import Testing
@testable import Core

@Suite("Reducer pure function")
struct ReducerTests {

    @Test("discovering a process inserts it once, idempotent on rediscovery")
    func addProcess() {
        let id = ProcessID("com.example.curl")
        let state = AppState()
        let (next, effects) = Reducer.reduce(
            state,
            .processDiscovered(id: id, displayName: "curl", executablePath: "/usr/bin/curl")
        )
        #expect(next.processes[id]?.displayName == "curl")
        #expect(next.processes[id]?.rule == .direct)
        #expect(effects.isEmpty)

        // rediscovering the same stable id must not clobber user-assigned state
        let (afterAssign, _) = Reducer.reduce(next, .assignRule(processID: id, rule: .proxied))
        let (rediscovered, _) = Reducer.reduce(
            afterAssign,
            .processDiscovered(id: id, displayName: "curl", executablePath: "/usr/bin/curl")
        )
        #expect(rediscovered.processes[id]?.rule == .proxied)
        #expect(rediscovered.processes.count == 1)
    }

    @Test("assigning a rule updates only the targeted process")
    func assignRule() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")
        state.processes[b] = MonitoredProcess(id: b, displayName: "B", executablePath: "/b")

        let (next, effects) = Reducer.reduce(state, .assignRule(processID: a, rule: .proxied))
        #expect(next.processes[a]?.rule == .proxied)
        #expect(next.processes[b]?.rule == .direct)
        // assignRule 派生「该进程 × * × *」规则收编进规则表;规则表是唯一路由真相,
        // assignments 恒为空(见 ruleSetPush)。
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: next.rules)])
        #expect(next.rules.map(\.appPattern) == ["a"])
    }

    @Test("flowStatsDelta accumulates onto existing per-process stats")
    func flowStatsDelta() {
        let a = ProcessID("a")
        var state = AppState()
        state.processes[a] = MonitoredProcess(
            id: a, displayName: "A", executablePath: "/a",
            stats: FlowStats(bytesUp: 10, bytesDown: 20)
        )

        let (next, effects) = Reducer.reduce(
            state,
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 5, bytesDownDelta: 7)], intervalSeconds: 0.5)
        )
        #expect(next.processes[a]?.stats == FlowStats(bytesUp: 15, bytesDown: 27))
        #expect(effects.isEmpty)
    }

    @Test("flowStatsDelta only touches matched ids — untouched entries stay value-equal (no full recompute)")
    func flowStatsDeltaIsIncremental() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let c = ProcessID("c")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", stats: FlowStats(bytesUp: 1, bytesDown: 1))
        state.processes[b] = MonitoredProcess(id: b, displayName: "B", executablePath: "/b", stats: FlowStats(bytesUp: 2, bytesDown: 2))
        state.processes[c] = MonitoredProcess(id: c, displayName: "C", executablePath: "/c", stats: FlowStats(bytesUp: 3, bytesDown: 3))

        let bBefore = state.processes[b]!
        let cBefore = state.processes[c]!

        let (next, _) = Reducer.reduce(
            state,
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 100, bytesDownDelta: 100)], intervalSeconds: 0.5)
        )

        #expect(next.processes[a]?.stats == FlowStats(bytesUp: 101, bytesDown: 101))
        #expect(next.processes[b] == bBefore)
        #expect(next.processes[c] == cBefore)
    }

    @Test("delta for an unknown id is dropped, not inserted")
    func flowStatsDeltaUnknownIdIsIgnored() {
        let ghost = ProcessID("ghost")
        let state = AppState()
        let (next, _) = Reducer.reduce(
            state,
            .flowStatsDeltaReceived([ghost: FlowStatsDelta(bytesUpDelta: 1, bytesDownDelta: 1)], intervalSeconds: 0.5)
        )
        #expect(next.processes[ghost] == nil)
        #expect(next.processes.isEmpty)
    }

    @Test("flowStatsDelta 算每进程瞬时速率 = 增量 ÷ 时间窗;本批没数据的进程速率衰减到 0")
    func flowStatsDeltaComputesRate() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")
        // b 上一批算过速率,本批没它的数据 → 应衰减到 0(空闲即 0)。
        state.processes[b] = MonitoredProcess(id: b, displayName: "B", executablePath: "/b")
        state.processes[b]?.rateDownPerSec = 999

        // 本批只有 a:0.5s 窗内 ↓1000、↑250 字节 → ↓2000 B/s、↑500 B/s。
        let (next, _) = Reducer.reduce(
            state,
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 250, bytesDownDelta: 1000)], intervalSeconds: 0.5)
        )
        #expect(next.processes[a]?.rateDownPerSec == 2000)
        #expect(next.processes[a]?.rateUpPerSec == 500)
        #expect(next.processes[a]?.stats == FlowStats(bytesUp: 250, bytesDown: 1000)) // 累计照旧
        #expect(next.processes[b]?.rateDownPerSec == 0) // 本批没数据 → 归 0
    }

    @Test("flowStatsDelta 时间窗非正时只累计字节、速率保持 0(不除零)")
    func flowStatsDeltaZeroIntervalNoRate() {
        let a = ProcessID("a")
        var state = AppState()
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a")
        let (next, _) = Reducer.reduce(
            state,
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 10, bytesDownDelta: 20)], intervalSeconds: 0)
        )
        #expect(next.processes[a]?.stats == FlowStats(bytesUp: 10, bytesDown: 20))
        #expect(next.processes[a]?.rateUpPerSec == 0)
        #expect(next.processes[a]?.rateDownPerSec == 0)
    }

    @Test("engine failure fails open AT THE EXTENSION: pushes an empty rule set, keeps user config intact")
    func engineFailureFailsOpen() {
        let a = ProcessID("a")
        var state = AppState(isEngineHealthy: true)
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)
        state.rules = [ProxyMatchRule(
            id: RuleID("r"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]

        let (next, effects) = Reducer.reduce(state, .engineFailure(reason: "transport crashed"))

        #expect(next.isEngineHealthy == false)
        // 用户配置(每进程规则/规则表)不被破坏——fail-open 靠"推空规则集"实现,不靠清写持久化配置。
        #expect(next.processes[a]?.rule == .proxied)
        #expect(next.rules == state.rules)
        // 真正在路由的是扩展:必须把 fail-open 推下去(空 assignments + 空 matchRules = 全部默认直连)。
        #expect(effects.contains(.applyRuleSet(assignments: [:], matchRules: [])))
        #expect(effects.contains(.log("engine failure, fail-open to direct: transport crashed")))
    }

    @Test("while the engine is unhealthy every rule-set push stays fail-open (empty), including resync")
    func unhealthyPushesStayFailOpen() {
        var state = AppState(isEngineHealthy: false)
        let a = ProcessID("a")
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)

        let (_, effects) = Reducer.reduce(state, .addMatchRule(ProxyMatchRule(
            id: RuleID("r"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )))
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: [])])

        let (_, resyncEffects) = Reducer.reduce(state, .resyncExtension)
        #expect(resyncEffects.first == .applyRuleSet(assignments: [:], matchRules: []))
    }

    @Test("extension becoming active again restores engine health and re-pushes the real rule set")
    func activationRecoversEngineHealth() {
        var state = AppState(isEngineHealthy: false)
        let a = ProcessID("a")
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)

        let (next, effects) = Reducer.reduce(state, .extensionActivationChanged(.active))

        #expect(next.isEngineHealthy == true)
        #expect(effects == [.applyRuleSet(assignments: [:], matchRules: [])])
    }

    @Test("activation changes that are not .active do not touch engine health and push nothing")
    func nonActiveActivationLeavesHealthAlone() {
        let state = AppState(isEngineHealthy: false)
        let (next, effects) = Reducer.reduce(state, .extensionActivationChanged(.needsApproval))
        #expect(next.isEngineHealthy == false)
        #expect(effects.isEmpty)
    }
}
