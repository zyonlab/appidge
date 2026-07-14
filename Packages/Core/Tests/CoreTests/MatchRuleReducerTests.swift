import Testing
@testable import Core

@Suite("Reducer — match-rule list (add / remove / reorder) + rule-set push")
struct MatchRuleReducerTests {

    private func rule(_ id: String, host: String = "*", _ action: ProxyRule = .proxied) -> ProxyMatchRule {
        ProxyMatchRule(id: RuleID(id), appPattern: "*", hostPattern: host, portRange: nil, action: action)
    }

    @Test("addMatchRule appends to the ordered list and pushes the rule set")
    func addMatchRule() {
        let r = rule("1", host: "*.corp")
        let (next, effects) = Reducer.reduce(AppState(), .addMatchRule(r))
        #expect(next.rules == [r])
        #expect(effects == [.applyRuleSet(globalProxyEnabled: false, assignments: [:], matchRules: [r])])
    }

    @Test("addMatchRule preserves insertion order")
    func addPreservesOrder() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        #expect(state.rules.map(\.id) == [RuleID("1"), RuleID("2")])
    }

    @Test("removeMatchRule drops by id, keeps the rest in order")
    func removeMatchRule() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("3")))
        let (next, effects) = Reducer.reduce(state, .removeMatchRule(RuleID("2")))
        #expect(next.rules.map(\.id) == [RuleID("1"), RuleID("3")])
        #expect(effects == [.applyRuleSet(globalProxyEnabled: false, assignments: [:], matchRules: next.rules)])
    }

    @Test("removeMatchRule for an unknown id is a no-op with no push")
    func removeUnknown() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        let (next, effects) = Reducer.reduce(state, .removeMatchRule(RuleID("ghost")))
        #expect(next.rules.map(\.id) == [RuleID("1")])
        #expect(effects.isEmpty)
    }

    @Test("reorderMatchRules reorders to match the given id order and pushes")
    func reorder() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("3")))
        let (next, effects) = Reducer.reduce(state, .reorderMatchRules([RuleID("3"), RuleID("1"), RuleID("2")]))
        #expect(next.rules.map(\.id) == [RuleID("3"), RuleID("1"), RuleID("2")])
        #expect(effects == [.applyRuleSet(globalProxyEnabled: false, assignments: [:], matchRules: next.rules)])
    }

    @Test("reorderMatchRules ignores unknown ids and appends any rules the order omitted")
    func reorderPartial() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        // order mentions only "2" (and a ghost); "1" was omitted -> kept, appended after
        let (next, _) = Reducer.reduce(state, .reorderMatchRules([RuleID("ghost"), RuleID("2")]))
        #expect(next.rules.map(\.id) == [RuleID("2"), RuleID("1")])
    }

    @Test("the rule-set push carries global flag, non-direct assignments, and the current rules together")
    func pushCarriesEverything() {
        var state = AppState(isGlobalProxyEnabled: true)
        let a = ProcessID("a")
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)
        let (_, effects) = Reducer.reduce(state, .addMatchRule(rule("r1", host: "*.x")))
        #expect(effects == [.applyRuleSet(
            globalProxyEnabled: true,
            assignments: [a: .proxied],
            matchRules: [rule("r1", host: "*.x")]
        )])
    }
}
