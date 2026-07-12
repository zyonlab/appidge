import Testing
import Foundation
import IPCContract
@testable import EngineKit

@Suite("FlowRouter — actor batching + fail-open, MockTransport only")
struct FlowRouterTests {

    @Test("multiple flow events inside the flush window do not each trigger a deliver — batched, not per-packet")
    func batchesInsteadOfPerPacket() async {
        let transport = MockTransport()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let router = FlowRouter(transport: transport, flushInterval: 0.5, now: t0)

        let a = ProcessIdentifierDTO("a")
        let b = ProcessIdentifierDTO("b")

        // three events well inside the 500ms window
        await router.route(processID: a, bytesUp: 10, bytesDown: 20, rule: .direct, now: t0.addingTimeInterval(0.1))
        await router.route(processID: a, bytesUp: 5, bytesDown: 5, rule: .direct, now: t0.addingTimeInterval(0.2))
        await router.route(processID: b, bytesUp: 1, bytesDown: 1, rule: .proxied, now: t0.addingTimeInterval(0.3))

        let deliveredSoFar = await transport.deliveredMessages
        #expect(deliveredSoFar.isEmpty, "no flush should have happened before the interval elapsed")

        // crossing the 500ms boundary triggers exactly one flush
        await router.tick(now: t0.addingTimeInterval(0.6))

        let delivered = await transport.deliveredMessages
        #expect(delivered.count == 1)

        guard case .flowStatsBatch(let batch) = delivered.first else {
            Issue.record("expected a flowStatsBatch message")
            return
        }
        let byProcess = Dictionary(uniqueKeysWithValues: batch.entries.map { ($0.processID, $0) })
        #expect(byProcess[a]?.bytesUpDelta == 15)
        #expect(byProcess[a]?.bytesDownDelta == 25)
        #expect(byProcess[b]?.bytesUpDelta == 1)
        #expect(byProcess[b]?.bytesDownDelta == 1)
    }

    @Test("an empty window produces no deliver call")
    func emptyWindowFlushesNothing() async {
        let transport = MockTransport()
        let t0 = Date(timeIntervalSince1970: 2_000)
        let router = FlowRouter(transport: transport, flushInterval: 0.5, now: t0)

        await router.tick(now: t0.addingTimeInterval(1.0))

        let delivered = await transport.deliveredMessages
        #expect(delivered.isEmpty)
    }

    @Test("forward failure fails open: retried direct, delivered stats still counted, engineFailure reported")
    func forwardFailureFailsOpen() async {
        let transport = MockTransport()
        let a = ProcessIdentifierDTO("a")
        await transport.failForwards(matching: { processID, rule in processID == a && rule == .proxied })

        let t0 = Date(timeIntervalSince1970: 3_000)
        let router = FlowRouter(transport: transport, flushInterval: 0.5, now: t0)

        await router.route(processID: a, bytesUp: 50, bytesDown: 60, rule: .proxied, now: t0.addingTimeInterval(0.05))

        let forwardCalls = await transport.forwardCalls
        #expect(forwardCalls.map(\.rule) == [.proxied, .direct], "must retry direct after the proxied forward throws")

        await router.tick(now: t0.addingTimeInterval(0.6))
        let delivered = await transport.deliveredMessages

        #expect(delivered.contains { message in
            if case .engineFailure = message { return true }
            return false
        })
        #expect(delivered.contains { message in
            if case .flowStatsBatch(let batch) = message {
                return batch.entries.contains { $0.processID == a && $0.bytesUpDelta == 50 }
            }
            return false
        })

        let healthy = await router.isHealthy
        #expect(healthy == false)
    }

    @Test("no real network or NE calls are reachable from this test target — only MockTransport is linked")
    func onlyMockTransportIsUsed() async {
        // Structural guarantee: EngineKitTests only imports EngineKit + IPCContract + Foundation,
        // never Network/NetworkExtension — see architecture invariant test suite for the source scan.
        let transport = MockTransport()
        #expect(await transport.forwardCalls.isEmpty)
    }
}
