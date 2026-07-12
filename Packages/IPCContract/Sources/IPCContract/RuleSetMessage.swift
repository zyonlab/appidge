public struct RuleAssignmentDTO: Sendable, Equatable, Codable {
    public let processID: ProcessIdentifierDTO
    public let rule: ProxyRuleDTO

    public init(processID: ProcessIdentifierDTO, rule: ProxyRuleDTO) {
        self.processID = processID
        self.rule = rule
    }
}

/// 规则下发：app → extension。
public struct RuleSetMessage: Sendable, Equatable, Codable {
    public let assignments: [RuleAssignmentDTO]
    public let globalProxyEnabled: Bool

    public init(assignments: [RuleAssignmentDTO], globalProxyEnabled: Bool) {
        self.assignments = assignments
        self.globalProxyEnabled = globalProxyEnabled
    }
}
