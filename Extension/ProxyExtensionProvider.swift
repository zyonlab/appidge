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

    // App 下发的代理配置。handleAppMessage（写）和 handleNewFlow 的 Task（读）并发访问，
    // 用锁保护——provider 已是 @unchecked Sendable，这里显式担起这份线程安全。
    private let configLock = NSLock()
    private var storedProxyConfig: ProxyConfigMessage?

    private var proxyConfig: ProxyConfigMessage? {
        configLock.withLock { storedProxyConfig }
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

        completionHandler(nil)
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
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let router, let tcpFlow = flow as? NEAppProxyTCPFlow else { return false }

        let processID = ProcessIdentifierDTO(flow.metaData.sourceAppSigningIdentifier)
        let remoteEndpoint = tcpFlow.remoteFlowEndpoint
        flowLogger.log("""
        handleNewFlow sourceAppSigningIdentifier=\(flow.metaData.sourceAppSigningIdentifier, privacy: .public) \
        remote=\(String(describing: remoteEndpoint), privacy: .public)
        """)

        tcpFlow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self, error == nil else {
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                return
            }
            Task { await self.beginFlow(tcpFlow: tcpFlow, to: remoteEndpoint, processID: processID, router: router) }
        }
        return true
    }

    private func beginFlow(
        tcpFlow: NEAppProxyTCPFlow,
        to remoteEndpoint: Network.NWEndpoint,
        processID: ProcessIdentifierDTO,
        router: FlowRouter
    ) async {
        let rule = await effectiveRule(for: processID, destination: remoteEndpoint)
        await routingHistoryTracker.record(processID: processID, wasProxied: rule == .proxied)
        do {
            let remote = try await openRemote(to: remoteEndpoint, rule: rule)
            pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, processID: processID, rule: rule, router: router)
            pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, processID: processID, rule: rule, router: router)
        } catch {
            flowLogger.error("openRemote failed, closing flow: \(String(describing: error), privacy: .public)")
            tcpFlow.closeReadWithError(error)
            tcpFlow.closeWriteWithError(error)
        }
    }

    /// 见类型注释的三层决策。回环 / 命中上游 → 强制直连；否则按进程规则。
    private func effectiveRule(for processID: ProcessIdentifierDTO, destination: Network.NWEndpoint) async -> ProxyRuleDTO {
        if let (host, port) = Self.hostPort(from: destination) {
            if LoopbackDetector.isLoopback(host: host) { return .direct }
            let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) { return .direct }
        }
        return await appliedRuleSetStore.currentRule(for: processID) ?? .direct
    }

    /// `.proxied` 且有 active 上游 → 拨上游、做 SOCKS5 CONNECT，返回已就绪的隧道连接；
    /// 否则（含 proxied 但没配上游的 fail-open）直连目的地。返回的连接一律"已 ready"，可直接 pump。
    private func openRemote(to endpoint: Network.NWEndpoint, rule: ProxyRuleDTO) async throws -> NWConnection {
        if rule == .proxied,
           let active = proxyConfig?.activeServer,
           let (destHost, destPort) = Self.hostPort(from: endpoint) {
            let stream = NWConnectionByteStream(proxyServer: active)
            try await stream.open()
            try await SOCKS5Connector(proxyServer: active).establish(toHost: destHost, port: destPort, over: stream)
            return stream.tunnelConnection
        }
        return try await Self.openDirect(to: endpoint)
    }

    /// 直连目的地并挂起到 `.ready`（或失败）。返回时连接已可读写。
    private static func openDirect(to endpoint: Network.NWEndpoint) async throws -> NWConnection {
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeOnceBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let error): box.resume(.failure(error))
                case .cancelled: box.resume(.failure(OpenRemoteError.cancelled))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        return connection
    }

    private static func hostPort(from endpoint: Network.NWEndpoint) -> (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .name(let name, _): hostString = name
        case .ipv4(let address): hostString = "\(address)"
        case .ipv6(let address): hostString = "\(address)"
        @unknown default: return nil
        }
        return (hostString, port.rawValue)
    }

    private func pumpClientToRemote(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        processID: ProcessIdentifierDTO,
        rule: ProxyRuleDTO,
        router: FlowRouter
    ) {
        tcpFlow.readData { [weak self] data, error in
            guard let self, let data, error == nil, !data.isEmpty else {
                remote.cancel()
                tcpFlow.closeReadWithError(error)
                return
            }
            remote.send(content: data, completion: .contentProcessed { sendError in
                guard sendError == nil else {
                    remote.cancel()
                    tcpFlow.closeReadWithError(sendError)
                    return
                }
                Task { await router.route(processID: processID, bytesUp: Int64(data.count), bytesDown: 0, rule: rule, now: Date()) }
                self.pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, processID: processID, rule: rule, router: router)
            })
        }
    }

    private func pumpRemoteToClient(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        processID: ProcessIdentifierDTO,
        rule: ProxyRuleDTO,
        router: FlowRouter
    ) {
        remote.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil, !data.isEmpty else {
                tcpFlow.closeWriteWithError(error)
                if isComplete { remote.cancel() }
                return
            }
            tcpFlow.write(data) { writeError in
                guard writeError == nil else {
                    remote.cancel()
                    tcpFlow.closeWriteWithError(writeError)
                    return
                }
                Task { await router.route(processID: processID, bytesUp: 0, bytesDown: Int64(data.count), rule: rule, now: Date()) }
                self.pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, processID: processID, rule: rule, router: router)
            }
        }
    }
}

private enum OpenRemoteError: Error, Sendable {
    case cancelled
}

/// CheckedContinuation 只能 resume 一次；NWConnection 的 stateUpdateHandler 可能在 ready 之后
/// 还回调 cancelled，用锁保护避免二次 resume 崩溃。同 NEFlowTransport 的 ContinuationBox。
private final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
