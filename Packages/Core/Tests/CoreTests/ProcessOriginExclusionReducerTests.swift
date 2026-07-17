import Testing
@testable import Core

@Suite("Reducer — dynamic process-origin exclusion discovery")
struct ProcessOriginExclusionReducerTests {

    @Test("default state has no dynamic origin-exclusion discovery")
    func defaultEmpty() {
        #expect(AppState().dynamicOriginExclusion == OriginExclusionDiscovery())
    }

    @Test("proxyProcessIdentitiesResolved sets the discovery and emits applyProcessOriginExclusions")
    func resolvedSetsStateAndPushes() {
        let discovery = OriginExclusionDiscovery(
            identifiers: ["com.example.xray", "com.example.v2ray"],
            executablePaths: ["/usr/local/bin/xray"]
        )
        let (state, effects) = Reducer.reduce(AppState(), .proxyProcessIdentitiesResolved(discovery))
        #expect(state.dynamicOriginExclusion == discovery)
        #expect(effects == [.applyProcessOriginExclusions(direct: discovery, hardBypass: OriginExclusionDiscovery())])
    }

    @Test("resolving the same discovery again is a no-op, no duplicate push")
    func unchangedIsNoOp() {
        let discovery = OriginExclusionDiscovery(identifiers: ["com.example.xray"])
        var (state, _) = Reducer.reduce(AppState(), .proxyProcessIdentitiesResolved(discovery))
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved(discovery))
        #expect(state.dynamicOriginExclusion == discovery)
        #expect(effects.isEmpty)
    }

    @Test("resolving an empty discovery clears previously discovered data and pushes the clear")
    func resolvingEmptyClears() {
        var (state, _) = Reducer.reduce(
            AppState(), .proxyProcessIdentitiesResolved(OriginExclusionDiscovery(identifiers: ["com.example.xray"]))
        )
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved(OriginExclusionDiscovery()))
        #expect(state.dynamicOriginExclusion == OriginExclusionDiscovery())
        #expect(effects == [.applyProcessOriginExclusions(direct: OriginExclusionDiscovery(), hardBypass: OriginExclusionDiscovery())])
    }

    @Test("a discovery that only changes executablePaths still counts as changed and pushes")
    func pathsOnlyChangeStillPushes() {
        var (state, _) = Reducer.reduce(
            AppState(), .proxyProcessIdentitiesResolved(OriginExclusionDiscovery(identifiers: ["com.example.xray"]))
        )
        let updated = OriginExclusionDiscovery(identifiers: ["com.example.xray"], executablePaths: ["/usr/local/bin/xray"])
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved(updated))
        #expect(state.dynamicOriginExclusion == updated)
        #expect(effects == [.applyProcessOriginExclusions(direct: updated, hardBypass: OriginExclusionDiscovery())])
    }
}
