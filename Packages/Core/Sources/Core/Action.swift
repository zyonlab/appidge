public enum Action: Sendable, Equatable {
    case setGlobalProxyEnabled(Bool)
    case processDiscovered(id: ProcessID, displayName: String, executablePath: String)
    case assignRule(processID: ProcessID, rule: ProxyRule)
    case flowStatsDeltaReceived([ProcessID: FlowStatsDelta])
    case engineFailure(reason: String)
}
