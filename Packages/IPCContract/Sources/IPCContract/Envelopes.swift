public enum AppToExtensionMessage: Sendable, Equatable, Codable {
    case applyRuleSet(RuleSetMessage)
    case requestDiagnostic(DiagnosticRequestDTO)
    case applyProxyConfig(ProxyConfigMessage)
}

public enum ExtensionToAppMessage: Sendable, Equatable, Codable {
    case flowStatsBatch(FlowStatsBatchMessage)
    case diagnosticResult(DiagnosticResultDTO)
    case engineFailure(reason: String)
}
