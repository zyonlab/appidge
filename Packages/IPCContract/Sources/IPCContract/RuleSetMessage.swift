public struct RuleAssignmentDTO: Sendable, Equatable, Codable {
    public let processID: ProcessIdentifierDTO
    public let rule: ProxyRuleDTO

    public init(processID: ProcessIdentifierDTO, rule: ProxyRuleDTO) {
        self.processID = processID
        self.rule = rule
    }
}

/// 一条细粒度规则的 wire-format（进程 × 主机 × 端口 → 动作）。是 `Core.ProxyMatchRule` 的
/// 传输孪生;真正按它路由的匹配器在 `EngineKit.RuleMatcher`（EngineKit 只认 IPCContract）。
public struct MatchRuleDTO: Sendable, Equatable, Codable {
    public let id: String
    public let appPattern: String
    public let hostPattern: String
    public let portRange: ClosedRange<UInt16>?
    public let rule: ProxyRuleDTO

    public init(
        id: String, appPattern: String, hostPattern: String,
        portRange: ClosedRange<UInt16>?, rule: ProxyRuleDTO
    ) {
        self.id = id
        self.appPattern = appPattern
        self.hostPattern = hostPattern
        self.portRange = portRange
        self.rule = rule
    }
}

/// 规则下发：app → extension。`matchRules` 是从上到下、首个命中生效的细粒度规则表;
/// `assignments` 是每进程的粗粒度规则(只含非默认的);`globalProxyEnabled` 是全局开关。
public struct RuleSetMessage: Sendable, Equatable, Codable {
    public let assignments: [RuleAssignmentDTO]
    public let matchRules: [MatchRuleDTO]
    public let globalProxyEnabled: Bool

    public init(assignments: [RuleAssignmentDTO], matchRules: [MatchRuleDTO] = [], globalProxyEnabled: Bool) {
        self.assignments = assignments
        self.matchRules = matchRules
        self.globalProxyEnabled = globalProxyEnabled
    }
}
