import Foundation
import IPCContract

/// 生产路径的真实实现，取代不通的 ``AppGroupAppSideTransport``（App Group UserDefaults +
/// Darwin 通知——扩展以 root 身份跑，App 以登录用户身份跑，两边解析到的 App Group 容器
/// 路径不同，永远读不到对方写的东西，真机验证过；Apple DTS 在开发者论坛确认这是 macOS
/// System Extension 的已知限制，官方推荐换 XPC）。
///
/// App 侧是 XPC **客户端**：扩展发布 `NSXPCListener(machServiceName:
/// XPCTransportConfig.machServiceName)`，这里主动 `NSXPCConnection(machServiceName:)`
/// 连过去。mach service 名字必须原样用 `IPCContract.XPCTransportConfig.machServiceName`
/// （踩过坑的历史见该文件注释），不要在这里重新拼字符串。
///
/// 并发安全用这个代码库贯穿全局的写法：`@unchecked Sendable` + 显式 `NSLock` 保护可变状态
/// （存住的 `onMessage` 回调、当前连接、监听状态），不用 actor——因为要实现 `@objc` 协议、
/// 要被 XPC runtime 同步调用，套 actor 反而更麻烦。
///
/// 懒重连：系统扩展是按需拉起的，扩展进程可能在 App 启动之后才真正跑起来，也可能中途重启。
/// `send(_:)` 每次调用前都检查连接是否还活着，断了 / 从没连过就重新建一条，不会因为某次没连
/// 上就永久放弃。
public final class XPCAppSideTransport: NSObject, AppSideTransport, AppXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var onMessage: (@Sendable (ExtensionToAppMessage) -> Void)?
    private var isListening = false

    override public init() {
        super.init()
    }

    // MARK: - AppSideTransport

    public func send(_ message: AppToExtensionMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let conn = currentConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            // 连接错误由 interruptionHandler/invalidationHandler 统一处理（清空存住的
            // connection），下一次 send() 会自动懒重连，这里不需要额外动作。
        } as? ExtensionXPCProtocol
        proxy?.send(data)
    }

    public func startListening(onMessage: @escaping @Sendable (ExtensionToAppMessage) -> Void) async {
        lock.withLock {
            self.onMessage = onMessage
            self.isListening = true
        }
        _ = currentConnection()
    }

    public func stopListening() async {
        let conn: NSXPCConnection? = lock.withLock {
            self.isListening = false
            self.onMessage = nil
            let existing = self.connection
            self.connection = nil
            return existing
        }
        conn?.invalidate()
    }

    // MARK: - AppXPCProtocol（扩展 → App 方向，扩展调这个）

    public func send(_ data: Data) {
        let (listening, handler) = lock.withLock { (self.isListening, self.onMessage) }
        guard listening, let handler else { return }
        guard let message = try? JSONDecoder().decode(ExtensionToAppMessage.self, from: data) else { return }
        handler(message)
    }

    // MARK: - 连接管理

    /// 返回一条可用的连接：已有的活跃连接直接复用，没有就新建一条并 `resume()`。
    /// 整个「查一次、没有就建」在同一次加锁内完成，避免并发 send() 时重复建连接。
    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let existing = self.connection {
                return existing
            }
            let newConnection = NSXPCConnection(
                machServiceName: XPCTransportConfig.machServiceName,
                options: []
            )
            newConnection.exportedInterface = NSXPCInterface(with: AppXPCProtocol.self)
            newConnection.exportedObject = self
            newConnection.remoteObjectInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
            newConnection.interruptionHandler = { [weak self] in
                self?.clearConnection()
            }
            newConnection.invalidationHandler = { [weak self] in
                self?.clearConnection()
            }
            newConnection.resume()
            self.connection = newConnection
            return newConnection
        }
    }

    private func clearConnection() {
        lock.withLock { self.connection = nil }
    }
}
