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

/// `effectiveRuleSync` 对一条 TCP flow 的判定结论。
enum TCPFlowDecision: Equatable {
    /// 完全不碰:返回 false 让系统原生处理,活动栏看不到(自身组件 / 回环 / 私网 / 上游)。
    case bypass
    /// 接管数据通路:`.proxied` 走上游、`.direct` 自己拨号直连、`.block` 拒绝——都在活动栏可见、可计量。
    case handle(ProxyRuleDTO)
    /// 观测(B):不接管数据通路,但在活动栏记一条连接事件(进程+目的地),随即返回 false 放行。
    /// 看得见"连了哪里"、零转发开销,代价是没有逐连接速率/字节。
    case observe
}

/// NETransparentProxyProvider 的真实实现（E1）：接管每条 flow，真实双向转发字节（不是空壳），
/// 计量经 ``FlowRouter`` 批量上报，诊断经 ``DiagnosticsRunner``。
///
/// 路由决策（``effectiveRuleSync``）——**策略 A(默认全量接管展示)**,从强到弱:
/// 1. **硬边界 → `.bypass`**(见 `hardBypassReason`,不受任何规则影响):
///    - **自身组件**:发起方是我们 app/扩展本体(静态标识/路径)——接管自己必然自套死循环。
///      注意这里**不含**本地代理:后者在策略 A 下要接管展示(见第 3 条)。
///    - **回环**（``LoopbackDetector``）/ **私网段**（``PrivateNetworkExclusion``）/
///      **上游**（``UpstreamExclusion``）:基础设施噪声 + 防环("扩展连上游"这一跳若被自己再抓
///      一次就成环)。
/// 2. **解出动作**:细粒度规则表（``RuleMatcher``,首个命中)→ 每进程规则 → **默认 `.direct`**。
///    默认即接管+自己拨号直连+计量,活动栏因此能对**所有**进程显示真实速率/流量(含本地代理
///    自己的出站),不再局限于走代理的进程。用户新建的规则插在表首、优先级最高(见
///    `Core.Reducer.addMatchRule`),手动改的策略必定生效。
/// 3. **本地代理防环**:发起方是 app 动态查到的本地代理(如 xray/yunti,签名标识 + 可执行文件
///    路径**两路独立信号**)时,一律**硬 `.bypass`、完全不接管**——它承载全系统代理流量,
///    接管即全量二次转发放大,真机三次实锤会把扩展拖死(见 `resolveDecision` ③ 的详注)。
/// 4. **`.observe`(策略 B)**:不接管数据通路,只记一条连接事件让它在活动栏可见后放行——零转发
///    开销,代价是没有逐连接速率/字节。用户可对任意进程/规则显式选用。
///
/// 转发（``openRemote``）：`.proxied` 且有 active 上游 → 经 ``SOCKS5Connector`` 隧道；
/// 否则直连目的地（``ProxyDialer/openDirect(to:)`` 显式清空代理配置，避免重蹈 5a7ad53 的覆辙）。
/// 拨号/握手失败 fail-open：关掉这条 flow，不阻塞其它流量。
final class ProxyExtensionProvider: NETransparentProxyProvider, @unchecked Sendable {
    private var router: FlowRouter?
    // 非 private:`emitObservedFlow` 在同类型的跨文件 extension 里投递观测事件(同 beginFlow 的先例)。
    var transport: XPCFlowTransport?
    // 不是 private:makeDiagnosticsRunner 拆到同 target 的 ProxyExtensionProviderRouting.swift。
    var diagnosticsRunner: DiagnosticsRunner?
    private let appGroup = "group.com.appidge"
    let appliedRuleSetStore = AppliedRuleSetStore()
    let routingHistoryTracker = RoutingHistoryTracker()
    // 负载均衡的游标要跨 flow 存活才能真的轮转,所以 selector 是 provider 级的单例。
    // 非 private:`openRemote` 在同类型的跨文件 extension 里用(同 beginFlow/transport 的先例)。
    let roundRobinSelector = RoundRobinSelector()

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

    /// 同上,但按可执行文件路径——`ProcessPathResolver` 从 flow 的 audit token 解出来的第二信号,
    /// 和签名标识各自独立比对(见 `ownExecutablePaths` 计算属性、`ProcessPathResolver` 的类型注释)。
    /// 只收自己扩展这一个:主 app 走的是 App Group IPC(UserDefaults),不产生会被 flow 拦截的
    /// TCP/UDP 连接,没有可执行文件路径需要排除。
    private static let ownProcessExecutablePaths: Set<String> = {
        guard let path = Bundle.main.executablePath else { return [] }
        return [path]
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
    // 同上,但按可执行文件路径(见 ownExecutablePaths)——未签名/ad-hoc 签名的本地代理软件常有
    // 多个进程、签名标识因进程而异,路径是更稳的第二信号(照抄开源 ProxyBridge 的做法)。
    private var storedDynamicOriginExclusionPaths: Set<String> = []

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

    // 不是 private:effectiveRuleSync 拆到同 target 的 ProxyExtensionProviderRouting.swift。
    var matchRules: [MatchRuleDTO] {
        configLock.withLock { storedMatchRules }
    }

    var routingMode: ProxyRoutingModeDTO {
        configLock.withLock { storedRoutingMode }
    }

    /// **自身组件**(app/扩展本体)的标识/路径——静态、启动时定。这一类**永远 `.bypass`**,
    /// 绝不接管自己的连接(否则必然自套死循环)。与"本地代理"区分开:后者在策略 A 下要**接管+直连+
    /// 展示**(不是 bypass),只是禁止把它代理出去(那才会转发环)。
    var selfIdentifiers: Set<String> { Self.ownProcessIdentifiers }
    var selfExecutablePaths: Set<String> { Self.ownProcessExecutablePaths }

    /// **本地代理进程**(如 xray/yunti)的标识/路径——app 动态查到、运行时可变。策略 A 下这类
    /// **照常接管并直连计量、在活动栏展示**;唯一的防环约束是:解出的动作若是 `.proxied` 一律
    /// 降级成 `.direct`(不能把本地代理的流量再转发回它)。
    var localProxyIdentifiers: Set<String> { configLock.withLock { storedDynamicOriginExclusions } }
    var localProxyExecutablePaths: Set<String> { configLock.withLock { storedDynamicOriginExclusionPaths } }

    /// 自身 ∪ 本地代理的并集——UDP 路径仍用这个"全排除"语义(UDP 没有"观测"通道,本地代理的
    /// UDP 一律放行直连即可,不需要像 TCP 那样接管展示)。TCP 的 `resolveDecision` 用上面分开的
    /// `selfXxx`/`localProxyXxx`,不用这两个。
    var ownIdentifiers: Set<String> { selfIdentifiers.union(localProxyIdentifiers) }
    var ownExecutablePaths: Set<String> { selfExecutablePaths.union(localProxyExecutablePaths) }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        ExtDiag.log("startProxy called")
        let transport = XPCFlowTransport(upstreamHost: "127.0.0.1", upstreamPort: 1080)
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

    private func handleAppMessage(_ message: AppToExtensionMessage, transport: XPCFlowTransport) async {
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
            // 定位「配置到底有没有下发到扩展」的关键日志:这次收到的规则表长什么样。
            let matchRulesSummary = matchRulesSnapshot.map { rule -> String in
                let port = rule.portRange.map(String.init(describing:)) ?? "any"
                return "[\(rule.appPattern)/\(rule.hostPattern)/\(port)->\(rule.rule)]"
            }.joined(separator: ",")
            ExtDiag.log(
                "applyRuleSet received: "
                + "perProcess=\(snapshot.map { "\($0.key)->\($0.value)" }.joined(separator: ",")) "
                + "matchRules=\(matchRulesSummary)"
            )
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
            ExtDiag.log("applyProxyConfig received: servers=\(config.servers.count) active=\(config.activeServerID ?? "nil")")
        case .applyRoutingMode(let mode):
            configLock.withLock { storedRoutingMode = mode }
        case .setPacketCapture(let enabled):
            configLock.withLock { storedPacketCaptureEnabled = enabled }
        case .setUDPPolicy(let policy):
            configLock.withLock { storedUDPPolicy = policy }
        case .applyProcessOriginExclusions(let message):
            configLock.withLock {
                storedDynamicOriginExclusions = Set(message.identifiers)
                storedDynamicOriginExclusionPaths = Set(message.executablePaths)
            }
            ExtDiag.log(
                "applyProcessOriginExclusions received: identifiers=\(message.identifiers.joined(separator: ",")) "
                + "paths=\(message.executablePaths.joined(separator: ","))"
            )
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
        let sourcePath = ProcessPathResolver.executablePath(from: tcpFlow.metaData.sourceAppAuditToken)
        let processID = ProcessIdentifierDTO(sourceID)
        let remoteEndpoint = tcpFlow.remoteFlowEndpoint
        // 原始主机名（app 用域名连的话 NE 会保留）——DNS-over-proxy 用它把域名交给代理去解析。
        let remoteHostname = tcpFlow.remoteHostname
        let hostPort = ProxyDialer.hostPort(from: remoteEndpoint)

        // 策略 A(默认):除了自身组件 / 回环 / 私网 / 上游这几道硬边界 `.bypass`,其余一律接管——
        // 含 `.direct`(自己拨号直连,不走代理),这样活动栏能对**所有**进程(含本地代理自己的出站)
        // 显示真实速率/流量。`.observe`(B)是例外:记一条连接事件让它可见,随即放行、不接管数据通路。
        // effectiveRuleSync 内部把每条 flow 的判定原因记进 ExtDiag(不只是被接管的)——定位
        // "配置没生效 vs 压根没拦截到"的关键证据,见该函数的文档注释。
        let decision = effectiveRuleSync(
            sourceID: sourceID, sourcePath: sourcePath, host: hostPort?.0, hostname: remoteHostname, port: hostPort?.1
        )
        let name = sourcePath.flatMap(ProcessPathResolver.displayName(fromExecutablePath:))
        switch decision {
        case .bypass:
            return false
        case .observe:
            // 不接管数据通路:记一条"观测"连接事件(0 字节)让活动栏看得到"这进程连了哪里",随即放行。
            // 展示优先域名(app 用域名连时 NE 保留),对齐 Proxifier 的 Target 列。
            emitObservedFlow(
                processID: processID, displayName: name, host: remoteHostname ?? hostPort?.0, port: hostPort?.1
            )
            return false
        case .handle(let rule):
            flowLogger.log("""
            handleNewTCPFlow INTERCEPT src=\(sourceID, privacy: .public) \
            rule=\(String(describing: rule), privacy: .public) host=\(hostPort?.0 ?? "-", privacy: .public)
            """)
            beginHandledFlow(
                tcpFlow: tcpFlow,
                origin: FlowOrigin(processID: processID, displayName: name, executablePath: sourcePath, rule: rule),
                to: remoteEndpoint, remoteHostname: remoteHostname, router: router
            )
            return true
        }
    }

    /// 非 private:`beginHandledFlow` 在同类型的跨文件 extension(`ProxyExtensionProviderRouting`)里
    /// 调用它——同 `matchRules`/`effectiveRuleSync` 的既有先例(拆文件压 lint 阈值)。
    func beginFlow(
        tcpFlow: NEAppProxyTCPFlow,
        to remoteEndpoint: Network.NWEndpoint,
        remoteHostname: String?,
        origin: FlowOrigin,
        router: FlowRouter
    ) async {
        let processID = origin.processID
        let rule = origin.rule
        // rule 由 handleNewTCPFlow 同步解出并传入(只有 .proxied/.block 才会走到这里);不再在此
        // async 重解,既省一次 actor 往返,也避免"同步判接管、异步又判成 .direct"的竞态。
        await routingHistoryTracker.record(processID: processID, wasProxied: rule == .proxied)

        // 展示/日志/环签名优先域名(app 用域名连时 NE 保留),对齐 Proxifier 的 Target 列——
        // 同一域名换 IP 不再看起来是"不同目标",环签名也更稳。端口仍取自 endpoint。
        let endpointHostPort = ProxyDialer.hostPort(from: remoteEndpoint)
        let host = remoteHostname ?? endpointHostPort?.0 ?? "?"
        let port = endpointHostPort?.1 ?? 0

        // 主动环检测:把这次捕获喂给检测器,命中(同目标短窗口内反复捕获)就提示 app,并随事件
        // 带上来源进程双信号——app 会把它自动加入旁路排除并回推(环自愈,对齐 Proxifier 的
        // auto-created Direct 规则),兜底 passive 的回环/上游/来源排除漏网的情况。
        let loopSignature = "\(host):\(port)"
        let looped = configLock.withLock {
            storedLoopDetector.record(signature: loopSignature, now: Date().timeIntervalSince1970)
        }
        if looped, let transport {
            let origin = origin
            Task {
                await transport.deliver(.loopDetected(
                    signature: loopSignature, processID: origin.processID, executablePath: origin.executablePath
                ))
            }
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
            rule: rule, proxyKind: proxyKind, openedAt: Date(), capture: capture,
            processDisplayName: origin.displayName
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
            openedAt: context.openedAt, processDisplayName: context.processDisplayName
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// 结束事件只发一次(两个 pump 都可能触发 teardown)。
    func emitClose(_ context: ConnectionContext, failed: Bool) {
        guard context.markClosedOnce() else { return }
        context.capture?.close() // 抓包文件随连接结束落盘关闭。
        emitConnectionEvent(context, phase: failed ? .failed : .closed)
    }

}
