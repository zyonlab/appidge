import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract
import os.log

/// smoke-ne.sh 用 `log stream` 观测这个 subsystem，确认真实流量下
/// `sourceAppSigningIdentifier` 拿到的是父 app 级还是 CLI 子进程级身份。
let flowLogger = Logger(subsystem: "com.appidge.app.ProxyExtension", category: "FlowIdentity")

/// NEAppProxyTCPFlow 是 NetworkExtension 的旧 Obj-C API，早于 Swift 6 并发审计，
/// 但按文档「Instances of this class are thread safe」，用 `@retroactive @unchecked
/// Sendable` 显式承担这个保证（比 `@preconcurrency` 把错误压成警告更干净：A3 要求
/// 零并发警告，`@retroactive` 避免了「未来 Apple 自己加 Sendable 会冲突」的警告）。
extension NEAppProxyTCPFlow: @retroactive @unchecked Sendable {}

/// `effectiveRuleSync` 对一条 TCP flow 的判定结论。`.bypass` 是转发环硬化的安全边界(见类型
/// 注释四道闸)**以及** rule 最终解出是 `.direct` 的情形——一律不接管;`.handle` 只覆盖
/// `.proxied`/`.block`。`.direct` 曾短暂改成"接管但自己直连",真机验证发现本地代理软件常有
/// 多个进程、签名标识因进程而异,现有排除只精确匹配了其中一个,已回退,详见 `effectiveRuleSync`。
enum TCPFlowDecision: Equatable {
    case bypass
    case handle(ProxyRuleDTO)
}

/// NETransparentProxyProvider 的真实实现（E1）：接管每条 flow，真实双向转发字节（不是空壳），
/// 计量经 ``FlowRouter`` 批量上报，诊断经 ``DiagnosticsRunner``。
///
/// 路由决策（``effectiveRuleSync``），从强到弱:
/// 1. **来源进程排除**（``ProcessOriginExclusion``）：发起方是我们自己组件或 app 动态查到的
///    本地代理进程（如 xray/yunti）→ `.bypass`（强制直连、不接管），与下面的地址判定正交，
///    见 PROGRESS.md「防环设计定论」。
/// 2. **回环排除**（``LoopbackDetector``）：目的地是 127.0.0.0/8 / ::1 / localhost → `.bypass`。
/// 3. **私网段排除**（``PrivateNetworkExclusion``）：目的地是 10/8、172.16/12、192.168/16、
///    169.254/16、fc00::/7 → `.bypass`（本地/局域网服务不该走代理）。
/// 4. **上游排除**（``UpstreamExclusion``）：目的地正是配置的某台上游代理 → `.bypass`，
///    否则"扩展连上游"这一跳会被自己再抓一次，形成转发环。
/// 5. 细粒度规则表（``RuleMatcher``），再不命中则用该进程分配的粗粒度规则（``AppliedRuleSetStore``）；
///    解出的结果只要是 `.direct` 也一律 `.bypass`——只有 `.proxied`/`.block` 才 `.handle`(见
///    `TCPFlowDecision` 的说明,这条是回退过一次的边界,别再放开)。
///
/// 转发（``openRemote``）：`.proxied` 且有 active 上游 → 经 ``SOCKS5Connector`` 隧道；
/// 否则直连目的地（``ProxyDialer/openDirect(to:)`` 显式清空代理配置，避免重蹈 5a7ad53 的覆辙）。
/// 拨号/握手失败 fail-open：关掉这条 flow，不阻塞其它流量。
final class ProxyExtensionProvider: NETransparentProxyProvider, @unchecked Sendable {
    private var router: FlowRouter?
    private var transport: NEFlowTransport?
    private var diagnosticsRunner: DiagnosticsRunner?
    private let appGroup = "group.com.appidge"
    private let appliedRuleSetStore = AppliedRuleSetStore()
    private let routingHistoryTracker = RoutingHistoryTracker()
    // 负载均衡的游标要跨 flow 存活才能真的轮转,所以 selector 是 provider 级的单例。
    private let roundRobinSelector = RoundRobinSelector()

    /// 我们自己组件(扩展 + 主 app)的进程身份集合,用于按来源做转发环硬化:这些身份发起的
    /// 连接强制直连,不再被自己抓回来代理(见 ``ProcessOriginExclusion``,与基于地址的
    /// ``UpstreamExclusion`` 正交)。扩展自己的 bundle id 从 Bundle 取,主 app 是它的父级
    /// (bundle id 去掉最后一段)。待人工回填:自己 app 的 flow 究竟以 bundle id 还是 team 前缀
    /// 身份出现在 sourceAppSigningIdentifier——不匹配时只是不排除(fail-open,同今天行为)。
    private static let ownProcessIdentifiers: Set<String> = {
        guard let ext = Bundle.main.bundleIdentifier else { return [] }
        let parent = ext.split(separator: ".").dropLast().joined(separator: ".")
        return parent.isEmpty ? [ext] : [ext, parent]
    }()

    // App 下发的代理配置。handleAppMessage（写）和 handleNewFlow 的 Task（读）并发访问，
    // 用锁保护——provider 已是 @unchecked Sendable，这里显式担起这份线程安全。
    // 不是 private:UDP 处理拆到同 target 的 ProxyExtensionProviderUDP.swift,需要跨文件访问
    // (private 只在同文件内的 extension 才透明,见「拆文件压行数」的既有先例,同 TCPFlowPump)。
    let configLock = NSLock()
    private var storedProxyConfig: ProxyConfigMessage?
    private var storedRoutingMode: ProxyRoutingModeDTO = .single
    // 每进程规则的同步快照:handleNewFlow(TCP 和 UDP)都必须同步决定接管与否(返回 Bool,
    // 读 actor 是 async 来不及),所以在 applyRuleSet 时额外维护这份锁保护的快照。
    private var storedPerProcessRules: [String: ProxyRuleDTO] = [:]
    // 细粒度 match 规则(进程 × 主机 × 端口)的同步快照,配合 storedPerProcessRules 让 TCP 的
    // handleNewFlow 能同步解出 effectiveRule(见 effectiveRuleSync)——不接管的流量必须在返回
    // false 前就判定,绝不能先接管再 async 决定。
    private var storedMatchRules: [MatchRuleDTO] = []
    // 主动环检测(兜底安全网):同一目标在极短窗口内被反复捕获即疑似转发环。阈值刻意调高——真实
    // 环会以每秒上千次的速度重捕,远超正常并发连接;精确阈值需真机微调(见 PROGRESS)。锁保护。
    private var storedLoopDetector = LoopDetector(threshold: 50, windowSeconds: 1.0)
    // 逐连接抓包开关(默认关)。锁保护;开着时 beginFlow 给每条连接建一个 .dmp 写入器。
    private var storedPacketCaptureEnabled = false
    // proxied 进程的 UDP 策略(默认 .block 止漏)。锁保护。
    private var storedUDPPolicy: UDPPolicyDTO = .block
    // 活跃的 SOCKS5 UDP 中继,按 flow 生命周期持有(否则 relay 被释放、连接被取消)。按生成的
    // id 存,relay 结束时经 onFinished 拿 id 移除。锁保护。
    var storedUDPRelays: [String: SOCKS5UDPRelay] = [:]
    // App 侧动态查到的本地代理进程(如 xray/yunti)签名标识集合,与静态的 ownProcessIdentifiers
    // 合并使用(见 ownIdentifiers 计算属性)——转发环硬化「来源进程自动排除」的第二正交维度。
    // 运行时发现的结果,不持久化,重启后由 app 重新查、applyProcessOriginExclusions 重新下发。
    private var storedDynamicOriginExclusions: Set<String> = []

    private var packetCaptureEnabled: Bool {
        configLock.withLock { storedPacketCaptureEnabled }
    }

    var udpPolicy: UDPPolicyDTO {
        configLock.withLock { storedUDPPolicy }
    }

    var proxyConfig: ProxyConfigMessage? {
        configLock.withLock { storedProxyConfig }
    }

    var perProcessRules: [String: ProxyRuleDTO] {
        configLock.withLock { storedPerProcessRules }
    }

    private var matchRules: [MatchRuleDTO] {
        configLock.withLock { storedMatchRules }
    }

    private var routingMode: ProxyRoutingModeDTO {
        configLock.withLock { storedRoutingMode }
    }

    /// 「来源进程自动排除」的完整集合:自身组件(静态,启动时定)∪ app 动态查到的本地代理进程
    /// (运行时可变,随 applyProcessOriginExclusions 更新)。两路来源都命中即强制直连。
    var ownIdentifiers: Set<String> {
        Self.ownProcessIdentifiers.union(configLock.withLock { storedDynamicOriginExclusions })
    }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        ExtDiag.log("startProxy called")
        let transport = NEFlowTransport(upstreamHost: "127.0.0.1", upstreamPort: 1080, appGroup: appGroup)
        self.transport = transport
        router = FlowRouter(transport: transport, flushInterval: 0.5, now: Date())
        diagnosticsRunner = makeDiagnosticsRunner(upstreamHost: "127.0.0.1", upstreamPort: 1080)

        transport.startListeningForAppMessages { [weak self] message in
            guard let self else { return }
            Task { await self.handleAppMessage(message, transport: transport) }
        }

        // 透明代理网络设置:拦截所有出站 TCP + UDP。此前完全没设置——拦截从未真正生效(也是
        // 「待人工回填」里 flow metadata 观测被卡住的一环)。UDP 纳入拦截是 A1「拦截 QUIC/UDP
        // 止漏」的前提。⚠️ 只能在真机 + 系统扩展获批后验证,见 PROGRESS.md 人工自测。
        setTunnelNetworkSettings(TransparentProxySettings.make()) { error in
            ExtDiag.log("setTunnelNetworkSettings done error=\(error.map { "\($0)" } ?? "nil")")
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        router = nil
        transport = nil
        diagnosticsRunner = nil
        completionHandler()
    }

    /// 复用同一个 appliedRuleSetStore/routingHistoryTracker 实例——诊断器读到的必须是
    /// handleAppMessage/handleNewFlow 实际在写的那两个 store，不是各查各的空壳。
    /// upstreamHost/Port 指向真实上游，让 upstreamReachable 诊断探的是"我们配的代理还在不在"。
    private func makeDiagnosticsRunner(upstreamHost: String, upstreamPort: UInt16) -> DiagnosticsRunner {
        DiagnosticsRunner(
            ruleLookup: appliedRuleSetStore,
            routingLookup: routingHistoryTracker,
            upstreamProbe: NWConnectionUpstreamProbe(),
            dnsResolver: NWConnectionDNSResolver(),
            environmentReader: ProcessInfoEnvironmentReader(),
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort
        )
    }

    private func handleAppMessage(_ message: AppToExtensionMessage, transport: NEFlowTransport) async {
        switch message {
        case .applyRuleSet(let ruleSet):
            await appliedRuleSetStore.apply(ruleSet)
            // 同步快照供 handleNewFlow(TCP+UDP)决策用。后到的同 id 覆盖先到的。
            let snapshot = Dictionary(
                ruleSet.assignments.map { ($0.processID.value, $0.rule) },
                uniquingKeysWith: { _, latest in latest }
            )
            let matchRulesSnapshot = ruleSet.matchRules
            configLock.withLock {
                storedPerProcessRules = snapshot
                storedMatchRules = matchRulesSnapshot
            }
        case .requestDiagnostic(let request):
            guard let diagnosticsRunner else { return }
            let results = await diagnosticsRunner.run(processID: request.processID, kinds: request.kinds)
            for result in results {
                await transport.deliver(.diagnosticResult(result))
            }
        case .applyProxyConfig(let config):
            configLock.withLock { storedProxyConfig = config }
            // active 上游变了，让 upstreamReachable 诊断跟着探新的上游地址。
            if let active = config.activeServer {
                diagnosticsRunner = makeDiagnosticsRunner(upstreamHost: active.host, upstreamPort: active.port)
            }
        case .applyRoutingMode(let mode):
            configLock.withLock { storedRoutingMode = mode }
        case .setPacketCapture(let enabled):
            configLock.withLock { storedPacketCaptureEnabled = enabled }
        case .setUDPPolicy(let policy):
            configLock.withLock { storedUDPPolicy = policy }
        case .applyProcessOriginExclusions(let message):
            configLock.withLock { storedDynamicOriginExclusions = Set(message.identifiers) }
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleNewTCPFlow(tcpFlow)
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            return blockOrAllowUDPFlow(udpFlow)
        }
        return false
    }

    private func handleNewTCPFlow(_ tcpFlow: NEAppProxyTCPFlow) -> Bool {
        guard let router else { return false }

        let sourceID = tcpFlow.metaData.sourceAppSigningIdentifier
        let processID = ProcessIdentifierDTO(sourceID)
        let remoteEndpoint = tcpFlow.remoteFlowEndpoint
        // 原始主机名（app 用域名连的话 NE 会保留）——DNS-over-proxy 用它把域名交给代理去解析。
        let remoteHostname = tcpFlow.remoteHostname
        let hostPort = ProxyDialer.hostPort(from: remoteEndpoint)

        // 转发环硬化的四道闸(自身来源/回环/私网段/上游排除)—— .bypass 绝不接管,让系统原生处理,
        // 这是 CPU 死转事故(5a7ad53)划定的安全边界,不能碰。除此之外一律 .handle(rule)接管——
        // 包括 rule == .direct:现在"直连"也由我们自己拨号(见 ProxyDialer.openDirect 的显式
        // no-proxy NWParameters),只是不走代理、原样连到原目的地,这样"应用"页才能对所有进程
        // 显示真实速率/流量,不再局限于走代理的进程。
        guard case .handle(let rule) = effectiveRuleSync(sourceID: sourceID, host: hostPort?.0, port: hostPort?.1) else {
            return false
        }

        flowLogger.log("""
        handleNewTCPFlow INTERCEPT src=\(sourceID, privacy: .public) rule=\(String(describing: rule), privacy: .public) \
        host=\(hostPort?.0 ?? "-", privacy: .public)
        """)
        ExtDiag.log("handleNewTCPFlow INTERCEPT src=\(sourceID) rule=\(rule) host=\(hostPort?.0 ?? "-")")
        tcpFlow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self, error == nil else {
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                return
            }
            Task {
                await self.beginFlow(
                    tcpFlow: tcpFlow, to: remoteEndpoint, remoteHostname: remoteHostname,
                    processID: processID, rule: rule, router: router
                )
            }
        }
        return true
    }

    private func beginFlow(
        tcpFlow: NEAppProxyTCPFlow,
        to remoteEndpoint: Network.NWEndpoint,
        remoteHostname: String?,
        processID: ProcessIdentifierDTO,
        rule: ProxyRuleDTO,
        router: FlowRouter
    ) async {
        // rule 由 handleNewTCPFlow 同步解出并传入(只有 .proxied/.block 才会走到这里);不再在此
        // async 重解,既省一次 actor 往返,也避免"同步判接管、异步又判成 .direct"的竞态。
        await routingHistoryTracker.record(processID: processID, wasProxied: rule == .proxied)

        let (host, port) = ProxyDialer.hostPort(from: remoteEndpoint) ?? (remoteHostname ?? "?", 0)

        // 主动环检测:把这次捕获喂给检测器,命中(同目标短窗口内反复捕获)就提示 app——
        // 兜底 passive 的回环/上游/来源排除漏网的情况。
        let loopSignature = "\(host):\(port)"
        let looped = configLock.withLock {
            storedLoopDetector.record(signature: loopSignature, now: Date().timeIntervalSince1970)
        }
        if looped, let transport {
            Task { await transport.deliver(.loopDetected(signature: loopSignature)) }
        }

        // 实际所用代理协议:按解析后的路由取第一跳的 kind——proxied 但降级成直连时记 nil,
        // 让连接日志里"到底走没走代理"如实。
        let proxyKind = ProxyDialer.representativeKind(rule: rule, config: proxyConfig, mode: routingMode)
        // 抓包开着时给这条连接建一个 .dmp 写入器;关着(或拿不到容器)就 nil,pump 里是 no-op。
        let capture = packetCaptureEnabled
            ? PacketCaptureWriter.forConnection(
                appGroup: appGroup, processID: processID.value, host: host, port: port,
                at: Date().timeIntervalSince1970
            )
            : nil
        let context = ConnectionContext(
            id: UUID().uuidString, processID: processID, host: host, port: port,
            rule: rule, proxyKind: proxyKind, openedAt: Date(), capture: capture
        )

        // 命中 Block 规则:直接拒绝这条 flow,不建立任何远端连接。记一条 closed 事件
        // (rule=block、0 字节)让连接日志里能看到"这条被拦截了",然后返回。
        if rule == .block {
            flowLogger.log("flow blocked by rule: \(processID.value, privacy: .public) -> \(host, privacy: .public):\(port)")
            tcpFlow.closeReadWithError(nil)
            tcpFlow.closeWriteWithError(nil)
            emitClose(context, failed: false)
            return
        }

        do {
            let remote = try await openRemote(to: remoteEndpoint, remoteHostname: remoteHostname, rule: rule)
            emitConnectionEvent(context, phase: .opened)
            pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
            pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
        } catch {
            flowLogger.error("openRemote failed, closing flow: \(String(describing: error), privacy: .public)")
            tcpFlow.closeReadWithError(error)
            tcpFlow.closeWriteWithError(error)
            emitClose(context, failed: true)
        }
    }

    /// 发一条连接生命周期事件给 app(取当前累计字节)。
    private func emitConnectionEvent(_ context: ConnectionContext, phase: ConnectionPhaseDTO) {
        guard let transport else { return }
        let bytes = context.snapshotBytes()
        let event = ConnectionEventDTO(
            id: context.id, processID: context.processID, targetHost: context.host, targetPort: context.port,
            rule: context.rule, proxyKind: context.proxyKind, phase: phase, bytesUp: bytes.up, bytesDown: bytes.down,
            openedAt: context.openedAt
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// 结束事件只发一次(两个 pump 都可能触发 teardown)。
    func emitClose(_ context: ConnectionContext, failed: Bool) {
        guard context.markClosedOnce() else { return }
        context.capture?.close() // 抓包文件随连接结束落盘关闭。
        emitConnectionEvent(context, phase: failed ? .failed : .closed)
    }

    /// handleNewFlow 必须**同步**决定接管与否(返回 Bool),不能 await actor。这是原 async effectiveRule
    /// 的同步镜像:用锁保护的快照(storedMatchRules / storedPerProcessRules / storedProxyConfig)做
    /// 完全相同的判定,结论分两种:
    /// - `.bypass`:转发环硬化的四道闸(自身来源 / 回环 / 私网段 / 上游排除)命中,**或者**最终解出
    ///   的规则就是 `.direct`——一律不接管,让系统原生处理。
    /// - `.handle(rule)`:只有 `.proxied`/`.block` 才接管。
    ///
    /// ⚠️ **`.direct` 曾经短暂改成"接管但自己直连"(想让"应用"页对任意进程展示速率),已回退**:
    /// 真机验证发现本地代理软件(如 xray/yunti)在系统里往往不止一个进程——`sourceAppSigningIdentifier`
    /// 报告的身份可能因进程而异(例:监听配置端口的那个报 `com.example.yunti`,能被
    /// `LocalProxyOriginDiscovery` 正确排除;但它另一个做实际出站连接的进程却报成了完全不同的
    /// `a.out`),现有的"来源进程自动排除"只精确匹配了前者。一旦 `.direct` 也被接管,这类没被
    /// 排除到的第二个进程的**全部真实流量**都会被透明地二次转发进我们自己的 pump——不是死循环,
    /// 但是会把用户已经在用的真实代理软件的全部流量套一层不必要的转发,增加真实的 CPU/延迟开销
    /// (真机 15 分钟内 8892 条接管里 8781 条是这个进程)。在把"排除本地代理进程"从「精确匹配监听
    /// 该端口的那一个」加强成「覆盖它的整个进程家族(比如按可执行路径匹配,PROGRESS.md 里早就
    /// 写好了这条兜底方案)」之前,`.direct` 必须继续保持"绝不接管"。
    ///
    /// host/port 拿不到(极少数解析不出目的地)时跳过地址类判定,只按每进程规则。
    private func effectiveRuleSync(sourceID: String, host: String?, port: UInt16?) -> TCPFlowDecision {
        // 转发环硬化(按来源):我们自己组件(app/扩展)+ app 动态查到的本地代理进程发起的连接
        // 不接管——无关目的地,先判。
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: ownIdentifiers) {
            return .bypass
        }
        if let host, let port {
            if LoopbackDetector.isLoopback(host: host) { return .bypass }
            // 私网段/link-local 目的地址强制直连(本地/局域网服务不该走代理),与回环正交、互补。
            if PrivateNetworkExclusion.isPrivateNetwork(host: host) { return .bypass }
            let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) { return .bypass }
            // 细粒度规则表(进程 × 主机 × 端口)优先于每进程粗粒度规则;命中即用其动作,
            // 但命中的动作本身是 .direct 时同样不接管(见上面的回退说明)。
            if let matched = RuleMatcher.firstMatch(matchRules, app: sourceID, host: host, port: port) {
                return matched == .direct ? .bypass : .handle(matched)
            }
        }
        let resolved = perProcessRules[sourceID] ?? .direct
        return resolved == .direct ? .bypass : .handle(resolved)
    }

    /// `.proxied` → 按 ``ProxyRouteResolver`` 解析出的路由拨上游、做隧道握手,返回已就绪、可直接
    /// pump 的连接;解析为 `.direct`(含 proxied 但没配上游的 fail-open)则直连目的地。实际拨号
    /// 交给无状态的 ``ProxyDialer``。目标地址经 ``ProxyTargetSelector`` 优先取原始主机名
    /// (DNS-over-proxy,让代理去解析)。
    private func openRemote(
        to endpoint: Network.NWEndpoint, remoteHostname: String?, rule: ProxyRuleDTO
    ) async throws -> NWConnection {
        guard rule == .proxied, let (endpointHost, port) = ProxyDialer.hostPort(from: endpoint) else {
            return try await ProxyDialer.openDirect(to: endpoint)
        }
        let config = proxyConfig
        let route = ProxyRouteResolver.resolve(
            mode: routingMode, servers: config?.servers ?? [], activeServerID: config?.activeServerID
        )
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: remoteHostname, endpointHost: endpointHost, port: port
        )
        return try await ProxyDialer.open(
            route: route, to: target, directEndpoint: endpoint, roundRobin: roundRobinSelector
        )
    }

}
