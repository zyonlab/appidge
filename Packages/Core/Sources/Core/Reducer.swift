public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        // reduce 是纯粹的分派表，按领域拆成几组 switch，让每个 switch 的分支数保持在
        // cyclomatic_complexity 阈值内——不是真有分支逻辑，只是 Action 的 case 多。
        // 前两组不匹配就返回 nil 交给下一组，最后一组兜底非可选。
        reduceProxyConfig(state, action)
            ?? reduceProcessAndFlow(state, action)
            ?? reduceLifecycle(state, action)
    }

    /// 代理服务器配置这一组 action。
    private static func reduceProxyConfig(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .addProxyServer(let server):
            return addProxyServer(server, state)
        case .updateProxyServer(let server):
            return updateProxyServer(server, state)
        case .removeProxyServer(let id):
            return removeProxyServer(id, state)
        case .setActiveProxyServer(let id):
            return setActiveProxyServer(id, state)
        default:
            return nil
        }
    }

    /// 进程发现 / 规则 / 流量计量 / 引擎失败这一组。
    private static func reduceProcessAndFlow(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
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
        default:
            return nil
        }
    }

    /// 目录 / 诊断 / 引导 / 启动这一组——放在链尾，兜底非可选。
    private static func reduceLifecycle(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        switch action {
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
        default:
            // 只可能是前两组已处理的 case，reduce 不会走到这里。
            return (state, [])
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

    /// 代理配置发生真实变更后，产出"把当前完整配置推给扩展"的 effect。servers 按 id 排序，
    /// 让推送内容确定、幂等，也便于测试断言。
    private static func proxyConfigPush(_ state: AppState) -> Effect {
        .applyProxyConfig(
            servers: state.proxyServers.values.sorted { $0.id.value < $1.id.value },
            activeID: state.activeProxyServerID
        )
    }

    private static func addProxyServer(_ server: ProxyServer, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.proxyServers[server.id] = server
        // 第一台被加入的代理自动选为 active，省去用户还得再点一下选中。
        if state.activeProxyServerID == nil {
            state.activeProxyServerID = server.id
        }
        return (state, [proxyConfigPush(state)])
    }

    private static func updateProxyServer(_ server: ProxyServer, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        // 只更新已存在的，不借 update 之名做插入（插入走 addProxyServer）。无变更不推送。
        guard state.proxyServers[server.id] != nil else { return (state, []) }
        state.proxyServers[server.id] = server
        return (state, [proxyConfigPush(state)])
    }

    private static func removeProxyServer(_ id: ProxyServerID, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        // 不存在就是 no-op，不推送。
        guard state.proxyServers[id] != nil else { return (state, []) }
        state.proxyServers[id] = nil
        if state.activeProxyServerID == id {
            state.activeProxyServerID = nil
        }
        return (state, [proxyConfigPush(state)])
    }

    private static func setActiveProxyServer(_ id: ProxyServerID?, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        // nil 明确表示"清空 active"；非 nil 但指向不存在的 id 则拒绝（保持原 active），不推送。
        if let id, state.proxyServers[id] == nil {
            return (state, [])
        }
        state.activeProxyServerID = id
        return (state, [proxyConfigPush(state)])
    }
}

private extension MonitoredProcess {
    mutating func apply(_ delta: FlowStatsDelta) {
        stats.apply(delta)
    }
}
