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

/// NETransparentProxyProvider 的真实实现（E1）：接管每条 flow，向真实远端拨号并双向
/// 转发字节（不是空壳），流量计量经 ``FlowRouter`` 按固定节奏批量上报给 app。
/// fail-open：拨号或转发失败时直接关闭该 flow，不阻塞其它流量，也不会把整机卡死。
final class ProxyExtensionProvider: NETransparentProxyProvider, @unchecked Sendable {
    private var router: FlowRouter?
    private let appGroup = "group.com.appidge"

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let transport = NEFlowTransport(upstreamHost: "127.0.0.1", upstreamPort: 1080, appGroup: appGroup)
        router = FlowRouter(transport: transport, flushInterval: 0.5, now: Date())
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        router = nil
        completionHandler()
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
            self.relay(tcpFlow: tcpFlow, to: remoteEndpoint, processID: processID, router: router)
        }
        return true
    }

    private func relay(
        tcpFlow: NEAppProxyTCPFlow,
        to remoteEndpoint: Network.NWEndpoint,
        processID: ProcessIdentifierDTO,
        router: FlowRouter
    ) {
        let remote = NWConnection(to: remoteEndpoint, using: .tcp)
        remote.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, processID: processID, router: router)
                self?.pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, processID: processID, router: router)
            case .failed, .cancelled:
                tcpFlow.closeReadWithError(nil)
                tcpFlow.closeWriteWithError(nil)
            default:
                break
            }
        }
        remote.start(queue: .global(qos: .utility))
    }

    private func pumpClientToRemote(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        processID: ProcessIdentifierDTO,
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
                Task { await router.route(processID: processID, bytesUp: Int64(data.count), bytesDown: 0, rule: .direct, now: Date()) }
                self.pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, processID: processID, router: router)
            })
        }
    }

    private func pumpRemoteToClient(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        processID: ProcessIdentifierDTO,
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
                Task { await router.route(processID: processID, bytesUp: 0, bytesDown: Int64(data.count), rule: .direct, now: Date()) }
                self.pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, processID: processID, router: router)
            }
        }
    }
}
