public enum DiagnosticKindDTO: Sendable, Equatable, Codable {
    case ruleHit
    case actuallyProxied
    case upstreamReachable
    case dnsResolution
    case udpIPv6QuicLeak
    case envConflict
}

/// 诊断请求：app → extension。
public struct DiagnosticRequestDTO: Sendable, Equatable, Codable {
    public let processID: ProcessIdentifierDTO
    public let kinds: [DiagnosticKindDTO]

    public init(processID: ProcessIdentifierDTO, kinds: [DiagnosticKindDTO]) {
        self.processID = processID
        self.kinds = kinds
    }
}

/// 诊断结果：extension → app。
public struct DiagnosticResultDTO: Sendable, Equatable, Codable {
    public let processID: ProcessIdentifierDTO
    public let kind: DiagnosticKindDTO
    public let passed: Bool
    public let detail: String

    public init(processID: ProcessIdentifierDTO, kind: DiagnosticKindDTO, passed: Bool, detail: String) {
        self.processID = processID
        self.kind = kind
        self.passed = passed
        self.detail = detail
    }
}
