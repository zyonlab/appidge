public enum Reducer {
    public static func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect]) {
        // reduce 是纯粹的分派表，按领域拆成几组 switch，让每个 switch 的分支数保持在
        // cyclomatic_complexity 阈值内——不是真有分支逻辑，只是 Action 的 case 多。
        // 前两组不匹配就返回 nil 交给下一组，最后一组兜底非可选。
        reduceProxyConfig(state, action)
            ?? reduceMatchRules(state, action)
            ?? reduceProcessAndFlow(state, action)
            ?? reduceSettings(state, action)
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
        case .setProxyRoutingMode(let mode):
            return setProxyRoutingMode(mode, state)
        default:
            return nil
        }
    }

    /// 细粒度规则表这一组 action。
    private static func reduceMatchRules(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .addMatchRule(let rule):
            return addMatchRule(rule, state)
        case .removeMatchRule(let id):
            return removeMatchRule(id, state)
        case .reorderMatchRules(let order):
            return reorderMatchRules(order, state)
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
        case .connectionEventReceived(let entry):
            return connectionEventReceived(entry, state)
        default:
            // 只可能是前面几组已处理的 case，reduce 不会走到这里。
            return (state, [])
        }
    }

    /// 路由相关状态变了就产出"把完整规则集推给扩展"的 effect：全局开关 + 非默认的每进程规则
    /// + 细粒度规则表。app 侧 effectHandler 翻成 RuleSetMessage 发出。
    private static func ruleSetPush(_ state: AppState) -> Effect {
        let assignments = state.processes.compactMapValues { $0.rule == .direct ? nil : $0.rule }
        return .applyRuleSet(
            globalProxyEnabled: state.isGlobalProxyEnabled,
            assignments: assignments,
            matchRules: state.rules
        )
    }

    private static func setGlobalProxyEnabled(_ enabled: Bool, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.isGlobalProxyEnabled = enabled
        return (state, [ruleSetPush(state)])
    }

    private static func addMatchRule(_ rule: ProxyMatchRule, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.rules.append(rule)
        return (state, [ruleSetPush(state)])
    }

    private static func removeMatchRule(_ id: RuleID, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        guard state.rules.contains(where: { $0.id == id }) else { return (state, []) }
        state.rules.removeAll { $0.id == id }
        return (state, [ruleSetPush(state)])
    }

    /// 按给定 id 顺序重排；未提及的规则保持原相对顺序、追加在后；未知 id 忽略。
    private static func reorderMatchRules(_ order: [RuleID], _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        let byID = Dictionary(state.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reordered: [ProxyMatchRule] = []
        var used = Set<RuleID>()
        for id in order where !used.contains(id) {
            if let rule = byID[id] {
                reordered.append(rule)
                used.insert(id)
            }
        }
        for rule in state.rules where !used.contains(rule.id) {
            reordered.append(rule)
        }
        state.rules = reordered
        return (state, [ruleSetPush(state)])
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
        return (state, [ruleSetPush(state)])
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

    /// 按连接 id 去重更新:已有则原地更新那一行(不重排、不占新名额),否则追加;
    /// 超过 ``AppState/connectionLogCap`` 就丢最旧。
    private static func connectionEventReceived(_ entry: ConnectionLogEntry, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        if let index = state.connectionLog.firstIndex(where: { $0.id == entry.id }) {
            state.connectionLog[index] = entry
        } else {
            state.connectionLog.append(entry)
            if state.connectionLog.count > AppState.connectionLogCap {
                state.connectionLog.removeFirst(state.connectionLog.count - AppState.connectionLogCap)
            }
        }
        return (state, [])
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

    private static func setProxyRoutingMode(_ mode: ProxyRoutingMode, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.proxyRoutingMode = mode
        return (state, [.applyRoutingMode(mode)])
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

/// 「设置类」action 的 reduce 放 Reducer 的同文件 extension 里,不占主 enum 的长度预算
/// (SwiftLint type_body_length 分别统计 enum 与 extension)。同文件仍可访问 private 成员。
private extension Reducer {
    static func reduceSettings(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .loopWarningRaised(let signature):
            var state = state
            state.loopWarning = signature
            return (state, [])
        case .dismissLoopWarning:
            var state = state
            state.loopWarning = nil
            return (state, [])
        case .resetState:
            return (AppState(), [])
        case .setPacketCaptureEnabled(let enabled):
            var state = state
            state.isPacketCaptureEnabled = enabled
            return (state, [.applyPacketCapture(enabled)])
        case .setUDPPolicy(let policy):
            var state = state
            state.udpPolicy = policy
            return (state, [.applyUDPPolicy(policy)])
        default:
            return nil
        }
    }
}

private extension MonitoredProcess {
    mutating func apply(_ delta: FlowStatsDelta) {
        stats.apply(delta)
    }
}
