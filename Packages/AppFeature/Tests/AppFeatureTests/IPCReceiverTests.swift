import Testing
import Foundation
import Core
import IPCContract
@testable import AppFeature

/// 这些测试用真实 Store + MockAppSideTransport，验证从「扩展推来一条消息」到
/// 「store.state 真的变了」这整条链路——不是在 mock Store 本身，是在测试真实的
/// 集成行为（IPCReceiver 只是把 Transport 和 Store 接起来，本身没有可单独测的逻辑）。
@Suite("IPCReceiver — wires AppSideTransport incoming messages into Store.dispatch")
struct IPCReceiverTests {

    @Test("a flowStatsBatch delivered via simulateIncoming updates the matching process's stats")
    func flowStatsBatchUpdatesProcessStats() async {
        let marker = ProcessID("marker")
        var initial = AppState()
        initial.processes[marker] = MonitoredProcess(id: marker, displayName: "marker", executablePath: "/marker")

        let store = await MainActor.run { Store(initialState: initial) }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()

        let batch = ExtensionToAppMessage.flowStatsBatch(
            FlowStatsBatchMessage(
                entries: [
                    FlowStatsEntryDTO(processID: ProcessIdentifierDTO("marker"), bytesUpDelta: 5, bytesDownDelta: 7)
                ],
                windowStart: .init(timeIntervalSince1970: 0),
                windowEnd: .init(timeIntervalSince1970: 1)
            )
        )
        await transport.simulateIncoming(batch)

        var stats: FlowStats?
        for _ in 0..<100 {
            stats = await MainActor.run { store.state.processes[marker]?.stats }
            if stats == FlowStats(bytesUp: 5, bytesDown: 7) { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(stats == FlowStats(bytesUp: 5, bytesDown: 7))
    }

    @Test("a diagnosticResult delivered via simulateIncoming records the outcome in store.state.diagnostics")
    func diagnosticResultUpdatesDiagnostics() async {
        let processID = ProcessID("proc")
        let store = await MainActor.run { Store() }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()

        let result = DiagnosticResultDTO(
            processID: ProcessIdentifierDTO("proc"), kind: .dnsResolution, passed: true, detail: "ok"
        )
        await transport.simulateIncoming(.diagnosticResult(result))

        var outcome: DiagnosticOutcome?
        for _ in 0..<100 {
            outcome = await MainActor.run { store.state.diagnostics[processID]?[.dnsResolution] }
            if outcome != nil { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(outcome == DiagnosticOutcome(passed: true, detail: "ok"))
    }

    @Test("an engineFailure delivered via simulateIncoming flips isEngineHealthy to false")
    func engineFailureUpdatesHealth() async {
        let store = await MainActor.run { Store() }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()

        await transport.simulateIncoming(.engineFailure(reason: "boom"))

        var healthy = true
        for _ in 0..<100 {
            healthy = await MainActor.run { store.state.isEngineHealthy }
            if !healthy { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(healthy == false)
    }

    @Test("a connectionEvent delivered via simulateIncoming is dispatched into state AND appended to the log file store")
    func connectionEventPersistsToFileStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("connections.log.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fileStore = ConnectionLogFileStore(fileURL: url)

        let store = await MainActor.run { Store() }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run {
            IPCReceiver(store: store, transport: transport, connectionLogFileStore: fileStore)
        }
        await receiver.start()

        let dto = ConnectionEventDTO(
            id: "c1", processID: ProcessIdentifierDTO("com.x"), targetHost: "example.com", targetPort: 443,
            rule: .proxied, proxyKind: .socks5, phase: .opened, bytesUp: 0, bytesDown: 0
        )
        await transport.simulateIncoming(.connectionEvent(dto))

        // 落盘经 actor + Task,轮询等它出现。
        var loaded: [Core.ConnectionLogEntry] = []
        for _ in 0..<100 {
            loaded = await fileStore.loadRecent(limit: 10)
            if !loaded.isEmpty { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(loaded.map(\.id) == ["c1"])
        // 同时确认既有内存链路没被影响:它也进了 store.state.connectionLog。
        let inState = await MainActor.run { store.state.connectionLog.map(\.id) }
        #expect(inState == ["c1"])
    }

    @Test("stop() after start() prevents a later incoming message from reaching the store")
    func stopPreventsFurtherDispatch() async {
        let store = await MainActor.run { Store() }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()
        await receiver.stop()

        await transport.simulateIncoming(.engineFailure(reason: "boom"))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let healthy = await MainActor.run { store.state.isEngineHealthy }
        #expect(healthy == true)
    }
}
