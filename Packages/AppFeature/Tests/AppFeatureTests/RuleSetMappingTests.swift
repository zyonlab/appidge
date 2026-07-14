import Testing
import Core
import IPCContract
@testable import AppFeature

@Suite("RuleSetMapping — Core rule state → IPCContract RuleSetMessage")
struct RuleSetMappingTests {

    @Test("maps global flag, sorted assignments, and match rules into applyRuleSet")
    func mapsEverything() {
        let message = RuleSetMapping.ruleSetMessage(
            globalProxyEnabled: true,
            assignments: [Core.ProcessID("b"): .proxied, Core.ProcessID("a"): .direct],
            matchRules: [
                Core.ProxyMatchRule(id: Core.RuleID("r1"), appPattern: "*", hostPattern: "*.corp", portRange: 22...22, action: .direct)
            ]
        )
        #expect(message == .applyRuleSet(RuleSetMessage(
            assignments: [
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("a"), rule: .direct),
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("b"), rule: .proxied)
            ],
            matchRules: [
                MatchRuleDTO(id: "r1", appPattern: "*", hostPattern: "*.corp", portRange: 22...22, rule: .direct)
            ],
            globalProxyEnabled: true
        )))
    }

    @Test("empty state maps to an empty rule set")
    func empty() {
        let message = RuleSetMapping.ruleSetMessage(globalProxyEnabled: false, assignments: [:], matchRules: [])
        #expect(message == .applyRuleSet(RuleSetMessage(assignments: [], matchRules: [], globalProxyEnabled: false)))
    }

    @Test(
        "ProxyRule maps 1:1 to ProxyRuleDTO",
        arguments: [
            (Core.ProxyRule.direct, ProxyRuleDTO.direct),
            (Core.ProxyRule.proxied, ProxyRuleDTO.proxied),
            (Core.ProxyRule.block, ProxyRuleDTO.block)
        ]
    )
    func ruleMapping(core: Core.ProxyRule, dto: ProxyRuleDTO) {
        let message = RuleSetMapping.ruleSetMessage(
            globalProxyEnabled: false, assignments: [Core.ProcessID("p"): core], matchRules: []
        )
        guard case .applyRuleSet(let ruleSet) = message else { Issue.record("expected applyRuleSet"); return }
        #expect(ruleSet.assignments.first?.rule == dto)
    }

    @Test("match-rule order is preserved (top-to-bottom precedence matters)")
    func matchRuleOrderPreserved() {
        let rules = [
            Core.ProxyMatchRule(id: Core.RuleID("1"), appPattern: "*", hostPattern: "a", portRange: nil, action: .direct),
            Core.ProxyMatchRule(id: Core.RuleID("2"), appPattern: "*", hostPattern: "b", portRange: nil, action: .proxied)
        ]
        let message = RuleSetMapping.ruleSetMessage(globalProxyEnabled: false, assignments: [:], matchRules: rules)
        guard case .applyRuleSet(let ruleSet) = message else { Issue.record("expected applyRuleSet"); return }
        #expect(ruleSet.matchRules.map(\.id) == ["1", "2"])
    }

    @Test("a disabled rule that would otherwise match is filtered out before downstream, so matching falls through")
    func disabledRuleIsNotSentDownstream() {
        // A disabled .block rule that would match host "a" sits above an enabled catch-all .proxied rule.
        // Filtering it out means the extension's matcher never sees it and falls through to .proxied for host "a".
        let disabled = Core.ProxyMatchRule(
            id: Core.RuleID("blockA"), appPattern: "*", hostPattern: "a", portRange: nil, action: .block, isEnabled: false
        )
        let catchAll = Core.ProxyMatchRule(
            id: Core.RuleID("proxyAll"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )
        let message = RuleSetMapping.ruleSetMessage(
            globalProxyEnabled: false, assignments: [:], matchRules: [disabled, catchAll]
        )
        guard case .applyRuleSet(let ruleSet) = message else { Issue.record("expected applyRuleSet"); return }
        #expect(ruleSet.matchRules.map(\.id) == ["proxyAll"])
        #expect(ruleSet.matchRules.first?.rule == .proxied)
    }

    @Test("only disabled rules are dropped; enabled rules pass through in their original order")
    func onlyDisabledRulesAreDropped() {
        let r1 = Core.ProxyMatchRule(id: Core.RuleID("1"), appPattern: "*", hostPattern: "x", portRange: nil, action: .direct)
        let r2 = Core.ProxyMatchRule(
            id: Core.RuleID("2"), appPattern: "*", hostPattern: "y", portRange: nil, action: .proxied, isEnabled: false
        )
        let r3 = Core.ProxyMatchRule(id: Core.RuleID("3"), appPattern: "*", hostPattern: "z", portRange: nil, action: .block)
        let message = RuleSetMapping.ruleSetMessage(globalProxyEnabled: false, assignments: [:], matchRules: [r1, r2, r3])
        guard case .applyRuleSet(let ruleSet) = message else { Issue.record("expected applyRuleSet"); return }
        #expect(ruleSet.matchRules.map(\.id) == ["1", "3"])
    }
}
