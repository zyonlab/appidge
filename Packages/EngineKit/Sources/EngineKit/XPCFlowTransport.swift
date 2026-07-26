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
    /// app 每次(重)连上时自动投递给它的一条消息(如扩展版本握手 `.extensionReady`)——
    /// 让 app 一连上就知道"是哪个 provider 实例在服务",据此检测会话是否绑在旧扩展上。
    private var readyMessage: ExtensionToAppMessage?
    /// 在途的注册自检探针(见 `probeSelfRegistration`);delegate 按 pid 识别到自己的探针连接
    /// 时经它回报成功。nil = 没有在途探针。
    private var pendingProbe: SelfProbeToken?

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

    /// 设置 app 每次连上时自动投递的握手消息(见 `readyMessage`);nil 清除。
    public func setReadyMessage(_ message: ExtensionToAppMessage?) {
        lock.withLock { readyMessage = message }
    }

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

    /// **注册自检探针**:从扩展进程内部向同一 mach service 发起一条连接,验证 listener 真的
    /// 注册成功且由**本进程**持有。为什么需要:升级换血窗口里,新扩展进程可能在新旧 launchd job
    /// 交替的竞态中被拉起,`NSXPCListener(machServiceName:)` 注册**静默失败**(API 没有任何错误
    /// 回调),app 侧 bootstrap look-up 报 "No such process"——扩展自己毫无感知地空转。
    ///
    /// 判定:delegate 收到 pid == 本进程的连接 = 探针到达了自己 → 注册成功(delegate 里拒绝该
    /// 连接,绝不让探针顶掉 app 的真实连接)。连接被 invalidate(无人监听)或超时(旧进程仍占着
    /// 名字,探针被路由过去、我们的 delegate 永远收不到)→ 注册失败。探针 payload 是解不出
    /// `AppToExtensionMessage` 的哨兵字节,误达旧进程也只是被静默丢弃,无副作用。
    ///
    /// completion 恰好回调一次(成功/失败/超时先到先得),在任意队列上。
    public func probeSelfRegistration(
        timeoutSeconds: Double = 2.0, completion: @escaping @Sendable (Bool) -> Void
    ) {
        let token = SelfProbeToken { [weak self] outcome in
            self?.lock.withLock { self?.pendingProbe = nil }
            completion(outcome)
        }
        lock.withLock { pendingProbe = token }

        let probe = NSXPCConnection(machServiceName: XPCTransportConfig.machServiceName)
        probe.remoteObjectInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        // 连接交给 token 持有:完成(成功/失败/超时,先到者生效)时统一 invalidate,
        // 各 @Sendable 闭包只捕获 @unchecked Sendable 的 token,不直接捕获 NSXPCConnection。
        token.attach(probe)
        probe.invalidationHandler = { token.complete(false) }
        probe.interruptionHandler = { token.complete(false) }
        probe.resume()
        let proxy = probe.remoteObjectProxyWithErrorHandler { _ in
            token.complete(false)
        } as? ExtensionXPCProtocol
        proxy?.send(Self.selfProbePayload)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            token.complete(false) // 已完成则 no-op(once 语义)
        }
    }

    /// 自检探针的哨兵 payload:解不出 `AppToExtensionMessage` 的字节——无论到达谁(自己/旧进程)
    /// 都会在 `send(_:)` 解码失败被静默丢弃。判定完全靠 delegate 的 pid 识别,不靠消息内容回传。
    private static let selfProbePayload = Data("appidge.xpc.self-probe".utf8)

    /// 重建 listener 再抢一次 mach service:首次注册失败可能只是竞态窗口(旧 job 还没死透、
    /// 名字还被占着);旧 job 死掉后名字释放,重建即可在进程内自愈,不必走到「退出重生」。
    /// 从未 `startListeningForAppMessages` 过(或已 `invalidate`)则 no-op。
    public func recreateListener() {
        let old: NSXPCListener? = lock.withLock {
            guard appMessageHandler != nil else { return nil }
            let existing = listener
            listener = nil
            return existing
        }
        guard let old else { return }
        old.invalidate()
        let fresh = NSXPCListener(machServiceName: XPCTransportConfig.machServiceName)
        fresh.delegate = self
        lock.withLock { listener = fresh }
        fresh.resume()
    }

    /// 停止监听并释放 mach service:`invalidate()` 掉 `NSXPCListener`,清掉当前连接。
    /// **必须在 `stopProxy` 里调**——否则旧监听器泄漏、仍占着同一个 mach service;下次 `startProxy`
    /// 新建的监听器与它抢同一服务,新 app 连上被路由到旧监听器/旧 transport,而 router 用新 transport
    /// 投 flow,两边对不上 → flow 全丢(真机实锤的「退出重开会话通但收不到 flow」)。
    public func invalidate() {
        let existing = lock.withLock { () -> NSXPCListener? in
            let l = listener
            listener = nil
            currentConnection = nil
            appMessageHandler = nil
            return l
        }
        existing?.invalidate()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 本进程发来的连接 = 注册自检探针(见 probeSelfRegistration):回报「注册成功、服务由我持有」,
        // 然后**拒绝**——绝不让探针顶掉 currentConnection 里 app 的真实连接。
        if newConnection.processIdentifier == getpid() {
            let probe = lock.withLock { pendingProbe }
            probe?.complete(true)
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: AppXPCProtocol.self)

        newConnection.interruptionHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }

        let ready = lock.withLock { () -> ExtensionToAppMessage? in
            currentConnection = newConnection
            return readyMessage
        }
        newConnection.resume()
        // app 一连上就投递握手消息(如扩展版本),让它立刻能判断会话绑的是不是最新 provider。
        if let ready, let data = try? JSONEncoder().encode(ready) {
            (newConnection.remoteObjectProxyWithErrorHandler { _ in } as? AppXPCProtocol)?.send(data)
        }
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

/// 自检探针的**恰好一次**完成语义:成功(delegate pid 识别)/失败(连接失效、错误)/超时三条
/// 路径都可能先到,先到者生效、其余 no-op。跟宿主同款 `@unchecked Sendable` + 显式锁
/// ——回调来自 XPC runtime 的任意队列。
private final class SelfProbeToken: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?
    /// 探针连接由 token 代持(NSXPCConnection 非 Sendable,不能被各 @Sendable 闭包直接捕获;
    /// 按文档它本身线程安全),完成时统一 invalidate。
    private var connection: NSXPCConnection?

    init(_ completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func attach(_ connection: NSXPCConnection) {
        lock.withLock { self.connection = connection }
    }

    func complete(_ success: Bool) {
        let (handler, probe) = lock.withLock { () -> ((@Sendable (Bool) -> Void)?, NSXPCConnection?) in
            let existing = completion
            completion = nil
            let conn = connection
            connection = nil
            return (existing, conn)
        }
        // 在 invalidationHandler 里再 invalidate 自己是安全的 no-op。
        probe?.invalidate()
        handler?(success)
    }
}
