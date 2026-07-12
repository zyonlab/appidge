public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        var state = state

        switch action {
        case .setGlobalProxyEnabled(let enabled):
            state.isGlobalProxyEnabled = enabled
            return (state, [])

        case .processDiscovered(let id, let displayName, let executablePath):
            if state.processes[id] == nil {
                state.processes[id] = MonitoredProcess(
                    id: id, displayName: displayName, executablePath: executablePath
                )
            }
            return (state, [])

        case .assignRule(let processID, let rule):
            state.processes[processID]?.rule = rule
            return (state, [])

        case .flowStatsDeltaReceived(let deltas):
            for (id, delta) in deltas {
                state.processes[id]?.apply(delta)
            }
            return (state, [])

        case .engineFailure(let reason):
            state.isEngineHealthy = false
            state.isGlobalProxyEnabled = false
            for id in state.processes.keys {
                state.processes[id]?.rule = .direct
            }
            return (state, [.log("engine failure, fail-open to direct: \(reason)")])
        }
    }
}

private extension MonitoredProcess {
    mutating func apply(_ delta: FlowStatsDelta) {
        stats.apply(delta)
    }
}
