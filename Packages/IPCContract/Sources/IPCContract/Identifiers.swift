public struct ProcessIdentifierDTO: Sendable, Hashable, Codable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum ProxyRuleDTO: Sendable, Equatable, Codable {
    case direct
    case proxied
    /// 拦截:命中的流量直接拒绝(对齐 Core.ProxyRule.block)。
    case block
}
