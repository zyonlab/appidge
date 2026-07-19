import Foundation

/// 细粒度规则表(增/删/排序/启停)的实现,从 Reducer.swift 拆出(压 file_length,同扩展侧
/// 拆文件的既有先例)。跨文件访问,故这里与 `Reducer.ruleSetPush` 均为 internal(非 private)。
extension Reducer {
    /// 新规则**插到表首**(index 0 = 最高优先级),整表因此天然按"最近添加在最上"排列。
    /// 规则匹配是"从上到下、首个命中生效",所以用户刚为某条连接建的规则会**立刻压过**已有的宽泛
    /// 规则(比如 `*→*→代理`)——这正是"手动修改进程连接策略必须生效"的要求。
    ///
    /// 去重键:进程 glob × 主机 glob × 端口区间三者全同就算"同一条规则"(动作不算在键里)。
    /// 命中去重键时:动作也一样 = 纯重复,直接把它**移到表首**(体现"最近又点了一次");动作不同 =
    /// 用户想改判定,更新动作后同样移到表首。都不新增第二条同键规则。
    static func addMatchRule(_ rule: ProxyMatchRule, _ state: AppState) -> (AppState, [Effect]) {
        let state = upsertingMatchRule(rule, state)
        return (state, [ruleSetPush(state)])
    }

    /// upsert 的共同实现:`addMatchRule` 与 `assignRule`(派生规则)共用同一套去重/置顶语义。
    static func upsertingMatchRule(_ rule: ProxyMatchRule, _ state: AppState) -> AppState {
        var state = state
        if let index = state.rules.firstIndex(where: {
            $0.appPattern == rule.appPattern && $0.hostPattern == rule.hostPattern && $0.portRange == rule.portRange
        }) {
            var existing = state.rules.remove(at: index)
            existing.action = rule.action  // 动作以最新一次为准(相同则无变化)
            state.rules.insert(existing, at: 0)
        } else {
            state.rules.insert(rule, at: 0)
        }
        return state
    }

    /// 就地编辑一条规则(按 `updated.id`):替换进程/主机/端口/动作,**保留原位置与 `isEnabled`**
    /// ——双击改规则用。id 不存在时 no-op、不推送(同 `removeMatchRule` 守卫)。不做三元组去重/置顶
    /// (那是新增语义);用户明确要改某一条,就改那一条,位置不动。
    static func updateMatchRule(_ updated: ProxyMatchRule, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        guard let index = state.rules.firstIndex(where: { $0.id == updated.id }) else { return (state, []) }
        state.rules[index].appPattern = updated.appPattern
        state.rules[index].hostPattern = updated.hostPattern
        state.rules[index].portRange = updated.portRange
        state.rules[index].action = updated.action
        return (state, [ruleSetPush(state)])
    }

    /// 应用页派生的「进程级」规则用确定 id `process:<processID>`(见 `assignRule` / `derivedRuleID`)——
    /// 删这类规则时必须同时把该进程的 `rule` 复位为 `.direct`,否则 `process.rule` 与规则表脱节:
    /// 持久化把两者一起存,重启时 `restorationActions` 又按 `process.rule` 重放 `assignRule`、
    /// 把这条已删规则重新派生出来(真机实锤「删了规则重启又出现」)。
    static let derivedRuleIDPrefix = "process:"

    /// 某进程的派生规则的确定 id。`assignRule` 建规则、`removeMatchRule` 反查进程,共用这一处。
    static func derivedRuleID(for processID: ProcessID) -> RuleID {
        RuleID("\(derivedRuleIDPrefix)\(processID.value)")
    }

    /// 若 id 是派生规则 id(`process:<processID>`)则解出其进程;否则 nil(手动建的 UUID 规则)。
    static func derivedProcessID(from id: RuleID) -> ProcessID? {
        guard id.value.hasPrefix(derivedRuleIDPrefix) else { return nil }
        return ProcessID(String(id.value.dropFirst(derivedRuleIDPrefix.count)))
    }

    static func removeMatchRule(_ id: RuleID, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        guard state.rules.contains(where: { $0.id == id }) else { return (state, []) }
        state.rules.removeAll { $0.id == id }
        // 派生规则:同步把来源进程的走法复位为 .direct,断掉「删了又被重放复活」的链路。
        if let processID = derivedProcessID(from: id) {
            state.processes[processID]?.rule = .direct
        }
        return (state, [ruleSetPush(state)])
    }

    /// 按给定 id 顺序重排；未提及的规则保持原相对顺序、追加在后；未知 id 忽略。
    static func reorderMatchRules(_ order: [RuleID], _ state: AppState) -> (AppState, [Effect]) {
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

    /// 启用/停用指定规则(规则仍留在表里)。命中就翻转 `isEnabled` 并按老路推整表;
    /// 未知 id 是 no-op、不推送(和 `removeMatchRule` 的守卫一致)。
    static func setMatchRuleEnabled(id: RuleID, enabled: Bool, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        guard let index = state.rules.firstIndex(where: { $0.id == id }) else { return (state, []) }
        state.rules[index].isEnabled = enabled
        return (state, [ruleSetPush(state)])
    }
}
