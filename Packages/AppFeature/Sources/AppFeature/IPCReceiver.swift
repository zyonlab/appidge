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

    public init(
        store: Store,
        transport: any AppSideTransport,
        connectionLogFileStore: ConnectionLogFileStore? = nil
    ) {
        self.store = store
        self.transport = transport
        self.connectionLogFileStore = connectionLogFileStore
    }

    public func start() async {
        let dispatch: @MainActor (Core.Action) -> Void = { [weak self] action in
            self?.store.dispatch(action)
        }
        let fileStore = connectionLogFileStore
        await transport.startListening { message in
            let actions = ExtensionMessageHandling.actions(for: message)
            Task {
                for action in actions {
                    await dispatch(action)
                    // 连接事件除了进内存日志,也落盘一份,好让重启后能 loadRecent 回灌。
                    if case .connectionEventReceived(let entry) = action {
                        await fileStore?.append(entry)
                    }
                }
            }
        }
    }

    public func stop() async {
        await transport.stopListening()
    }
}
