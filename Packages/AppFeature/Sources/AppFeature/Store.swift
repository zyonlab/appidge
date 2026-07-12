import Observation
import Core

/// 单向数据流的唯一入口：UI 只读 ``state``、只 ``dispatch(_:)``。
/// reduce 是纯函数（见 Core），副作用只在 Effect 里、只在后台 Task.detached 执行，
/// 结果以新的 Action 回灌 store —— 绝不从后台直接改 state。
@MainActor
@Observable
public final class Store {
    public private(set) var state: Core.AppState
    private let effectHandler: @Sendable (Core.Effect) async -> Core.Action?

    public init(
        initialState: Core.AppState = Core.AppState(),
        effectHandler: @escaping @Sendable (Core.Effect) async -> Core.Action? = { _ in nil }
    ) {
        self.state = initialState
        self.effectHandler = effectHandler
    }

    public func dispatch(_ action: Core.Action) {
        let (nextState, effects) = Core.Reducer.reduce(state, action)
        state = nextState
        guard !effects.isEmpty else { return }

        let runEffect = effectHandler
        let redispatch: @MainActor (Core.Action) -> Void = { [weak self] followUp in
            self?.dispatch(followUp)
        }
        for effect in effects {
            Task.detached {
                guard let followUp = await runEffect(effect) else { return }
                await redispatch(followUp)
            }
        }
    }
}
