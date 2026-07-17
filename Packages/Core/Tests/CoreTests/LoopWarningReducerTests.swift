import Testing
@testable import Core

@Suite("Reducer — 环告警:忽略过的 signature 不再重复弹")
struct LoopWarningReducerTests {

    @Test("首次告警写入 loopWarning")
    func firstWarningShows() {
        let (state, effects) = Reducer.reduce(AppState(), .loopWarningRaised("1.2.3.4:443"))
        #expect(state.loopWarning == "1.2.3.4:443")
        #expect(effects.isEmpty)
    }

    @Test("dismiss 记住 signature,同一 signature 再次上报不再弹;不同 signature 照常弹")
    func dismissSuppressesRepeat() {
        var (state, _) = Reducer.reduce(AppState(), .loopWarningRaised("1.2.3.4:443"))
        (state, _) = Reducer.reduce(state, .dismissLoopWarning)
        #expect(state.loopWarning == nil)
        #expect(state.dismissedLoopSignatures.contains("1.2.3.4:443"))

        // 扩展侧检测器每次命中都会投递——忽略过的不再打扰。
        (state, _) = Reducer.reduce(state, .loopWarningRaised("1.2.3.4:443"))
        #expect(state.loopWarning == nil)

        // 新的 signature 是新问题,照常提醒。
        (state, _) = Reducer.reduce(state, .loopWarningRaised("5.6.7.8:443"))
        #expect(state.loopWarning == "5.6.7.8:443")
    }

    @Test("无告警时 dismiss 是纯 no-op(不误记任何 signature)")
    func dismissWithoutWarningIsNoOp() {
        let (state, _) = Reducer.reduce(AppState(), .dismissLoopWarning)
        #expect(state.dismissedLoopSignatures.isEmpty)
    }
}
