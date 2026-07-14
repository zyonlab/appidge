import Testing
@testable import Core

@Suite("Reducer — active loop-detection warning raise/dismiss")
struct LoopWarningReducerTests {

    @Test("loopWarningRaised stores the signature; no effects")
    func raiseSetsWarning() {
        let (state, effects) = Reducer.reduce(AppState(), .loopWarningRaised("1.2.3.4:443"))
        #expect(state.loopWarning == "1.2.3.4:443")
        #expect(effects.isEmpty)
    }

    @Test("a later raise overwrites the previous signature")
    func raiseOverwrites() {
        var state = AppState()
        state = Reducer.reduce(state, .loopWarningRaised("a:1")).0
        state = Reducer.reduce(state, .loopWarningRaised("b:2")).0
        #expect(state.loopWarning == "b:2")
    }

    @Test("dismissLoopWarning clears it back to nil")
    func dismissClears() {
        var state = AppState(loopWarning: "1.2.3.4:443")
        state = Reducer.reduce(state, .dismissLoopWarning).0
        #expect(state.loopWarning == nil)
    }
}
