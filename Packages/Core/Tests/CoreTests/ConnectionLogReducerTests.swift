import Testing
@testable import Core

@Suite("Reducer — connection log (upsert by id, capped)")
struct ConnectionLogReducerTests {

    private func entry(
        _ id: String, phase: ConnectionPhase = .opened, up: Int64 = 0, down: Int64 = 0
    ) -> ConnectionLogEntry {
        ConnectionLogEntry(
            id: id, processID: ProcessID("com.x"), host: "example.com", port: 443,
            rule: .proxied, proxyKind: .socks5, phase: phase, bytesUp: up, bytesDown: down
        )
    }

    @Test("a new connection event appends an entry, no effects")
    func appendNew() {
        let (next, effects) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1")))
        #expect(next.connectionLog.map(\.id) == ["c1"])
        #expect(next.connectionLog.first?.phase == .opened)
        #expect(effects.isEmpty)
    }

    @Test("a later event for the same id updates that entry in place (phase + bytes), no duplicate row")
    func upsertSameID() {
        var (state, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1", phase: .opened)))
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c1", phase: .closed, up: 100, down: 900)))
        #expect(state.connectionLog.count == 1)
        #expect(state.connectionLog.first?.phase == .closed)
        #expect(state.connectionLog.first?.bytesUp == 100)
        #expect(state.connectionLog.first?.bytesDown == 900)
    }

    @Test("a late .opened refresh never resurrects an already-closed row (periodic byte backfill race)")
    func lateOpenedRefreshDoesNotResurrectClosedRow() {
        // 扩展对活跃连接周期性重发 .opened 事件回填字节;若关闭事件先落地、迟到的回填事件
        // 后到(Task 投递无序),绝不能把已关闭的行改回「活动」——否则该行永远显示绿点。
        var (state, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1", phase: .opened)))
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c1", phase: .closed, up: 100, down: 900)))
        let closed = state.connectionLog.first
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c1", phase: .opened, up: 90, down: 800)))
        #expect(state.connectionLog.count == 1)
        #expect(state.connectionLog.first == closed)   // 整行原样保留:phase 仍 closed,字节仍是关闭时的最终值
        // failed 同理
        var (s2, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c2", phase: .failed)))
        (s2, _) = Reducer.reduce(s2, .connectionEventReceived(entry("c2", phase: .opened, up: 1)))
        #expect(s2.connectionLog.first?.phase == .failed)
    }

    @Test("updating one connection leaves the others untouched and preserves order")
    func upsertPreservesOrder() {
        var (state, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("a")))
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("b")))
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c")))
        let bBefore = state.connectionLog[1]
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("a", phase: .closed, up: 5)))
        #expect(state.connectionLog.map(\.id) == ["a", "b", "c"]) // order stable
        #expect(state.connectionLog[1] == bBefore)               // b untouched
        #expect(state.connectionLog[0].phase == .closed)         // a updated
    }

    @Test("the log is capped: appending beyond the cap drops the oldest")
    func capped() {
        var state = AppState()
        for i in 0..<(AppState.connectionLogCap + 10) {
            (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c\(i)")))
        }
        #expect(state.connectionLog.count == AppState.connectionLogCap)
        // oldest ("c0".."c9") evicted; newest present
        #expect(state.connectionLog.first?.id == "c10")
        #expect(state.connectionLog.last?.id == "c\(AppState.connectionLogCap + 9)")
    }

    @Test("updating an existing id does not count against the cap or reorder")
    func updateDoesNotGrow() {
        var state = AppState()
        for i in 0..<AppState.connectionLogCap {
            (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c\(i)")))
        }
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("c0", phase: .closed)))
        #expect(state.connectionLog.count == AppState.connectionLogCap)
        #expect(state.connectionLog.first?.id == "c0") // still first, updated in place
        #expect(state.connectionLog.first?.phase == .closed)
    }

    @Test("a connection event for a never-before-seen process registers it in state.processes (default direct)")
    func registersUnknownProcess() {
        let (next, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1")))
        #expect(next.processes[ProcessID("com.x")]?.rule == .direct)
        #expect(next.processes[ProcessID("com.x")]?.displayName == "com.x")
    }

    @Test("a connection event for an already-known process leaves its displayName/rule untouched")
    func knownProcessUntouched() {
        var state = AppState()
        state.processes[ProcessID("com.x")] = MonitoredProcess(
            id: ProcessID("com.x"), displayName: "My App", executablePath: "/Applications/My App.app", rule: .proxied
        )
        let (next, _) = Reducer.reduce(state, .connectionEventReceived(entry("c1")))
        #expect(next.processes[ProcessID("com.x")]?.displayName == "My App")
        #expect(next.processes[ProcessID("com.x")]?.rule == .proxied)
    }

    @Test("registering a new process from a connection event does not itself emit a rule-set push")
    func registeringDoesNotPushRuleSet() {
        let (_, effects) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1")))
        #expect(effects.isEmpty)
    }

    @Test("a connection event carrying processDisplayName uses it as the registered displayName")
    func registersWithProcessDisplayName() {
        let named = ConnectionLogEntry(
            id: "c1", processID: ProcessID("a.out"), host: "example.com", port: 443,
            rule: .proxied, proxyKind: .socks5, phase: .opened, bytesUp: 0, bytesDown: 0,
            processDisplayName: "xray"
        )
        let (next, _) = Reducer.reduce(AppState(), .connectionEventReceived(named))
        #expect(next.processes[ProcessID("a.out")]?.displayName == "xray")
    }

    @Test("a connection event without processDisplayName falls back to the raw processID for the registered displayName")
    func registersWithoutProcessDisplayNameFallsBackToID() {
        let (next, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("c1")))
        #expect(next.processes[ProcessID("com.x")]?.displayName == "com.x")
    }

    // MARK: - clearConnectionLog

    @Test("clearConnectionLog empties connectionLog and emits an effect to clear the on-disk file")
    func clearConnectionLogEmptiesAndPushesEffect() {
        var (state, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("a")))
        (state, _) = Reducer.reduce(state, .connectionEventReceived(entry("b")))
        let (next, effects) = Reducer.reduce(state, .clearConnectionLog)
        #expect(next.connectionLog.isEmpty)
        #expect(effects == [.clearConnectionLogFile])
    }

    @Test("clearConnectionLog does not touch processes — only the log rows go away")
    func clearConnectionLogLeavesProcessesUntouched() {
        let (state, _) = Reducer.reduce(AppState(), .connectionEventReceived(entry("a")))
        #expect(state.processes[ProcessID("com.x")] != nil)
        let (next, _) = Reducer.reduce(state, .clearConnectionLog)
        #expect(next.processes[ProcessID("com.x")] != nil)
    }

    @Test("clearConnectionLog on an already-empty log is a no-op with no effect")
    func clearConnectionLogEmptyIsNoOp() {
        let (next, effects) = Reducer.reduce(AppState(), .clearConnectionLog)
        #expect(next.connectionLog.isEmpty)
        #expect(effects.isEmpty)
    }

    // MARK: - normalizedForRestore

    @Test("normalizedForRestore flips an opened entry to closed")
    func normalizedForRestoreFlipsOpenedToClosed() {
        let restored = entry("c1", phase: .opened).normalizedForRestore()
        #expect(restored.phase == .closed)
    }

    @Test("normalizedForRestore leaves closed/failed entries untouched")
    func normalizedForRestoreLeavesTerminalPhasesAlone() {
        #expect(entry("c1", phase: .closed).normalizedForRestore().phase == .closed)
        #expect(entry("c1", phase: .failed).normalizedForRestore().phase == .failed)
    }

    @Test("normalizedForRestore only touches phase — every other field is preserved")
    func normalizedForRestorePreservesOtherFields() {
        let original = entry("c1", phase: .opened, up: 10, down: 20)
        let restored = original.normalizedForRestore()
        #expect(restored.id == original.id)
        #expect(restored.processID == original.processID)
        #expect(restored.host == original.host)
        #expect(restored.bytesUp == original.bytesUp)
        #expect(restored.bytesDown == original.bytesDown)
    }
}
