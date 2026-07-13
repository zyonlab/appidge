public struct AppState: Sendable, Equatable {
    public var isGlobalProxyEnabled: Bool
    public var isEngineHealthy: Bool
    public var processes: [ProcessID: MonitoredProcess]
    public var catalog: [ProcessID: DirectoryEntry]
    public var diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]]
    public var hasCompletedOnboarding: Bool
    public var proxyServers: [ProxyServerID: ProxyServer]
    public var activeProxyServerID: ProxyServerID?

    public init(
        isGlobalProxyEnabled: Bool = false,
        isEngineHealthy: Bool = true,
        processes: [ProcessID: MonitoredProcess] = [:],
        catalog: [ProcessID: DirectoryEntry] = [:],
        diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]] = [:],
        hasCompletedOnboarding: Bool = false,
        proxyServers: [ProxyServerID: ProxyServer] = [:],
        activeProxyServerID: ProxyServerID? = nil
    ) {
        self.isGlobalProxyEnabled = isGlobalProxyEnabled
        self.isEngineHealthy = isEngineHealthy
        self.processes = processes
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.proxyServers = proxyServers
        self.activeProxyServerID = activeProxyServerID
    }
}
