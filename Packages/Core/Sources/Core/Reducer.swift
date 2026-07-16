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
        case .setMatchRuleEnabled(let id, let enabled):
            return setMatchRuleEnabled(id: id, enabled: enabled, state)
        default:
            return nil
        }
    }

    /// 进程发现 / 规则 / 流量计量 / 引擎失败这一组。
    private static func reduceProcessAndFlow(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .processDiscovered(let id, let displayName, let executablePath):
            return processDiscovered(id: id, displayName: displayName, executablePath: executablePath, state)
        case .assignRule(let processID, let rule):
            return assignRule(processID: processID, rule: rule, state)
        case .flowStatsDeltaReceived(let deltas, let intervalSeconds):
            return flowStatsDeltaReceived(deltas, intervalSeconds, state)
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
        case .clearConnectionLog:
            return clearConnectionLog(state)
        case .resyncExtension:
            return resyncExtension(state)
        default:
            // 只可能是前面几组已处理的 case，reduce 不会走到这里。
            return (state, [])
        }
    }

    /// 路由相关状态变了就产出"把完整规则集推给扩展"的 effect：非默认的每进程规则
    /// + 细粒度规则表。app 侧 effectHandler 翻成 RuleSetMessage 发出。
    ///
    /// **fail-open 感知**:引擎不健康(`isEngineHealthy == false`)时推**空规则集**——扩展对
    /// 未知进程/无规则命中一律回落默认直连,这才是把"异常时恢复直连"落到真正在路由的组件上;
    /// 用户配置(state 里的规则)原样保留,恢复健康后按老路重推(见 `extensionActivationChanged`)。
    ///
    /// 非 private:规则表操作拆到 ReducerMatchRules.swift(压 file_length,同扩展侧拆文件先例)。
    static func ruleSetPush(_ state: AppState) -> Effect {
        guard state.isEngineHealthy else {
            return .applyRuleSet(assignments: [:], matchRules: [])
        }
        let assignments = state.processes.compactMapValues { $0.rule == .direct ? nil : $0.rule }
        return .applyRuleSet(
            assignments: assignments,
            matchRules: state.rules
        )
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

    /// 每进程规则**统一收编进规则表**:除了更新 `processes[id].rule`(「应用」表的显示 + 持久化),
    /// 还派生一条「该进程 × 任意主机 × 任意端口」的规则,按 `addMatchRule` 同一套去重/置顶语义
    /// upsert 到表首。这保证「时间倒排、最新覆盖」跨两种入口(应用表右键 / 连接右键)一致成立:
    /// 扩展的匹配器只看规则表的从上到下顺序,新做的每进程修改必然压过更早的连接级规则;显式改回
    /// 「直连」也因此可表达、可下发(以前 `.direct` 在下发时被剥掉,只能靠"缺席"表示)。
    /// 派生规则的 id 确定(`process:<id>`)——reduce 是纯函数,不能造随机 UUID;去重键命中时
    /// 沿用表里现有那条,id 只在首次创建时用到。
    private static func assignRule(processID: ProcessID, rule: ProxyRule, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.processes[processID]?.rule = rule
        let derived = ProxyMatchRule(
            id: RuleID("process:\(processID.value)"),
            appPattern: processID.value, hostPattern: "*", portRange: nil, action: rule
        )
        state = upsertingMatchRule(derived, state)
        return (state, [ruleSetPush(state)])
    }

    private static func flowStatsDeltaReceived(
        _ deltas: [ProcessID: FlowStatsDelta], _ intervalSeconds: Double, _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        // 速率是瞬时量:先把所有进程速率归 0(本批没数据 = 当前不活跃 = 0),再对本批有增量的
        // 进程按「增量 ÷ 时间窗」算出当前速率。累计字节照旧只增不减。
        for id in state.processes.keys {
            state.processes[id]?.rateUpPerSec = 0
            state.processes[id]?.rateDownPerSec = 0
        }
        for (id, delta) in deltas {
            state.processes[id]?.apply(delta, intervalSeconds: intervalSeconds)
        }
        return (state, [])
    }

    /// 引擎异常 → fail-open:标记不健康并**把空规则集推给扩展**(一切回落默认直连)。
    /// 不清写 state 里的每进程规则/规则表——那是用户的持久化配置,破坏性清写会在下次落盘时
    /// 把配置永久丢掉;fail-open 由 `ruleSetPush` 的健康度守卫实现,恢复后原配置重推即可。
    private static func engineFailure(reason: String, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.isEngineHealthy = false
        return (state, [
            ruleSetPush(state),
            .log("engine failure, fail-open to direct: \(reason)")
        ])
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
    /// 超过 ``AppState/connectionLogCap`` 就丢最旧。顺带把这条连接的进程注册进
    /// `state.processes`(若之前没见过)——"应用"表现在展示的是**真实观察到过连接的进程**,
    /// 不再局限于目录扫描到的 app(同 `directoryScanned`/`processDiscovered` 的幂等写法:
    /// 已存在就不碰,避免覆盖扫描/持久化已经取到的更好的 displayName/已分配的 rule)。
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
        if state.processes[entry.processID] == nil {
            state.processes[entry.processID] = MonitoredProcess(
                id: entry.processID,
                displayName: entry.processDisplayName ?? entry.processID.value,
                executablePath: entry.processID.value
            )
        }
        return (state, [])
    }

    /// 只清 `connectionLog` 这张表,不碰 `processes`(累计流量/规则是独立概念,用户清的是
    /// "这些行不想再看见",不是"忘掉这些进程")。已经是空的就是纯 no-op,不必让磁盘也白跑一趟。
    private static func clearConnectionLog(_ state: AppState) -> (AppState, [Effect]) {
        guard !state.connectionLog.isEmpty else { return (state, []) }
        var state = state
        state.connectionLog = []
        return (state, [.clearConnectionLogFile])
    }

    /// 全量重推当前配置给扩展——state 原样不动,只产出一串"把现状推下去"的 effect。
    /// 顺序固定(便于测试断言 + 确定性):规则集 → 代理配置 → 路由模式 → 抓包 → UDP 策略 → 排除名单。
    /// 每一条都用现有的推送 effect(和用户改动时走的是同一批),扩展侧幂等接收。
    /// 用途见 `Action.resyncExtension`:XPC(重)连上、或启动恢复完成后触发一次。
    private static func resyncExtension(_ state: AppState) -> (AppState, [Effect]) {
        (state, [
            ruleSetPush(state),
            proxyConfigPush(state),
            .applyRoutingMode(state.proxyRoutingMode),
            .applyPacketCapture(state.isPacketCaptureEnabled),
            .applyUDPPolicy(state.udpPolicy),
            .applyProcessOriginExclusions(state.dynamicOriginExclusion)
        ])
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
        case .extensionActivationChanged(let activation):
            var state = state
            state.extensionActivation = activation
            // 扩展(重新)跑起来 = 新的引擎会话:之前 fail-open 标记的不健康态就此翻篇,恢复健康
            // 并把真实规则集重推下去(不健康期间推的是空规则集)。只在「不健康 → active」这个
            // 转变沿推一次,平时的 activation 回报不产生多余推送。
            if case .active = activation, !state.isEngineHealthy {
                state.isEngineHealthy = true
                return (state, [ruleSetPush(state)])
            }
            return (state, [])
        case .proxyProcessIdentitiesResolved(let discovery):
            // 未变化就不推(和 applyProxyConfig 等其它下发一致的幂等守卫)。
            guard state.dynamicOriginExclusion != discovery else { return (state, []) }
            var state = state
            state.dynamicOriginExclusion = discovery
            return (state, [.applyProcessOriginExclusions(discovery)])
        default:
            return nil
        }
    }
}

private extension MonitoredProcess {
    /// 累计字节只增不减;瞬时速率 = 本批增量 ÷ 本批时间窗。时间窗非正时只累计、不动速率
    /// (调用方已把速率归 0)。
    mutating func apply(_ delta: FlowStatsDelta, intervalSeconds: Double) {
        stats.apply(delta)
        guard intervalSeconds > 0 else { return }
        rateUpPerSec = Double(delta.bytesUpDelta) / intervalSeconds
        rateDownPerSec = Double(delta.bytesDownDelta) / intervalSeconds
    }
}
