import Testing
@testable import Core

@Suite("Reducer — updateMatchRule 就地编辑,保留位置与启用态")
struct UpdateMatchRuleReducerTests {

    private func rule(_ id: String, _ host: String, _ action: ProxyRule = .proxied, enabled: Bool = true) -> ProxyMatchRule {
        ProxyMatchRule(id: RuleID(id), appPattern: "*", hostPattern: host, portRange: nil, action: action, isEnabled: enabled)
    }

    @Test("就地替换四字段,位置不动、isEnabled 保留")
    func editsInPlace() {
        var state = AppState()
        state.rules = [rule("1", "a.com"), rule("2", "b.com", enabled: false), rule("3", "c.com")]

        let (next, effects) = Reducer.reduce(state, .updateMatchRule(
            id: RuleID("2"), appPattern: "com.x", hostPattern: "b2.com", portRange: 443...443, action: .direct
        ))

        // 仍在原位(index 1),id 不变。
        #expect(next.rules.map(\.id) == [RuleID("1"), RuleID("2"), RuleID("3")])
        let edited = next.rules[1]
        #expect(edited.appPattern == "com.x")
        #expect(edited.hostPattern == "b2.com")
        #expect(edited.portRange == 443...443)
        #expect(edited.action == .direct)
        #expect(edited.isEnabled == false) // 保留原启用态
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("未知 id 是 no-op,不推送")
    func unknownIdNoOp() {
        var state = AppState()
        state.rules = [rule("1", "a.com")]
        let (next, effects) = Reducer.reduce(state, .updateMatchRule(
            id: RuleID("ghost"), appPattern: "*", hostPattern: "*", portRange: nil, action: .block
        ))
        #expect(next.rules == state.rules)
        #expect(effects.isEmpty)
    }

    @Test("编辑不做三元组去重/置顶(区别于 addMatchRule)——即便改成与它条同键也不合并")
    func editDoesNotDedup() {
        var state = AppState()
        state.rules = [rule("1", "a.com"), rule("2", "b.com")]
        // 把 rule 2 改成和 rule 1 完全同键(app*/host a.com/port nil)。
        let (next, _) = Reducer.reduce(state, .updateMatchRule(
            id: RuleID("2"), appPattern: "*", hostPattern: "a.com", portRange: nil, action: .direct
        ))
        // 仍是两条,各在原位(编辑就是编辑那一条,不触发去重合并)。
        #expect(next.rules.map(\.id) == [RuleID("1"), RuleID("2")])
    }
}
