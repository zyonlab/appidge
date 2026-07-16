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
    /// 观测:不接管数据通路,仅记录连接事件后放行(对齐 Core.ProxyRule.observe)。
    case observe
}
