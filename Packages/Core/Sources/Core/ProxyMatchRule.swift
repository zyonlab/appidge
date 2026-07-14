public struct RuleID: Sendable, Hashable, Codable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// 一条细粒度转发规则的**领域模型**:按 进程 × 目标主机 × 目标端口 匹配,命中就用 `action`。
/// app/host 用 `*` 通配,port 用闭区间(nil = 任意端口)。规则表从上到下、首个命中生效。
///
/// 匹配**逻辑**不在 Core——真正按规则路由的是扩展,它经 EngineKit 工作、只认 IPCContract 的
/// `MatchRuleDTO`(EngineKit 不依赖 Core,见架构不变量 B2)。所以这里只放数据,匹配器住在
/// `EngineKit.RuleMatcher`(对 DTO 求值,并在那里重点测试)。Core 这份是 AppState/UI 用的。
public struct ProxyMatchRule: Sendable, Equatable, Codable, Identifiable {
    public let id: RuleID
    /// 匹配进程签名标识(sourceAppSigningIdentifier)的 glob;`*` = 任意进程。
    public var appPattern: String
    /// 匹配目标主机的 glob;`*` = 任意主机。`*.example.com` 只匹配子域,`*example.com` 连 apex 也匹配。
    public var hostPattern: String
    /// 匹配目标端口的闭区间;nil = 任意端口。单端口用 `443...443`。
    public var portRange: ClosedRange<UInt16>?
    public var action: ProxyRule

    public init(
        id: RuleID, appPattern: String, hostPattern: String,
        portRange: ClosedRange<UInt16>?, action: ProxyRule
    ) {
        self.id = id
        self.appPattern = appPattern
        self.hostPattern = hostPattern
        self.portRange = portRange
        self.action = action
    }
}
