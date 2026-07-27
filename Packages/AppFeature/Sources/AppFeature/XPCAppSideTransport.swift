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
///
/// **重连退避(必须有,真机实锤)**:扩展在系统设置里被**停用**后,mach service 无人监听、
/// 连接一建立就 invalidate。没有退避时会形成自持风暴:send() 的懒重连(无延迟)每次新建连接
/// 都触发 `onConnect` → app dispatch resyncExtension → 6 条 send → 每条又新建连接 → 又触发
/// onConnect……app 本体被打到 100%+ CPU。现在断开按 ``ReconnectBackoff`` 指数退避
/// (1s→2s→…→封顶 30s),**冷却期内 send() 不新建连接、消息直接丢弃**(重连成功后
/// onConnect → resync 会全量补推,丢弃无损);收到扩展任何真实消息(链路证实健康)即归零。
public final class XPCAppSideTransport: NSObject, AppSideTransport, AppXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var onMessage: (@Sendable (ExtensionToAppMessage) -> Void)?
    private var isListening = false
    private var backoff = ReconnectBackoff()
    /// 这个时刻(epoch 秒)之前不允许新建连接(冷却)。
    private var cooldownUntil: TimeInterval = 0
    /// 已有一个延迟重连 Task 在路上,别再排第二个。
    private var reconnectScheduled = false
    /// 每当**新建**一条到扩展的连接时触发一次(复用已有连接不触发)。集成方(app)据此把当前
    /// 完整配置全量重推给扩展(`Action.resyncExtension`)——扩展升级/重启/XPC 掉线重连后,
    /// 扩展是空规则起步的,必须由 app 主动补推,否则它一直空转。断线后会自动重连,重连成功即再触发。
    private var onConnect: (@Sendable () -> Void)?
    /// 通道可达性**翻转沿**回调(true=恢复可达,false=判为不可达)。判据是 `ReconnectBackoff`
    /// 的连续掉线阈值(见 `isChannelConsideredUnreachable`);集成方据此 dispatch
    /// `.xpcChannelReachabilityChanged`,把「扩展监听器注册失败」从静默重试升级成显式警告。
    private var onReachabilityChange: (@Sendable (Bool) -> Void)?
    /// 上一次已通知出去的可达性,只在翻转时再通知(初始视为可达——没有失败证据前不误报)。
    private var lastNotifiedReachable = true

    /// mach service 连接候选表(非空;经 ``IPCContract/XPCTransportConfig/connectionCandidates(preferred:)``
    /// 构造:内嵌扩展 plist 读出的版本化名优先、legacy 兜底)。选哪个由 ``ReconnectBackoff/candidateIndex``
    /// 按连续掉线计数轮换——健康期恒用版本化名;升级窗口里系统还在跑旧扩展(监听 legacy 名)时,
    /// 掉一次线即回退到 legacy 连上旧扩展,版本握手/自愈照常工作。
    private let serviceNameCandidates: [String]

    public init(serviceNameCandidates: [String] = [XPCTransportConfig.machServiceName]) {
        // 防御:空候选表退回 legacy 单候选,连接路径永不无名可用。
        self.serviceNameCandidates = serviceNameCandidates.isEmpty
            ? [XPCTransportConfig.machServiceName]
            : serviceNameCandidates
        super.init()
    }

    /// 设置"连上扩展"回调。幂等,后设覆盖先设。传 nil 清除。
    public func setOnConnect(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { self.onConnect = handler }
    }

    /// 设置通道可达性翻转回调。幂等,后设覆盖先设。传 nil 清除。
    public func setOnReachabilityChange(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.withLock { self.onReachabilityChange = handler }
    }

    // MARK: - AppSideTransport

    public func send(_ message: AppToExtensionMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }
        // 冷却期内拿不到连接:直接丢弃。重连成功后 onConnect → resyncExtension 全量补推,无损。
        guard let conn = currentConnection() else { return }
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
        let (listening, handler) = lock.withLock { () -> (Bool, (@Sendable (ExtensionToAppMessage) -> Void)?) in
            // 扩展真的发来了消息 = 链路证实健康,退避归零(下次断开又从 1s 起步)。
            self.backoff.reset()
            return (self.isListening, self.onMessage)
        }
        notifyReachabilityIfFlipped()
        guard listening, let handler else { return }
        guard let message = try? JSONDecoder().decode(ExtensionToAppMessage.self, from: data) else { return }
        handler(message)
    }

    // MARK: - 连接管理

    /// 返回一条可用的连接：已有的活跃连接直接复用，没有就新建一条并 `resume()`;
    /// **冷却期内返回 nil**(不新建,调用方丢弃本次发送)。
    /// 整个「查一次、没有就建」在同一次加锁内完成，避免并发 send() 时重复建连接。
    /// **新建**连接时(而非复用)在锁外触发一次 `onConnect`——让 app 全量重推配置。
    private func currentConnection() -> NSXPCConnection? {
        let (conn, isNew) = lock.withLock { () -> (NSXPCConnection?, Bool) in
            if let existing = self.connection {
                return (existing, false)
            }
            guard Date().timeIntervalSince1970 >= self.cooldownUntil else {
                return (nil, false)
            }
            let newConnection = NSXPCConnection(
                machServiceName: serviceNameCandidates[
                    backoff.candidateIndex(candidateCount: serviceNameCandidates.count)
                ],
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

    /// 连接中断/失效:清掉存住的连接。若仍在监听(app 还想收扩展消息 = 还在使用中),就按退避
    /// 延迟安排一次自动重连——扩展升级/重启后旧连接会断,若不主动重连,得等到下一次用户改配置
    /// 才 `send()` 重连,期间扩展一直空转、活动栏空白。
    /// 重连即新建连接 → 再次触发 `onConnect` → app 重推配置,形成自愈闭环;扩展被停用时按
    /// 指数退避拉长到最多 30s 一次,不再空耗 CPU(见类型注释的「重连退避」)。
    /// 可达性(由退避的连续掉线数派生)相对上次通知发生翻转时,在锁外回调一次。
    /// 掉线路径与收消息路径都调它——两条路径都可能改变判定。
    private func notifyReachabilityIfFlipped() {
        let notification: (@Sendable (Bool) -> Void, Bool)? = lock.withLock {
            let reachable = !backoff.isChannelConsideredUnreachable
            guard reachable != lastNotifiedReachable, let handler = onReachabilityChange else { return nil }
            lastNotifiedReachable = reachable
            return (handler, reachable)
        }
        guard let (handler, reachable) = notification else { return }
        handler(reachable)
    }

    private func handleConnectionDropped() {
        let delay: Double? = lock.withLock {
            self.connection = nil
            guard self.isListening else { return nil }
            self.backoff.recordDrop()
            let delay = self.backoff.delaySeconds
            self.cooldownUntil = Date().timeIntervalSince1970 + delay
            guard !self.reconnectScheduled else { return nil }
            self.reconnectScheduled = true
            return delay
        }
        notifyReachabilityIfFlipped()
        guard let delay else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let listening = self.lock.withLock { () -> Bool in
                self.reconnectScheduled = false
                return self.isListening
            }
            guard listening else { return }
            _ = self.currentConnection()   // 新建 → 触发 onConnect → app 重推
        }
    }
}

/// XPC 重连的指数退避(纯值,单测见 ReconnectBackoffTests):连续断开 1s → 2s → 4s → …
/// 封顶 30s;`reset()` 后从头来。为什么封顶 30s:扩展被停用是用户主动状态,可能持续很久,
/// 但用户在系统设置里重新打开后,最多 30s 内自动重连自愈,不需要重启 app。
struct ReconnectBackoff: Sendable, Equatable {
    private(set) var consecutiveDrops = 0

    /// 连续掉线达到几次判「通道不可达」。3 次(退避 1s+2s 后的第三次失败,首次失败后 ~7s 内落定):
    /// 正常升级/重启的重连抖动通常 1-2 次内恢复,不误报;监听器注册失败(bootstrap look-up
    /// "No such process")则会一直掉,快速越过阈值。
    static let unreachableThreshold = 3

    mutating func recordDrop() { consecutiveDrops += 1 }
    mutating func reset() { consecutiveDrops = 0 }

    /// 下一次允许重连的延迟(秒)。从未断开 = 0(立即可连)。
    var delaySeconds: Double {
        guard consecutiveDrops > 0 else { return 0 }
        let exponential = pow(2.0, Double(consecutiveDrops - 1))
        return min(30, exponential)
    }

    /// 通道是否该被判为不可达(连续掉线过阈值,期间没收到过任何扩展消息)。
    /// 供 transport 在翻转沿回调 app(→ `.xpcChannelReachabilityChanged`),UI 据此显式警告,
    /// 不再让「扩展监听器注册失败」停留在静默重试里。
    var isChannelConsideredUnreachable: Bool { consecutiveDrops >= Self.unreachableThreshold }

    /// mach service 候选轮换:健康期(0 掉线)用首选(版本化名),每掉一次线换下一个候选,
    /// 取模回绕;`reset()`(链路证实健康)后回到首选。选择只依赖连续掉线计数,不引入新状态。
    /// 零候选返回 0(调用方守卫非空,这里只保证不除零)。
    func candidateIndex(candidateCount: Int) -> Int {
        guard candidateCount > 0 else { return 0 }
        return consecutiveDrops % candidateCount
    }
}
