import Testing
@testable import Core

@Suite("Reducer pure function")
struct ReducerTests {

    @Test("global proxy toggle flips state, no effects")
    func globalToggle() {
        let state = AppState()
        let (next, effects) = Reducer.reduce(state, .setGlobalProxyEnabled(true))
        #expect(next.isGlobalProxyEnabled == true)
        #expect(effects.isEmpty)

        let (next2, _) = Reducer.reduce(next, .setGlobalProxyEnabled(false))
        #expect(next2.isGlobalProxyEnabled == false)
    }

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
        #expect(effects.isEmpty)
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
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 5, bytesDownDelta: 7)])
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
            .flowStatsDeltaReceived([a: FlowStatsDelta(bytesUpDelta: 100, bytesDownDelta: 100)])
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
            .flowStatsDeltaReceived([ghost: FlowStatsDelta(bytesUpDelta: 1, bytesDownDelta: 1)])
        )
        #expect(next.processes[ghost] == nil)
        #expect(next.processes.isEmpty)
    }

    @Test("engine failure fails open: proxy disabled, all rules forced direct, logged")
    func engineFailureFailsOpen() {
        let a = ProcessID("a")
        var state = AppState(isGlobalProxyEnabled: true, isEngineHealthy: true)
        state.processes[a] = MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied)

        let (next, effects) = Reducer.reduce(state, .engineFailure(reason: "transport crashed"))

        #expect(next.isGlobalProxyEnabled == false)
        #expect(next.isEngineHealthy == false)
        #expect(next.processes[a]?.rule == .direct)
        #expect(effects.contains(.log("engine failure, fail-open to direct: transport crashed")))
    }
}
