import Testing
@testable import Core

@Suite("Reducer — match-rule list (add / remove / reorder) + rule-set push")
struct MatchRuleReducerTests {

    /// `host` 留空时按 `id` 派生一个独一无二的主机模式(`"*.<id>"`)——大多数用例只关心
    /// 增/删/排序的列表操作,不关心主机字面量;派生保证同一测试里不同 id 的规则不会撞上新加的
    /// 去重逻辑(同 app/host/port 视为同一条规则)。真正要测"同 host 命中去重"的用例显式传 `host`。
    private func rule(_ id: String, host: String = "", _ action: ProxyRule = .proxied) -> ProxyMatchRule {
        ProxyMatchRule(
            id: RuleID(id), appPattern: "*", hostPattern: host.isEmpty ? "*.\(id)" : host,
            portRange: nil, action: action
        )
    }

    @Test("addMatchRule inserts the rule and pushes the rule set")
    func addMatchRule() {
        let r = rule("1", host: "*.corp")
        let (next, effects) = Reducer.reduce(AppState(), .addMatchRule(r))
        #expect(next.rules == [r])
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: [r])])
    }

    @Test("addMatchRule puts the newest rule on top (highest priority, newest-first)")
    func addPutsNewestOnTop() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        // 最新添加的排最上 → 首个命中生效时它最优先(修"手动规则被通配规则遮蔽"的核心)。
        #expect(state.rules.map(\.id) == [RuleID("2"), RuleID("1")])
    }

    @Test("removeMatchRule drops by id, keeps the rest in order")
    func removeMatchRule() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("3")))
        // 新规则置顶 → 加完是 [3, 2, 1];删掉 2 后剩 [3, 1]。
        let (next, effects) = Reducer.reduce(state, .removeMatchRule(RuleID("2")))
        #expect(next.rules.map(\.id) == [RuleID("3"), RuleID("1")])
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("removeMatchRule for an app-derived rule resets the process route to .direct (no resurrection on restore)")
    func removeDerivedRuleResetsProcessRoute() {
        let pid = ProcessID("com.example.yunti")
        var (state, _) = Reducer.reduce(
            AppState(), .processDiscovered(id: pid, displayName: "云梯", executablePath: "/x")
        )
        // 应用页设「走代理」= assignRule:设 process.rule + 派生 id="process:<pid>" 的规则。
        (state, _) = Reducer.reduce(state, .assignRule(processID: pid, rule: .proxied))
        #expect(state.processes[pid]?.rule == .proxied)
        let derivedID = RuleID("process:\(pid.value)")
        #expect(state.rules.contains { $0.id == derivedID })

        // 在「规则」页删掉这条派生规则:规则消失,且**进程走法复位为 .direct**——否则 process.rule
        // 仍留着旧走法,持久化后重启时 restorationActions 会用它重放 assignRule、把已删规则重新派生
        // 出来(真机实锤的「删了规则重启又出现」)。
        let (next, effects) = Reducer.reduce(state, .removeMatchRule(derivedID))
        #expect(next.rules.contains { $0.id == derivedID } == false)
        #expect(next.processes[pid]?.rule == .direct)
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("removeMatchRule for an unknown id is a no-op with no push")
    func removeUnknown() {
        let (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        let (next, effects) = Reducer.reduce(state, .removeMatchRule(RuleID("ghost")))
        #expect(next.rules.map(\.id) == [RuleID("1")])
        #expect(effects.isEmpty)
    }

    @Test("reorderMatchRules reorders to match the given id order and pushes")
    func reorder() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("3")))
        let (next, effects) = Reducer.reduce(state, .reorderMatchRules([RuleID("3"), RuleID("1"), RuleID("2")]))
        #expect(next.rules.map(\.id) == [RuleID("3"), RuleID("1"), RuleID("2")])
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("reorderMatchRules ignores unknown ids and appends any rules the order omitted")
    func reorderPartial() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        // order mentions only "2" (and a ghost); "1" was omitted -> kept, appended after
        let (next, _) = Reducer.reduce(state, .reorderMatchRules([RuleID("ghost"), RuleID("2")]))
        #expect(next.rules.map(\.id) == [RuleID("2"), RuleID("1")])
    }

    @Test("the rule-set push carries non-direct assignments and the current rules together")
    func pushCarriesEverything() {
        var state = AppState()
        let a = ProcessID("a")
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)
        let (_, effects) = Reducer.reduce(state, .addMatchRule(rule("r1", host: "*.x")))
        #expect(effects == [.applyRuleSet(
            assignments: [:],
            matchRules: [rule("r1", host: "*.x")]
        )])
    }

    // MARK: - dedup on add

    @Test("re-adding an identical rule doesn't duplicate it — the existing one moves to the top")
    func addExactDuplicateMovesExistingToTop() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1", host: "*.corp", .proxied)))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2", host: "*.other", .proxied)))
        // 同 app/host/port/action、不同 id(用户对同一条连接又点了一次"建规则")。
        let (next, effects) = Reducer.reduce(state, .addMatchRule(rule("3", host: "*.corp", .proxied)))
        // 不新增第二条同键规则;原来那条(id=1)被移到表首。
        #expect(next.rules.map(\.id) == [RuleID("1"), RuleID("2")])
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("re-adding the same app/host/port with a different action updates the action and moves it to the top")
    func addSameKeyDifferentActionUpdatesAndMovesToTop() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1", host: "*.corp", .proxied)))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2", host: "*.other", .proxied)))
        // 此时表是 [2, 1]。对 *.corp 改判成 .direct → 更新动作并置顶。
        let (next, _) = Reducer.reduce(state, .addMatchRule(rule("3", host: "*.corp", .direct)))
        #expect(next.rules.map(\.id) == [RuleID("1"), RuleID("2")])
        #expect(next.rules[0].action == .direct)
        #expect(next.rules[1].action == .proxied)
    }

    @Test("updating a rule's action preserves its isEnabled state")
    func updatePreservesIsEnabled() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1", host: "*.corp", .proxied)))
        (state, _) = Reducer.reduce(state, .setMatchRuleEnabled(id: RuleID("1"), enabled: false))
        let (next, _) = Reducer.reduce(state, .addMatchRule(rule("2", host: "*.corp", .block)))
        #expect(next.rules.map(\.id) == [RuleID("1")])
        #expect(next.rules[0].action == .block)
        #expect(next.rules[0].isEnabled == false)
    }

    @Test("a rule with a different app/host/port combo is inserted on top, keeping the rest in order")
    func addDifferentComboGoesOnTop() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1", host: "*.corp", .proxied)))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2", host: "*.other", .direct)))
        #expect(state.rules.map(\.id) == [RuleID("2"), RuleID("1")])
    }

    @Test("a newly added specific rule outranks a pre-existing catch-all — the shadowing bug that made manual rules dead")
    func newRuleOutranksExistingWildcard() {
        // 先有一条"通配一切 → 代理"(用户配置里真实存在的那条)。
        let wildcard = ProxyMatchRule(
            id: RuleID("wild"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(wildcard))
        // 用户右键某条 a.out 连接 → 建"直连"规则。
        let specific = ProxyMatchRule(
            id: RuleID("specific"), appPattern: "a.out", hostPattern: "1.2.3.4",
            portRange: 443...443, action: .direct
        )
        (state, _) = Reducer.reduce(state, .addMatchRule(specific))
        // 新规则必须排在通配规则**之前**,否则永远轮不到(首个命中生效)。
        #expect(state.rules.map(\.id) == [RuleID("specific"), RuleID("wild")])
    }

    // MARK: - assignRule 收编进规则表(跨入口时间倒排)

    @Test("assignRule derives a host-agnostic rule at the top of the table and updates the process")
    func assignRuleDerivesTableRule() {
        let a = ProcessID("com.example.app")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")

        let (next, effects) = Reducer.reduce(state, .assignRule(processID: a, rule: .proxied))

        #expect(next.processes[a]?.rule == .proxied)
        #expect(next.rules.count == 1)
        #expect(next.rules[0].appPattern == "com.example.app")
        #expect(next.rules[0].hostPattern == "*")
        #expect(next.rules[0].portRange == nil)
        #expect(next.rules[0].action == .proxied)
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("a NEWER per-process assignment outranks an OLDER connection-level rule — recency wins across entries")
    func newerAssignmentOutranksOlderMatchRule() {
        let a = ProcessID("com.example.app")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")
        // 用户上周对某条连接右键"走代理"。
        let old = ProxyMatchRule(
            id: RuleID("old"), appPattern: "com.example.app", hostPattern: "1.2.3.4",
            portRange: 443...443, action: .proxied
        )
        (state, _) = Reducer.reduce(state, .addMatchRule(old))
        // 今天在「应用」表把整个进程改成"直连" → 派生规则必须压在旧规则之上(首个命中生效)。
        let (next, _) = Reducer.reduce(state, .assignRule(processID: a, rule: .direct))
        #expect(next.rules.map(\.appPattern) == ["com.example.app", "com.example.app"])
        #expect(next.rules[0].hostPattern == "*")
        #expect(next.rules[0].action == .direct)
        #expect(next.rules[1].id == RuleID("old"))
    }

    @Test("re-assigning the same process updates the derived rule in place (no duplicates), moved to top")
    func reassignUpsertsDerivedRule() {
        let a = ProcessID("com.example.app")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")
        (state, _) = Reducer.reduce(state, .assignRule(processID: a, rule: .proxied))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("mid", host: "*.other")))
        let (next, _) = Reducer.reduce(state, .assignRule(processID: a, rule: .block))
        // 仍然只有一条派生规则,动作更新为 block,回到表首。
        #expect(next.rules.count == 2)
        #expect(next.rules[0].appPattern == "com.example.app")
        #expect(next.rules[0].action == .block)
    }

    // MARK: - per-rule enable/disable

    @Test("a rule created without specifying isEnabled defaults to enabled (still participates)")
    func defaultsToEnabled() {
        #expect(rule("1").isEnabled)
        let (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        #expect(state.rules.first?.isEnabled == true)
    }

    @Test("setMatchRuleEnabled flips isEnabled on the target rule (leaving others untouched) and pushes the rule set")
    func setEnabledFlipsAndPushes() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .addMatchRule(rule("2")))
        let (next, effects) = Reducer.reduce(state, .setMatchRuleEnabled(id: RuleID("1"), enabled: false))
        #expect(next.rules.first(where: { $0.id == RuleID("1") })?.isEnabled == false)
        #expect(next.rules.first(where: { $0.id == RuleID("2") })?.isEnabled == true)
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
    }

    @Test("disabling keeps the rule in the table (disable is not delete); re-enabling restores it")
    func disableKeepsRuleThenReEnable() {
        var (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        (state, _) = Reducer.reduce(state, .setMatchRuleEnabled(id: RuleID("1"), enabled: false))
        #expect(state.rules.map(\.id) == [RuleID("1")])
        #expect(state.rules.first?.isEnabled == false)
        (state, _) = Reducer.reduce(state, .setMatchRuleEnabled(id: RuleID("1"), enabled: true))
        #expect(state.rules.first?.isEnabled == true)
    }

    @Test("setMatchRuleEnabled for an unknown id is a no-op with no push")
    func setEnabledUnknownIsNoOp() {
        let (state, _) = Reducer.reduce(AppState(), .addMatchRule(rule("1")))
        let (next, effects) = Reducer.reduce(state, .setMatchRuleEnabled(id: RuleID("ghost"), enabled: false))
        #expect(next.rules == state.rules)
        #expect(effects.isEmpty)
    }
}
