import Core
import IPCContract

/// 把 ``AppSideTransport`` 收到的扩展消息接进 ``Store``：`start()` 之后，每条
/// `ExtensionToAppMessage` 先经 ``ExtensionMessageHandling`` 翻成 `[Core.Action]`，
/// 再逐个 `dispatch` 进 store。这条链路本身没有独立的业务逻辑（翻译在
/// ExtensionMessageHandling，状态变更在 Reducer），IPCReceiver 只是接线。
///
/// `AppSideTransport.startListening` 的回调类型是 `@escaping @Sendable
/// (ExtensionToAppMessage) -> Void`——非 MainActor 隔离、同步。为了安全地跳回
/// `store.dispatch`（`@MainActor` 隔离），复用 `Store.dispatch` 已经验证过的手法
/// （见 PROGRESS.md「失败尝试 #2」）：先构造一个 `@MainActor (Action) -> Void`
/// 闭包（只在这个闭包内 weak capture self），全局 actor 隔离的闭包类型本身是
/// Sendable，可以被外层 `@Sendable` 闭包安全捕获；真正调用时用 `await` 跳回主 actor。
@MainActor
public final class IPCReceiver {
    private let store: Store
    private let transport: any AppSideTransport
    /// 可选:每条连接事件顺带落盘(rolling JSONL),重启后由 App 用 `loadRecent` 回灌。
    /// nil 则只走内存(既有行为),现有测试不受影响。
    private let connectionLogFileStore: ConnectionLogFileStore?

    /// 连接事件合并窗口:代理流量稳定时扩展每秒投很多条连接事件,逐条 dispatch 会让昂贵的
    /// 连接表(500 行 filter+sort+layout)每条都重渲染(真机采样实锤 app CPU 大头)。这里
    /// 按 `coalesceWindow` 攒一批、一次性 `.connectionEventsReceived` 落地——Table 重渲染频率
    /// 与事件速率解耦(与扩展侧 flowStats 批量推送同一套架构思路)。其余消息类型立即 dispatch。
    private let coalesceWindow: Duration
    private var pendingConnectionEntries: [Core.ConnectionLogEntry] = []
    private var flushTask: Task<Void, Never>?

    /// 排除名单消息里的宿主 app bundle 路径(App 层传 `Bundle.main` 的真实路径)——期望指纹
    /// 必须与 effectHandler 下发时用的同一个值,否则对账恒失配。测试可注 nil/固定值。
    private let hostAppBundlePath: String?

    public init(
        store: Store,
        transport: any AppSideTransport,
        connectionLogFileStore: ConnectionLogFileStore? = nil,
        coalesceWindow: Duration = .milliseconds(250),
        hostAppBundlePath: String? = nil
    ) {
        self.store = store
        self.transport = transport
        self.connectionLogFileStore = connectionLogFileStore
        self.coalesceWindow = coalesceWindow
        self.hostAppBundlePath = hostAppBundlePath
    }

    public func start() async {
        let dispatch: @MainActor (Core.Action) -> Void = { [weak self] action in
            self?.store.dispatch(action)
        }
        let enqueue: @MainActor (Core.ConnectionLogEntry) -> Void = { [weak self] entry in
            self?.enqueueConnectionEntry(entry)
        }
        // 配置对账:指纹上报不走纯映射(需要拿当前 state 算期望指纹再注入 action),在这里
        // 特殊接线——回主 actor 读 state、算 expected、dispatch 双值 action,比对在 reducer。
        let reconcile: @MainActor (String) -> Void = { [weak self] reported in
            guard let self else { return }
            let expected = ExpectedConfigFingerprint.compute(
                state: self.store.state, hostAppBundlePath: self.hostAppBundlePath
            )
            self.store.dispatch(.configFingerprintReported(reported: reported, expected: expected))
        }
        let fileStore = connectionLogFileStore
        await transport.startListening { message in
            if case .configFingerprintReported(let reported) = message {
                Task { await reconcile(reported) }
                return
            }
            let actions = ExtensionMessageHandling.actions(for: message)
            Task {
                for action in actions {
                    // 连接事件走合并窗口(降低连接表重渲染频率);其余立即 dispatch。
                    if case .connectionEventReceived(let entry) = action {
                        await enqueue(entry)
                        await fileStore?.append(entry)
                    } else {
                        await dispatch(action)
                    }
                }
            }
        }
    }

    /// 攒入一条连接事件,并确保有一个在窗口末尾统一 flush 的任务在跑(已在跑就不重排)。
    private func enqueueConnectionEntry(_ entry: Core.ConnectionLogEntry) {
        pendingConnectionEntries.append(entry)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.coalesceWindow ?? .milliseconds(250))
            self?.flushPendingConnectionEntries()
        }
    }

    /// 把攒下的连接事件作为**一个**批量 action 落地(一次 state 变更 → 连接表只重渲染一次)。
    private func flushPendingConnectionEntries() {
        flushTask = nil
        guard !pendingConnectionEntries.isEmpty else { return }
        let batch = pendingConnectionEntries
        pendingConnectionEntries.removeAll(keepingCapacity: true)
        store.dispatch(.connectionEventsReceived(batch))
    }

    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        flushPendingConnectionEntries()
        await transport.stopListening()
    }
}
