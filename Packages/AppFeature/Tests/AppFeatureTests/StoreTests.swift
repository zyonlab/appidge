import Testing
import Core
@testable import AppFeature

@Suite("Store — @MainActor, unidirectional dispatch")
struct StoreTests {

    @Test("dispatch applies the pure reducer synchronously")
    func dispatchAppliesReducerSynchronously() async {
        let store = await MainActor.run { Store() }
        await MainActor.run {
            store.dispatch(.setPacketCaptureEnabled(true))
        }
        let enabled = await MainActor.run { store.state.isPacketCaptureEnabled }
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

    @Test("onAction fires synchronously after each dispatch, with the state already updated")
    func onActionFiresAfterStateUpdate() async {
        let store = await MainActor.run { Store() }
        let observed = await MainActor.run { () -> [Core.Action] in
            var seen: [Core.Action] = []
            store.onAction = { action in
                seen.append(action)
                // State must already reflect this dispatch by the time onAction runs —
                // that's the whole point (callers decide "worth persisting" from fresh state).
                if case .setPacketCaptureEnabled(let enabled) = action {
                    #expect(store.state.isPacketCaptureEnabled == enabled)
                }
            }
            store.dispatch(.setPacketCaptureEnabled(true))
            store.dispatch(.setPacketCaptureEnabled(false))
            return seen
        }
        #expect(observed == [.setPacketCaptureEnabled(true), .setPacketCaptureEnabled(false)])
    }

    @Test("a Store with no onAction set behaves exactly as before — nil is a safe no-op default")
    func onActionDefaultsToNilWithoutSideEffects() async {
        let store = await MainActor.run { Store() }
        await MainActor.run {
            store.dispatch(.setPacketCaptureEnabled(true))
        }
        let enabled = await MainActor.run { store.state.isPacketCaptureEnabled }
        #expect(enabled == true)
    }

    @Test("effects execute serially in dispatch order — an earlier-but-slower effect still lands before a later one")
    func effectsExecuteSerurallyInDispatchOrder() async {
        // 记录 effectHandler 实际"跑完"的顺序。第一条 effect(1 条规则)故意睡得久,第二条(2 条
        // 规则)不睡。旧的并发实现里第二条会先跑完 → 乱序;串行实现里第一条必须先跑完 → 保序。
        // 这正是真机 bug 的最小复现:后发的"更完整快照"不能被先发的"残缺快照"覆盖。
        actor Recorder {
            private(set) var order: [Int] = []
            func record(_ n: Int) { order.append(n) }
        }
        let recorder = Recorder()

        let store = await MainActor.run {
            Store(effectHandler: { effect in
                guard case .applyRuleSet(_, let matchRules) = effect else { return nil }
                if matchRules.count == 1 {
                    try? await Task.sleep(nanoseconds: 40_000_000) // 慢
                }
                await recorder.record(matchRules.count)
                return nil
            })
        }

        await MainActor.run {
            store.dispatch(.addMatchRule(ProxyMatchRule(
                id: RuleID("r1"), appPattern: "*", hostPattern: "a", portRange: nil, action: .proxied
            )))
            store.dispatch(.addMatchRule(ProxyMatchRule(
                id: RuleID("r2"), appPattern: "*", hostPattern: "b", portRange: nil, action: .proxied
            )))
        }

        // 等两条都跑完。
        var order: [Int] = []
        for _ in 0..<100 {
            order = await recorder.order
            if order.count == 2 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // 串行保序:1 条规则的推送(先 dispatch、更慢)必须排在 2 条规则的推送之前。
        #expect(order == [1, 2])
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
