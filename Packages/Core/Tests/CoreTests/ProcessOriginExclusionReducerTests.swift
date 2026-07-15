import Testing
@testable import Core

@Suite("Reducer — dynamic process-origin exclusion identifiers")
struct ProcessOriginExclusionReducerTests {

    @Test("default state has no dynamic origin-exclusion identifiers")
    func defaultEmpty() {
        #expect(AppState().dynamicOriginExclusionIdentifiers.isEmpty)
    }

    @Test("proxyProcessIdentitiesResolved sets the identifiers and emits applyProcessOriginExclusions")
    func resolvedSetsStateAndPushes() {
        let identifiers: Set<String> = ["com.example.xray", "com.example.v2ray"]
        let (state, effects) = Reducer.reduce(AppState(), .proxyProcessIdentitiesResolved(identifiers))
        #expect(state.dynamicOriginExclusionIdentifiers == identifiers)
        #expect(effects == [.applyProcessOriginExclusions(identifiers)])
    }

    @Test("resolving the same identifiers again is a no-op, no duplicate push")
    func unchangedIsNoOp() {
        let identifiers: Set<String> = ["com.example.xray"]
        var (state, _) = Reducer.reduce(AppState(), .proxyProcessIdentitiesResolved(identifiers))
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved(identifiers))
        #expect(state.dynamicOriginExclusionIdentifiers == identifiers)
        #expect(effects.isEmpty)
    }

    @Test("resolving an empty set clears previously discovered identifiers and pushes the clear")
    func resolvingEmptyClears() {
        var (state, _) = Reducer.reduce(AppState(), .proxyProcessIdentitiesResolved(["com.example.xray"]))
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved([]))
        #expect(state.dynamicOriginExclusionIdentifiers.isEmpty)
        #expect(effects == [.applyProcessOriginExclusions([])])
    }
}
