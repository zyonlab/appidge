import Testing
@testable import Core

@Suite("Reducer — 系统扩展激活状态如实回灌 store")
struct ExtensionActivationReducerTests {

    @Test("默认状态是 .inactive(还没提交激活请求)")
    func defaultInactive() {
        #expect(AppState().extensionActivation == .inactive)
    }

    @Test(
        "extensionActivationChanged 把状态写进 state,不产生副作用",
        arguments: [
            ExtensionActivation.activating,
            .disabled,
            .needsApproval,
            .active,
            .failed(reason: "code signature invalid"),
            .inactive
        ]
    )
    func setsActivation(activation: ExtensionActivation) {
        let (state, effects) = Reducer.reduce(AppState(), .extensionActivationChanged(activation))
        #expect(state.extensionActivation == activation)
        #expect(effects.isEmpty)
    }

    @Test("只有 .active 时 isRunning 为真")
    func isRunningOnlyWhenActive() {
        #expect(ExtensionActivation.active.isRunning)
        for other: ExtensionActivation in [.inactive, .activating, .needsApproval, .disabled, .failed(reason: "x")] {
            #expect(!other.isRunning)
        }
    }

    @Test("扩展激活状态与引擎健康度彼此独立:engineFailure 不动 extensionActivation")
    func orthogonalToEngineHealth() {
        let active = AppState(extensionActivation: .active)
        let (afterFailure, _) = Reducer.reduce(active, .engineFailure(reason: "transport crashed"))
        #expect(afterFailure.extensionActivation == .active) // 扩展还装着,只是引擎回退直连
        #expect(!afterFailure.isEngineHealthy)
    }
}
