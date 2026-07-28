import Testing
@testable import Core

/// 配置对账(第 2 层闭环):扩展定期上报「已落地配置」指纹,app 与「当前 state 会推出去什么」
/// 的期望指纹比对——不一致 = 分叉,全量 resync 自愈。指纹计算在 AppFeature/IPCContract
/// (Core 认不得 wire DTO),reducer 只做纯字符串比对 + 决策,expected 由接线层随 action 注入。
@Suite("Reducer — 配置指纹对账:失配即 resync,连击计数,恢复归零")
struct ConfigReconciliationReducerTests {

    private var readyState: AppState {
        var state = AppState(isConfigurationReplayComplete: true)
        state.rules = [ProxyMatchRule(
            id: RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]
        return state
    }

    @Test("指纹一致:无 effect,连击清零")
    func matchClearsStreak() {
        var state = readyState
        state.configFingerprintMismatchStreak = 2
        let (next, effects) = Reducer.reduce(state, .configFingerprintReported(reported: "abc", expected: "abc"))
        #expect(next.configFingerprintMismatchStreak == 0)
        #expect(effects.isEmpty)
    }

    @Test("指纹一致且连击本就为零:纯 no-op(state 不变)")
    func matchWithZeroStreakIsNoOp() {
        let state = readyState
        let (next, effects) = Reducer.reduce(state, .configFingerprintReported(reported: "abc", expected: "abc"))
        #expect(next == state)
        #expect(effects.isEmpty)
    }

    @Test("指纹失配:连击 +1,产出全量 resync 六条推送(自愈)+ 一条日志")
    func mismatchTriggersResync() {
        let state = readyState
        let (next, effects) = Reducer.reduce(state, .configFingerprintReported(reported: "aaa", expected: "bbb"))
        #expect(next.configFingerprintMismatchStreak == 1)
        // 六条推送 + 1 条日志;推送内容与 resyncExtension 完全一致(排除名单先行、规则集殿后)。
        let (_, resyncEffects) = Reducer.reduce(state, .resyncExtension)
        #expect(Array(effects.prefix(resyncEffects.count)) == resyncEffects)
        #expect(effects.count == resyncEffects.count + 1)
    }

    @Test("expected 为 nil(恢复门没开,期望态尚无意义):纯 no-op,不计连击")
    func nilExpectedIsNoOp() {
        let state = AppState()
        let (next, effects) = Reducer.reduce(state, .configFingerprintReported(reported: "aaa", expected: nil))
        #expect(next == state)
        #expect(effects.isEmpty)
    }

    @Test("连续失配持续计数(observability:≥3 视为持续分叉,UI 可据此升级警告)")
    func consecutiveMismatchesAccumulate() {
        var state = readyState
        for expectedStreak in 1...4 {
            let (next, _) = Reducer.reduce(state, .configFingerprintReported(reported: "aaa", expected: "bbb"))
            #expect(next.configFingerprintMismatchStreak == expectedStreak)
            state = next
        }
    }
}
