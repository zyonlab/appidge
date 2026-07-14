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
    /// 主动环检测的当前告警(命中的目标标识);nil = 无告警。UI 据此弹提示,用户可 dismiss。
    public var loopWarning: String?
    /// 是否逐连接抓包落 `.dmp`(默认关——抓包占磁盘且涉隐私,显式开)。开关下发给扩展。
    public var isPacketCaptureEnabled: Bool
    /// proxied 进程的 UDP/QUIC 怎么处理(默认 `.block` 止漏)。下发给扩展。
    public var udpPolicy: UDPPolicy

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
        connectionLog: [ConnectionLogEntry] = [],
        loopWarning: String? = nil,
        isPacketCaptureEnabled: Bool = false,
        udpPolicy: UDPPolicy = .block
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
        self.loopWarning = loopWarning
        self.isPacketCaptureEnabled = isPacketCaptureEnabled
        self.udpPolicy = udpPolicy
    }
}
