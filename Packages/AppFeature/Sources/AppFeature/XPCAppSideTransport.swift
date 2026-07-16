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
    /// 每当**新建**一条到扩展的连接时触发一次(复用已有连接不触发)。集成方(app)据此把当前
    /// 完整配置全量重推给扩展(`Action.resyncExtension`)——扩展升级/重启/XPC 掉线重连后,
    /// 扩展是空规则起步的,必须由 app 主动补推,否则它一直空转。断线后会自动重连,重连成功即再触发。
    private var onConnect: (@Sendable () -> Void)?

    override public init() {
        super.init()
    }

    /// 设置"连上扩展"回调。幂等,后设覆盖先设。传 nil 清除。
    public func setOnConnect(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { self.onConnect = handler }
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
    /// **新建**连接时(而非复用)在锁外触发一次 `onConnect`——让 app 全量重推配置。
    private func currentConnection() -> NSXPCConnection {
        let (conn, isNew) = lock.withLock { () -> (NSXPCConnection, Bool) in
            if let existing = self.connection {
                return (existing, false)
            }
            let newConnection = NSXPCConnection(
                machServiceName: XPCTransportConfig.machServiceName,
                options: []
            )
            newConnection.exportedInterface = NSXPCInterface(with: AppXPCProtocol.self)
            newConnection.exportedObject = self
            newConnection.remoteObjectInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
            newConnection.interruptionHandler = { [weak self] in
                self?.handleConnectionDropped()
            }
            newConnection.invalidationHandler = { [weak self] in
                self?.handleConnectionDropped()
            }
            newConnection.resume()
            self.connection = newConnection
            return (newConnection, true)
        }
        if isNew {
            // 锁外触发,避免 onConnect 里回调进 send()→currentConnection() 造成重入死锁。
            let handler = lock.withLock { self.onConnect }
            handler?()
        }
        return conn
    }

    /// 连接中断/失效:清掉存住的连接。若仍在监听(app 还想收扩展消息 = 还在使用中),就安排一次
    /// 自动重连——扩展升级/重启后旧连接会断,若不主动重连,得等到下一次用户改配置才 `send()` 重连,
    /// 期间扩展一直空转、活动栏空白。延迟 1s 是给扩展留重启窗口,也避免扩展彻底没了时的紧凑重试。
    /// 重连即新建连接 → 再次触发 `onConnect` → app 重推配置,形成自愈闭环。
    private func handleConnectionDropped() {
        let shouldReconnect = lock.withLock { () -> Bool in
            self.connection = nil
            return self.isListening
        }
        guard shouldReconnect else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.lock.withLock({ self.isListening }) else { return }
            _ = self.currentConnection()   // 新建 → 触发 onConnect → app 重推
        }
    }
}
