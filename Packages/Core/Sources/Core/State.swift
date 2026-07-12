public struct AppState: Sendable, Equatable {
    public var isGlobalProxyEnabled: Bool
    public var isEngineHealthy: Bool
    public var processes: [ProcessID: MonitoredProcess]

    public init(
        isGlobalProxyEnabled: Bool = false,
        isEngineHealthy: Bool = true,
        processes: [ProcessID: MonitoredProcess] = [:]
    ) {
        self.isGlobalProxyEnabled = isGlobalProxyEnabled
        self.isEngineHealthy = isEngineHealthy
        self.processes = processes
    }
}
