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
}
