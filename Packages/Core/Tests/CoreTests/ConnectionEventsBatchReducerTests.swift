import Testing
@testable import Core

@Suite("Reducer — 批量连接事件与逐条语义一致(单次 state 变更)")
struct ConnectionEventsBatchReducerTests {

    private func entry(_ id: String, _ pid: String, phase: ConnectionPhase = .opened) -> ConnectionLogEntry {
        ConnectionLogEntry(
            id: id, processID: ProcessID(pid), host: "h", port: 1,
            rule: .proxied, proxyKind: .socks5, phase: phase, bytesUp: 0, bytesDown: 0
        )
    }

    @Test("批量落地 == 逐条落地(同样的 upsert / 进程注册 / 顺序)")
    func batchEqualsSequential() {
        let entries = [entry("a", "p1"), entry("b", "p2"), entry("a", "p1", phase: .closed)]

        var sequential = AppState()
        for e in entries { sequential = Reducer.reduce(sequential, .connectionEventReceived(e)).0 }

        let (batched, effects) = Reducer.reduce(AppState(), .connectionEventsReceived(entries))

        #expect(batched == sequential)
        #expect(effects.isEmpty)
        // a 被 upsert 成 closed(不新增行),b 独立一行 → 共 2 行。
        #expect(batched.connectionLog.map(\.id) == ["a", "b"])
        #expect(batched.connectionLog.first { $0.id == "a" }?.phase == .closed)
        #expect(batched.processes.count == 2)
    }

    @Test("空批次是纯 no-op")
    func emptyBatchIsNoOp() {
        let (next, effects) = Reducer.reduce(AppState(), .connectionEventsReceived([]))
        #expect(next == AppState())
        #expect(effects.isEmpty)
    }

    @Test("批量也遵守 500 条环形上限")
    func batchRespectsCap() {
        let entries = (0..<(AppState.connectionLogCap + 30)).map { entry("id\($0)", "p\($0)") }
        let (next, _) = Reducer.reduce(AppState(), .connectionEventsReceived(entries))
        #expect(next.connectionLog.count == AppState.connectionLogCap)
        // 丢的是最旧的 30 条。
        #expect(next.connectionLog.first?.id == "id30")
    }
}
