public enum DiagnosticKind: Sendable, Equatable, Codable, CaseIterable {
    case ruleHit
    case actuallyProxied
    case upstreamReachable
    case dnsResolution
    case udpIPv6QuicLeak
    case envConflict
}

public struct DiagnosticOutcome: Sendable, Equatable, Codable {
    public let passed: Bool
    public let detail: String

    public init(passed: Bool, detail: String) {
        self.passed = passed
        self.detail = detail
    }
}
