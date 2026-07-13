public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        switch action {
        case .setGlobalProxyEnabled(let enabled):
            return setGlobalProxyEnabled(enabled, state)
        case .processDiscovered(let id, let displayName, let executablePath):
            return processDiscovered(id: id, displayName: displayName, executablePath: executablePath, state)
        case .assignRule(let processID, let rule):
            return assignRule(processID: processID, rule: rule, state)
        case .flowStatsDeltaReceived(let deltas):
            return flowStatsDeltaReceived(deltas, state)
        case .engineFailure(let reason):
            return engineFailure(reason: reason, state)
        case .directoryScanned(let entries):
            return directoryScanned(entries, state)
        case .requestDiagnostic(let processID, let kinds):
            return requestDiagnostic(processID: processID, kinds: kinds, state)
        case .diagnosticResultReceived(let processID, let kind, let passed, let detail):
            return diagnosticResultReceived(processID: processID, kind: kind, passed: passed, detail: detail, state)
        case .onboardingCompleted:
            return onboardingCompleted(state)
        case .appLaunched:
            return appLaunched(state)
        }
    }

    private static func setGlobalProxyEnabled(_ enabled: Bool, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.isGlobalProxyEnabled = enabled
        return (state, [])
    }

    private static func processDiscovered(
        id: ProcessID, displayName: String, executablePath: String, _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        if state.processes[id] == nil {
            state.processes[id] = MonitoredProcess(id: id, displayName: displayName, executablePath: executablePath)
        }
        return (state, [])
    }

    private static func assignRule(processID: ProcessID, rule: ProxyRule, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.processes[processID]?.rule = rule
        return (state, [])
    }

    private static func flowStatsDeltaReceived(
        _ deltas: [ProcessID: FlowStatsDelta], _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        for (id, delta) in deltas {
            state.processes[id]?.apply(delta)
        }
        return (state, [])
    }

    private static func engineFailure(reason: String, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.isEngineHealthy = false
        state.isGlobalProxyEnabled = false
        for id in state.processes.keys {
            state.processes[id]?.rule = .direct
        }
        return (state, [.log("engine failure, fail-open to direct: \(reason)")])
    }

    private static func directoryScanned(_ entries: [DirectoryEntry], _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        for entry in entries {
            state.catalog[entry.id] = entry
            if state.processes[entry.id] == nil {
                state.processes[entry.id] = MonitoredProcess(
                    id: entry.id, displayName: entry.displayName, executablePath: entry.executablePath
                )
            }
        }
        return (state, [])
    }

    private static func requestDiagnostic(
        processID: ProcessID, kinds: [DiagnosticKind], _ state: AppState
    ) -> (AppState, [Effect]) {
        (state, [.runDiagnostic(processID: processID, kinds: kinds)])
    }

    private static func diagnosticResultReceived(
        processID: ProcessID, kind: DiagnosticKind, passed: Bool, detail: String, _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        state.diagnostics[processID, default: [:]][kind] = DiagnosticOutcome(passed: passed, detail: detail)
        return (state, [])
    }

    private static func onboardingCompleted(_ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.hasCompletedOnboarding = true
        return (state, [])
    }

    private static func appLaunched(_ state: AppState) -> (AppState, [Effect]) {
        (state, [.scanDirectory])
    }
}

private extension MonitoredProcess {
    mutating func apply(_ delta: FlowStatsDelta) {
        stats.apply(delta)
    }
}
