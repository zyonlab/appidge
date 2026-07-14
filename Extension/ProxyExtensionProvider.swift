import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract
import os.log

/// smoke-ne.sh 用 `log stream` 观测这个 subsystem，确认真实流量下
/// `sourceAppSigningIdentifier` 拿到的是父 app 级还是 CLI 子进程级身份。
private let flowLogger = Logger(subsystem: "com.appidge.app.ProxyExtension", category: "FlowIdentity")

/// NEAppProxyTCPFlow 是 NetworkExtension 的旧 Obj-C API，早于 Swift 6 并发审计，
/// 但按文档「Instances of this class are thread safe」，用 `@retroactive @unchecked
/// Sendable` 显式承担这个保证（比 `@preconcurrency` 把错误压成警告更干净：A3 要求
/// 零并发警告，`@retroactive` 避免了「未来 Apple 自己加 Sendable 会冲突」的警告）。
extension NEAppProxyTCPFlow: @retroactive @unchecked Sendable {}

/// NETransparentProxyProvider 的真实实现（E1）：接管每条 flow，真实双向转发字节（不是空壳），
/// 计量经 ``FlowRouter`` 批量上报，诊断经 ``DiagnosticsRunner``。
///
/// 路由决策（``effectiveRule``）三层，从强到弱：
/// 1. **回环排除**（``LoopbackDetector``）：目的地是 127.0.0.0/8 / ::1 / localhost → 强制直连。
/// 2. **上游排除**（``UpstreamExclusion``）：目的地正是配置的某台上游代理 → 强制直连，
///    否则"扩展连上游"这一跳会被自己再抓一次，形成转发环。
/// 3. 否则用该进程分配的规则（``AppliedRuleSetStore``）。
///
/// 转发（``openRemote``）：`.proxied` 且有 active 上游 → 经 ``SOCKS5Connector`` 隧道；
/// 否则直连目的地。拨号/握手失败 fail-open：关掉这条 flow，不阻塞其它流量。
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
    private let configLock = NSLock()
    private var storedProxyConfig: ProxyConfigMessage?
    private var storedRoutingMode: ProxyRoutingModeDTO = .single
    // 每进程规则的同步快照:UDP 决策在 handleNewFlow 里必须同步返回(读 actor 是 async,来不及),
    // 所以在 applyRuleSet 时额外维护这份锁保护的快照。TCP 路径仍走 async 的 appliedRuleSetStore。
    private var storedPerProcessRules: [String: ProxyRuleDTO] = [:]
    // 主动环检测(兜底安全网):同一目标在极短窗口内被反复捕获即疑似转发环。阈值刻意调高——真实
    // 环会以每秒上千次的速度重捕,远超正常并发连接;精确阈值需真机微调(见 PROGRESS)。锁保护。
    private var storedLoopDetector = LoopDetector(threshold: 50, windowSeconds: 1.0)
    // 逐连接抓包开关(默认关)。锁保护;开着时 beginFlow 给每条连接建一个 .dmp 写入器。
    private var storedPacketCaptureEnabled = false
    // proxied 进程的 UDP 策略(默认 .block 止漏)。锁保护。
    private var storedUDPPolicy: UDPPolicyDTO = .block
    // 活跃的 SOCKS5 UDP 中继,按 flow 生命周期持有(否则 relay 被释放、连接被取消)。按生成的
    // id 存,relay 结束时经 onFinished 拿 id 移除。锁保护。
    private var storedUDPRelays: [String: SOCKS5UDPRelay] = [:]

    private var packetCaptureEnabled: Bool {
        configLock.withLock { storedPacketCaptureEnabled }
    }

    private var udpPolicy: UDPPolicyDTO {
        configLock.withLock { storedUDPPolicy }
    }

    private var proxyConfig: ProxyConfigMessage? {
        configLock.withLock { storedProxyConfig }
    }

    private var perProcessRules: [String: ProxyRuleDTO] {
        configLock.withLock { storedPerProcessRules }
    }

    private var routingMode: ProxyRoutingModeDTO {
        configLock.withLock { storedRoutingMode }
    }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
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
            // 同步快照供 UDP 决策用(见 storedPerProcessRules）。后到的同 id 覆盖先到的。
            let snapshot = Dictionary(
                ruleSet.assignments.map { ($0.processID.value, $0.rule) },
                uniquingKeysWith: { _, latest in latest }
            )
            configLock.withLock { storedPerProcessRules = snapshot }
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

        let processID = ProcessIdentifierDTO(tcpFlow.metaData.sourceAppSigningIdentifier)
        let remoteEndpoint = tcpFlow.remoteFlowEndpoint
        // 原始主机名（app 用域名连的话 NE 会保留）——DNS-over-proxy 用它把域名交给代理去解析。
        let remoteHostname = tcpFlow.remoteHostname
        flowLogger.log("""
        handleNewTCPFlow sourceAppSigningIdentifier=\(tcpFlow.metaData.sourceAppSigningIdentifier, privacy: .public) \
        remote=\(String(describing: remoteEndpoint), privacy: .public) hostname=\(remoteHostname ?? "-", privacy: .public)
        """)

        tcpFlow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self, error == nil else {
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                return
            }
            Task {
                await self.beginFlow(
                    tcpFlow: tcpFlow, to: remoteEndpoint, remoteHostname: remoteHostname,
                    processID: processID, router: router
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
        router: FlowRouter
    ) async {
        let rule = await effectiveRule(for: processID, destination: remoteEndpoint)
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
            rule: rule, proxyKind: proxyKind, capture: capture
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
            rule: context.rule, proxyKind: context.proxyKind, phase: phase, bytesUp: bytes.up, bytesDown: bytes.down
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// 结束事件只发一次(两个 pump 都可能触发 teardown)。
    func emitClose(_ context: ConnectionContext, failed: Bool) {
        guard context.markClosedOnce() else { return }
        context.capture?.close() // 抓包文件随连接结束落盘关闭。
        emitConnectionEvent(context, phase: failed ? .failed : .closed)
    }

    /// 见类型注释的三层决策。回环 / 命中上游 → 强制直连；否则按进程规则。
    private func effectiveRule(for processID: ProcessIdentifierDTO, destination: Network.NWEndpoint) async -> ProxyRuleDTO {
        // 转发环硬化(按来源):我们自己组件(app/扩展)发起的连接强制直连,别再代理它——
        // 无关目的地,先于地址类判定。
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: processID.value, ownIdentifiers: Self.ownProcessIdentifiers) {
            return .direct
        }
        if let (host, port) = ProxyDialer.hostPort(from: destination) {
            if LoopbackDetector.isLoopback(host: host) { return .direct }
            let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) { return .direct }
            // 细粒度规则表(进程 × 主机 × 端口)优先于每进程粗粒度规则;命中即用其动作。
            if let matched = await appliedRuleSetStore.matchRule(app: processID.value, host: host, port: port) {
                return matched
            }
        }
        return await appliedRuleSetStore.currentRule(for: processID) ?? .direct
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

/// UDP 处理 + flow 双向 pump 拆到同文件 extension 里(不占 provider 类体的长度预算,且同文件仍可
/// 访问其 private 成员)。
private extension ProxyExtensionProvider {
    /// UDP/QUIC:按 3 态策略处理。allowDirect→不接管(原生直连);block→接管并 drop(止漏);
    /// proxy→经 SOCKS5 UDP ASSOCIATE 中继。
    func blockOrAllowUDPFlow(_ flow: NEAppProxyUDPFlow) -> Bool {
        let sourceID = flow.metaData.sourceAppSigningIdentifier
        let active = proxyConfig?.activeServer
        let disposition = UDPFlowPolicy.disposition(
            sourceIdentifier: sourceID,
            ownIdentifiers: Self.ownProcessIdentifiers,
            perProcessRule: perProcessRules[sourceID],
            udpPolicy: udpPolicy,
            upstreamIsSOCKS5: active?.kind == .socks5
        )
        switch disposition {
        case .allowDirect:
            return false // 不接管,UDP 原生直连。
        case .block:
            flowLogger.log("blocking UDP flow from \(sourceID, privacy: .public)")
            flow.open(withLocalFlowEndpoint: nil) { error in
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
            return true
        case .proxy:
            // disposition 已保证 active 是 SOCKS5;兜底再判一次。
            guard let active, active.kind == .socks5 else {
                flow.open(withLocalFlowEndpoint: nil) { error in
                    flow.closeReadWithError(error); flow.closeWriteWithError(error)
                }
                return true
            }
            startUDPRelay(flow: flow, proxy: active)
            return true
        }
    }

    /// 建一个 SOCKS5 UDP 中继并按 id 持有(结束时经 onFinished 用同一 id 移除)。id 是 let,可安全
    /// 被 @Sendable 的 onFinished 捕获(不像捕获 relay 变量那样触发并发告警)。
    func startUDPRelay(flow: NEAppProxyUDPFlow, proxy: ProxyServerDTO) {
        let id = UUID().uuidString
        let relay = SOCKS5UDPRelay(flow: flow, proxy: proxy) { [weak self] in
            guard let self else { return }
            self.configLock.withLock { _ = self.storedUDPRelays.removeValue(forKey: id) }
        }
        configLock.withLock { storedUDPRelays[id] = relay }
        Task { await relay.start() }
    }

}
