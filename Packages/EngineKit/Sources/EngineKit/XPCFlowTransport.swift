import Foundation
import IPCContract

/// 生产路径的真实 Transport（E2 的 XPC 版）：App↔扩展走 XPC（`IPCContract.XPCTransportConfig`
/// 的 mach service），不再用 App Group UserDefaults + Darwin 通知（那条路径在 sysex 上不通，
/// 见 ``NEFlowTransport`` 和 `IPCContract/XPCTransport.swift` 的注释）。
///
/// `forward()` 是**纯计量钩子、零 I/O**。⚠️ 曾经的实现对每个 `.proxied` 数据块都
/// `probeUpstream()` 新建一条到上游的 TCP 连接(握手成功即 cancel)——TCPFlowPump 每读一个
/// ≤64KB 的 chunk 就调一次 `FlowRouter.route` → `forward`,一次大下载就是数千次
/// connect/handshake/cancel:耗尽扩展进程的临时端口与 fd、CPU 飙升,catch-all 接管下全系统
/// 断网(真机"装上后 Chrome 等无法联网、重启才恢复"的直接放大器)。上游可达性属于诊断
/// (`DiagnosticsRunner` 的 `upstreamReachable`),不属于数据面;数据面的失败本来就由 pump
/// 的连接错误路径(fail-open 关流)处理。
///
/// 并发安全用显式 `NSLock`，不用 actor：这个类型要 conform `@objc protocol`
/// （`ExtensionXPCProtocol`）并被 XPC runtime 在任意队列上调用，跟 actor 隔离域不兼容；
/// 这是这个代码库贯穿全局的写法（参考 ``NEFlowTransport`` 自己、
/// `Extension/ProxyExtensionProvider.swift` 的 `configLock`）。
public final class XPCFlowTransport: NSObject, Transport, ExtensionXPCProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var appMessageHandler: (@Sendable (AppToExtensionMessage) -> Void)?
    private var currentConnection: NSXPCConnection?
    private var listener: NSXPCListener?

    /// 参数保留只为调用点兼容(曾用于 forward 的逐 chunk 上游探活,见类型注释的 ⚠️)。
    public init(upstreamHost: String, upstreamPort: UInt16) {
        super.init()
    }

    /// 纯计量钩子:字节已由 pump 真实转发,这里不做任何 I/O(见类型注释的 ⚠️)。
    public func forward(
        processID: ProcessIdentifierDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        via rule: ProxyRuleDTO
    ) async throws {}

    /// 通过当前已连接的 XPC connection 把消息推给 App。拿不到连接（还没人连上、
    /// 或连接已失效）就静默不发——跟 ``NEFlowTransport.deliver`` 在拿不到 UserDefaults
    /// 时直接 return 的容错哲学一致，`deliver` 签名本来就不 throw。
    public func deliver(_ message: ExtensionToAppMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let connection = lock.withLock { currentConnection }
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // App 端不可达（尚未连接、已断开）：静默丢弃，不崩溃。
        } as? AppXPCProtocol
        proxy?.send(data)
    }

    /// Extension 侧监听 App 发来的消息（规则下发、诊断请求）：建 `NSXPCListener`，
    /// 收到连接就接受，收到消息就解码回调。不在自动化测试里跑，理由跟
    /// ``NEFlowTransport`` 一样——需要真实跨进程 XPC，SPM 测试环境跑不出来。
    public func startListeningForAppMessages(onMessage: @escaping @Sendable (AppToExtensionMessage) -> Void) {
        lock.withLock { appMessageHandler = onMessage }

        let listener = NSXPCListener(machServiceName: XPCTransportConfig.machServiceName)
        listener.delegate = self
        lock.withLock { self.listener = listener }
        listener.resume()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: AppXPCProtocol.self)

        newConnection.interruptionHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }

        lock.withLock { currentConnection = newConnection }
        newConnection.resume()
        return true
    }

    private func clearConnection(_ connection: NSXPCConnection) {
        lock.withLock {
            if currentConnection === connection {
                currentConnection = nil
            }
        }
    }

    // MARK: - ExtensionXPCProtocol（App → 扩展方向，App 调这个）

    /// XPC 运行时在任意队列上调用，不是 Swift 并发隔离的——内部用锁保护读
    /// `appMessageHandler` 闭包，解码失败静默丢弃，不崩溃。
    public func send(_ data: Data) {
        guard let message = try? JSONDecoder().decode(AppToExtensionMessage.self, from: data) else { return }
        let handler = lock.withLock { appMessageHandler }
        handler?(message)
    }
}

