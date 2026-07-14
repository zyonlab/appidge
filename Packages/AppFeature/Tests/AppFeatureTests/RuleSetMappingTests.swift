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
        arguments: [(Core.ProxyRule.direct, ProxyRuleDTO.direct), (Core.ProxyRule.proxied, ProxyRuleDTO.proxied)]
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
}
