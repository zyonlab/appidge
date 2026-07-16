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
    /// 每次 dispatch 应用完 reducer 之后的旁路通知(不参与 reduce、不影响 state/effects)。
    /// 用途：让外层(App 层)据 action 类型编排"这个改动值得存盘"之类的策略，不用把持久化
    /// 逻辑塞进 Store 或 Core——Store 仍然只管单向数据流本身。默认 nil,不设置就没有任何行为变化。
    public var onAction: (@MainActor (Core.Action) -> Void)?

    public init(
        initialState: Core.AppState = Core.AppState(),
        effectHandler: @escaping @Sendable (Core.Effect) async -> Core.Action? = { _ in nil }
    ) {
        self.state = initialState
        self.effectHandler = effectHandler
    }

    /// 待执行 effect 的 FIFO 队列 + 是否有消费者在跑。之前每个 effect 各起一个 `Task.detached`,
    /// 彼此**并发乱序**——启动恢复时十几个 `applyRuleSet` 全量快照推送并发到达扩展,最后落地的
    /// 那个说了算,如果是某个"规则还没加全"的中间态,扩展的规则表就被覆盖成残缺/空的(真机实锤:
    /// 扩展空转、活动栏一条都进不来)。改成**单消费者串行**:effect 严格按产生顺序(dispatch 在
    /// `@MainActor` 上本就是串行的)逐个执行,保证同类推送后发的一定后到,最新状态永远胜出。
    private var effectQueue: [Core.Effect] = []
    private var isDrainingEffects = false

    public func dispatch(_ action: Core.Action) {
        let (nextState, effects) = Core.Reducer.reduce(state, action)
        state = nextState
        // 不管这次 dispatch 有没有产生 effect 都通知——调用方判断"值不值得存盘"只看 action
        // 类型,跟这次有没有副作用无关(比如 assignRule 总是值得存,不管 ruleSetPush 有没有发出)。
        onAction?(action)
        guard !effects.isEmpty else { return }
        effectQueue.append(contentsOf: effects)
        drainEffects()
    }

    /// 串行地把队列里的 effect 一个个跑完。已经在跑就直接返回(新 effect 已进队,当前循环会捞到)。
    /// effect 的副作用(XPC 发送、扫描、诊断)本身是非 `@MainActor` 的 async 闭包,`await` 时会
    /// 离开主 actor 去干活、干完回来;主 actor 只用来串行地"取下一个 / 回灌 followUp",不阻塞。
    private func drainEffects() {
        guard !isDrainingEffects else { return }
        isDrainingEffects = true
        let runEffect = effectHandler
        Task { @MainActor [weak self] in
            while let effect = self?.effectQueue.first {
                self?.effectQueue.removeFirst()
                let followUp = await runEffect(effect)
                if let followUp { self?.dispatch(followUp) }
            }
            self?.isDrainingEffects = false
        }
    }
}
