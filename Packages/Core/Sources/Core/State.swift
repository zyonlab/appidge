public struct AppState: Sendable, Equatable {
    public var isGlobalProxyEnabled: Bool
    public var isEngineHealthy: Bool
    public var processes: [ProcessID: MonitoredProcess]
    public var catalog: [ProcessID: DirectoryEntry]
    public var diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]]
    public var hasCompletedOnboarding: Bool
    public var proxyServers: [ProxyServerID: ProxyServer]
    public var activeProxyServerID: ProxyServerID?
    /// 代理流量如何使用上游(单台 / 链 / 故障转移 / 负载均衡)。默认 `.single`,用 activeProxyServerID。
    public var proxyRoutingMode: ProxyRoutingMode
    /// 细粒度规则表(进程 × 主机 × 端口),从上到下求值、首个命中生效。见 ``RuleMatcher``。
    public var rules: [ProxyMatchRule]
    /// 每连接日志(按连接 id 去重更新),环形缓冲上限 ``connectionLogCap``。
    public var connectionLog: [ConnectionLogEntry]

    /// 连接日志保留的最大条数;超出丢最旧。
    public static let connectionLogCap = 500

    public init(
        isGlobalProxyEnabled: Bool = false,
        isEngineHealthy: Bool = true,
        processes: [ProcessID: MonitoredProcess] = [:],
        catalog: [ProcessID: DirectoryEntry] = [:],
        diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]] = [:],
        hasCompletedOnboarding: Bool = false,
        proxyServers: [ProxyServerID: ProxyServer] = [:],
        activeProxyServerID: ProxyServerID? = nil,
        proxyRoutingMode: ProxyRoutingMode = .single,
        rules: [ProxyMatchRule] = [],
        connectionLog: [ConnectionLogEntry] = []
    ) {
        self.isGlobalProxyEnabled = isGlobalProxyEnabled
        self.isEngineHealthy = isEngineHealthy
        self.processes = processes
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.proxyServers = proxyServers
        self.activeProxyServerID = activeProxyServerID
        self.proxyRoutingMode = proxyRoutingMode
        self.rules = rules
        self.connectionLog = connectionLog
    }
}
