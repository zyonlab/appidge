import Core
import Dispatch
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

    public init(
        store: Store,
        transport: any AppSideTransport,
        connectionLogFileStore: ConnectionLogFileStore? = nil,
        coalesceWindow: Duration = .milliseconds(250)
    ) {
        self.store = store
        self.transport = transport
        self.connectionLogFileStore = connectionLogFileStore
        self.coalesceWindow = coalesceWindow
    }

    public func start() async {
        let dispatch: @MainActor (Core.Action) -> Void = { [weak self] action in
            self?.store.dispatch(action)
        }
        let enqueue: @MainActor (Core.ConnectionLogEntry) -> Void = { [weak self] entry in
            self?.enqueueConnectionEntry(entry)
        }
        let fileStore = connectionLogFileStore
        await transport.startListening { message in
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
        let started = DispatchTime.now().uptimeNanoseconds
        store.dispatch(.connectionEventsReceived(batch))
        // 这一段是**主线程**上的 reducer 工作（按 id 去重 + 环形缓冲维护 + 触发 SwiftUI 重算）。
        // 埋点回调由 App 层注入，AppFeature 不反向依赖 App。
        PerfHooks.onConnectionBatch?(DispatchTime.now().uptimeNanoseconds &- started, batch.count)
    }

    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        flushPendingConnectionEntries()
        await transport.stopListening()
    }
}

/// 供 App 层注入的性能埋点钩子（AppFeature 不反向依赖 App，故用回调而非直接引用 App 的 PerfDiag）。
/// **临时诊断用**：确认完性能瓶颈后与 App 侧 PerfDiag 一并移除。
public enum PerfHooks {
    /// (这批连接事件落进 Store 的耗时纳秒, 批大小)。nil = 未启用埋点，热路径零开销。
    nonisolated(unsafe) public static var onConnectionBatch: ((UInt64, Int) -> Void)?
}
