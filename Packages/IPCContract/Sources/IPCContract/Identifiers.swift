public struct ProcessIdentifierDTO: Sendable, Hashable, Codable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum ProxyRuleDTO: Sendable, Equatable, Codable {
    case direct
    case proxied
}
