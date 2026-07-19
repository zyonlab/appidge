import Testing
import Core
@testable import AppFeature

/// `PersistedConfiguration.restorationActions()` is the testable core of onboarding
/// restore: turning a loaded configuration into the exact ordered `Core.Action`s the
/// app dispatches at launch. It only reuses existing `Core.Action` cases
/// (`directoryScanned`, `processDiscovered`, `assignRule`, `onboardingCompleted`) —
/// no new case was needed. Kept in AppFeature (not App/AppidgeApp.swift) specifically
/// so this decision logic gets real TDD coverage; App/OnboardingView.swift and
/// AppidgeApp.swift stay thin SwiftUI glue, same as the existing untested
/// App/ContentView.swift.
@Suite("PersistedConfiguration.restorationActions — ordered Action sequence for launch restore")
struct PersistenceRestorationTests {

    @Test("empty configuration produces no actions")
    func emptyConfigurationProducesNoActions() {
        let actions = PersistedConfiguration().restorationActions()
        #expect(actions.isEmpty)
    }

    @Test("catalog entries become a single batched directoryScanned action, sorted by id")
    func catalogBecomesSingleDirectoryScannedAction() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(catalog: [
            b: DirectoryEntry(id: b, displayName: "B", executablePath: "/b"),
            a: DirectoryEntry(id: a, displayName: "A", executablePath: "/a")
        ])
        let actions = config.restorationActions()
        #expect(actions == [.directoryScanned([
            DirectoryEntry(id: a, displayName: "A", executablePath: "/a"),
            DirectoryEntry(id: b, displayName: "B", executablePath: "/b")
        ])])
    }

    @Test("a process with the default .direct rule only emits processDiscovered")
    func processWithDefaultRuleOnlyEmitsDiscovery() {
        let id = ProcessID("x")
        let config = PersistedConfiguration(processes: [
            id: MonitoredProcess(id: id, displayName: "X", executablePath: "/x", rule: .direct)
        ])
        let actions = config.restorationActions()
        #expect(actions == [.processDiscovered(id: id, displayName: "X", executablePath: "/x")])
    }

    @Test("a process with a non-default rule emits processDiscovered then assignRule")
    func processWithNonDefaultRuleEmitsDiscoveryThenAssignRule() {
        let id = ProcessID("x")
        let config = PersistedConfiguration(processes: [
            id: MonitoredProcess(id: id, displayName: "X", executablePath: "/x", rule: .proxied)
        ])
        let actions = config.restorationActions()
        #expect(actions == [
            .processDiscovered(id: id, displayName: "X", executablePath: "/x"),
            .assignRule(processID: id, rule: .proxied)
        ])
    }

    @Test("multiple processes are emitted in deterministic id-sorted order")
    func multipleProcessesAreSortedById() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(processes: [
            b: MonitoredProcess(id: b, displayName: "B", executablePath: "/b", rule: .proxied),
            a: MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .direct)
        ])
        let actions = config.restorationActions()
        #expect(actions == [
            .processDiscovered(id: a, displayName: "A", executablePath: "/a"),
            .processDiscovered(id: b, displayName: "B", executablePath: "/b"),
            .assignRule(processID: b, rule: .proxied)
        ])
    }

    /// `addMatchRule` 是"插到表首"语义(新规则优先级最高),所以恢复时必须**倒序**重放,
    /// 每次置顶正好把持久化的优先级顺序原样重建。正序重放会把整表颠倒。
    @Test("matchRules become addMatchRule actions in reverse order, so insert-at-top rebuilds the saved priority order")
    func matchRulesBecomeAddMatchRuleActionsInReverseOrder() {
        let r1 = ProxyMatchRule(id: RuleID("r1"), appPattern: "a.out", hostPattern: "1.2.3.4", portRange: nil, action: .direct)
        let r2 = ProxyMatchRule(
            id: RuleID("r2"), appPattern: "*", hostPattern: "*.example.com",
            portRange: 443...443, action: .block, isEnabled: false
        )
        let config = PersistedConfiguration(matchRules: [r1, r2])
        let actions = config.restorationActions()
        #expect(actions == [.addMatchRule(r2), .addMatchRule(r1)])
    }

    /// 端到端的那条才是真正的契约:倒序重放 + 置顶插入,重建出来的 `state.rules` 必须和存盘时**完全一致**。
    @Test("replaying restored matchRules through the real reducer reproduces the saved priority order exactly")
    func replayingMatchRulesReproducesSavedOrder() {
        let saved = [
            ProxyMatchRule(id: RuleID("top"), appPattern: "a.out", hostPattern: "1.2.3.4", portRange: nil, action: .direct),
            ProxyMatchRule(id: RuleID("mid"), appPattern: "b", hostPattern: "*", portRange: nil, action: .observe),
            ProxyMatchRule(id: RuleID("wild"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied)
        ]
        var state = AppState()
        for action in PersistedConfiguration(matchRules: saved).restorationActions() {
            let (next, _) = Reducer.reduce(state, action)
            state = next
        }
        #expect(state.rules == saved)
    }

    @Test("matchRules are restored after process discovery/rule assignment, before proxy servers")
    func matchRulesOrderedBetweenProcessesAndProxyServers() {
        let processID = ProcessID("x")
        let rule = ProxyMatchRule(id: RuleID("r1"), appPattern: "x", hostPattern: "*", portRange: nil, action: .block)
        let config = PersistedConfiguration(
            processes: [processID: MonitoredProcess(id: processID, displayName: "X", executablePath: "/x", rule: .proxied)],
            proxyServers: [PersistedProxyServer(id: "s1", host: "h", port: 1080, kind: .socks5, username: nil)],
            matchRules: [rule]
        )
        let actions = config.restorationActions()
        #expect(actions == [
            .processDiscovered(id: processID, displayName: "X", executablePath: "/x"),
            .assignRule(processID: processID, rule: .proxied),
            .addMatchRule(rule),
            .addProxyServer(PersistedProxyServer(id: "s1", host: "h", port: 1080, kind: .socks5, username: nil).toProxyServer()),
            .setActiveProxyServer(nil)
        ])
    }

    /// 真机实锤的「删了规则重启又出现」端到端回归:应用页设走法(assignRule 派生规则 + 置 process.rule)
    /// → 规则页删掉那条派生规则 → 存盘快照 → 重启重放。修复前 process.rule 没随删除复位,重放 assignRule
    /// 把规则复活;修复后 removeMatchRule 复位 process.rule,重放不再产出这条规则。
    @Test("deleting an app-derived rule then round-tripping through persistence does not resurrect it")
    func deletingDerivedRuleSurvivesRestore() {
        let pid = ProcessID("com.example.yunti")
        var state = AppState()
        state = Reducer.reduce(state, .processDiscovered(id: pid, displayName: "云梯", executablePath: "/x")).0
        state = Reducer.reduce(state, .assignRule(processID: pid, rule: .proxied)).0
        let derivedID = RuleID("process:\(pid.value)")
        #expect(state.rules.contains { $0.id == derivedID })

        // 规则页删掉派生规则。
        state = Reducer.reduce(state, .removeMatchRule(derivedID)).0
        #expect(state.rules.isEmpty)

        // 存盘 → 重启:重放持久化快照,规则必须仍不存在(不复活)。
        var restored = AppState()
        for action in PersistedConfiguration(from: state).restorationActions() {
            restored = Reducer.reduce(restored, action).0
        }
        #expect(restored.rules.contains { $0.id == derivedID } == false)
        #expect(restored.rules.isEmpty)
    }

    @Test("hasCompletedOnboarding true appends a trailing onboardingCompleted action")
    func onboardingCompletedIsAppendedLast() {
        let config = PersistedConfiguration(hasCompletedOnboarding: true)
        #expect(config.restorationActions() == [.onboardingCompleted])
    }

    @Test("hasCompletedOnboarding false emits no onboarding action")
    func onboardingNotCompletedEmitsNoAction() {
        let config = PersistedConfiguration(hasCompletedOnboarding: false)
        #expect(config.restorationActions().isEmpty)
    }

    @Test("replaying restorationActions through the real reducer reconstructs an equivalent AppState")
    func replayingActionsThroughReducerReconstructsState() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(
            processes: [
                a: MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied),
                b: MonitoredProcess(id: b, displayName: "B", executablePath: "/b", rule: .direct)
            ],
            catalog: [
                a: DirectoryEntry(id: a, displayName: "A", executablePath: "/a", industryTag: .technology)
            ],
            hasCompletedOnboarding: true,
            matchRules: [ProxyMatchRule(
                id: RuleID("r1"), appPattern: "a.out", hostPattern: "1.2.3.4", portRange: nil, action: .direct
            )]
        )

        var state = AppState()
        for action in config.restorationActions() {
            let (next, _) = Reducer.reduce(state, action)
            state = next
        }

        #expect(state.catalog == config.catalog)
        #expect(state.processes[a]?.displayName == "A")
        #expect(state.processes[a]?.rule == .proxied)
        #expect(state.processes[b]?.displayName == "B")
        #expect(state.processes[b]?.rule == .direct)
        #expect(state.hasCompletedOnboarding == true)
        // assignRule 重放会为非默认的每进程规则派生一条「进程 × * × *」规则(见 Reducer.assignRule
        // 的"收编进规则表");真实 round-trip 里它本来就在持久化的 matchRules 里(存盘时就是从
        // state.rules 带走的),这个手工 fixture 没带,所以重放后补在表尾。持久化的规则表本身
        // 顺序原样在前。
        #expect(Array(state.rules.prefix(config.matchRules.count)) == config.matchRules)
        #expect(state.rules.count == config.matchRules.count + 1)
        #expect(state.rules.last?.appPattern == "a")
        #expect(state.rules.last?.action == .proxied)
        // Runtime/ephemeral fields untouched by restore, still at their fresh-launch defaults.
        #expect(state.isEngineHealthy == true)
    }
}
