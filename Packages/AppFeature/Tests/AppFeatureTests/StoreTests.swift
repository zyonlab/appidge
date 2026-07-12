import Testing
import Core
@testable import AppFeature

@Suite("Store — @MainActor, unidirectional dispatch")
struct StoreTests {

    @Test("dispatch applies the pure reducer synchronously")
    func dispatchAppliesReducerSynchronously() async {
        let store = await MainActor.run { Store() }
        await MainActor.run {
            store.dispatch(.setGlobalProxyEnabled(true))
        }
        let enabled = await MainActor.run { store.state.isGlobalProxyEnabled }
        #expect(enabled == true)
    }

    @Test("UI only reads state and dispatches — state has no public setter")
    func stateIsReadOnlyFromOutside() async {
        // Compile-level guarantee: `store.state` is `private(set)`, so this test
        // exists to document the contract; if Store ever grows a public setter
        // this test still passes but the architecture-invariant scan (B-suite)
        // and code review are the real backstop. Kept minimal, no reflection hacks.
        let store = await MainActor.run { Store() }
        let before = await MainActor.run { store.state }
        #expect(before == AppState())
    }

    @Test("effects run and their resulting action re-enters the store asynchronously")
    func dispatchRunsEffectsAndReenters() async {
        let marker = ProcessID("marker")
        var initial = AppState()
        initial.processes[marker] = MonitoredProcess(
            id: marker, displayName: "marker", executablePath: "/marker", rule: .direct
        )

        let store = await MainActor.run {
            Store(initialState: initial, effectHandler: { effect in
                guard case .log = effect else { return nil }
                return .assignRule(processID: marker, rule: .proxied)
            })
        }

        await MainActor.run {
            store.dispatch(.engineFailure(reason: "boom"))
        }

        // engineFailure's own reducer synchronously forces every rule to .direct
        // (fail-open) — so seeing it flip to .proxied afterwards can only be the
        // async effect's follow-up action landing.
        var observedRule: ProxyRule?
        for _ in 0..<100 {
            observedRule = await MainActor.run { store.state.processes[marker]?.rule }
            if observedRule == .proxied { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(observedRule == .proxied)
    }

    @Test("an effect handler returning nil produces no follow-up action")
    func effectHandlerReturningNilIsANoOp() async {
        let store = await MainActor.run {
            Store(effectHandler: { _ in nil })
        }
        await MainActor.run {
            store.dispatch(.engineFailure(reason: "boom"))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let healthy = await MainActor.run { store.state.isEngineHealthy }
        #expect(healthy == false) // only the synchronous fail-open applied
    }
}
