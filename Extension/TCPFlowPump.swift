import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit

/// TCP flow 的双向 pump,拆到单独文件里(压 provider 主文件的行数)。读一端、写另一端、按方向
/// 计量、可选抓包,任一端出错/结束就关流并发一次结束事件(`emitClose`,已放宽到 internal 供跨文件调用)。
extension ProxyExtensionProvider {
    func pumpClientToRemote(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        context: ConnectionContext,
        router: FlowRouter
    ) {
        tcpFlow.readData { [weak self] data, error in
            guard let self, let data, error == nil, !data.isEmpty else {
                remote.cancel()
                tcpFlow.closeReadWithError(error)
                self?.emitClose(context, failed: error != nil)
                return
            }
            remote.send(content: data, completion: .contentProcessed { sendError in
                guard sendError == nil else {
                    remote.cancel()
                    tcpFlow.closeReadWithError(sendError)
                    self.emitClose(context, failed: true)
                    return
                }
                context.addUp(Int64(data.count))
                context.capture?.write(outbound: true, data)
                Task { await router.route(processID: context.processID, bytesUp: Int64(data.count), bytesDown: 0, rule: context.rule, now: Date()) }
                self.pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
            })
        }
    }

    func pumpRemoteToClient(
        tcpFlow: NEAppProxyTCPFlow,
        remote: NWConnection,
        context: ConnectionContext,
        router: FlowRouter
    ) {
        remote.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil, !data.isEmpty else {
                tcpFlow.closeWriteWithError(error)
                if isComplete { remote.cancel() }
                self?.emitClose(context, failed: error != nil)
                return
            }
            tcpFlow.write(data) { writeError in
                guard writeError == nil else {
                    remote.cancel()
                    tcpFlow.closeWriteWithError(writeError)
                    self.emitClose(context, failed: true)
                    return
                }
                context.addDown(Int64(data.count))
                context.capture?.write(outbound: false, data)
                Task { await router.route(processID: context.processID, bytesUp: 0, bytesDown: Int64(data.count), rule: context.rule, now: Date()) }
                self.pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
            }
        }
    }
}
