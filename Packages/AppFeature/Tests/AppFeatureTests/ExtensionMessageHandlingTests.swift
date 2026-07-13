import Testing
import Core
import IPCContract
@testable import AppFeature

@Suite("ExtensionMessageHandling — pure translation from IPCContract wire messages to Core.Action")
struct ExtensionMessageHandlingTests {

    @Test("flowStatsBatch with no entries produces one flowStatsDeltaReceived with an empty dictionary")
    func emptyFlowStatsBatch() {
        let batch = FlowStatsBatchMessage(
            entries: [],
            windowStart: .init(timeIntervalSince1970: 0),
            windowEnd: .init(timeIntervalSince1970: 1)
        )
        let actions = ExtensionMessageHandling.actions(for: .flowStatsBatch(batch))

        #expect(actions == [.flowStatsDeltaReceived([:])])
    }

    @Test("flowStatsBatch with multiple entries maps each DTO to a ProcessID/FlowStatsDelta pair")
    func multiEntryFlowStatsBatch() {
        let batch = FlowStatsBatchMessage(
            entries: [
                FlowStatsEntryDTO(processID: ProcessIdentifierDTO("a"), bytesUpDelta: 10, bytesDownDelta: 20),
                FlowStatsEntryDTO(processID: ProcessIdentifierDTO("b"), bytesUpDelta: 30, bytesDownDelta: 40)
            ],
            windowStart: .init(timeIntervalSince1970: 0),
            windowEnd: .init(timeIntervalSince1970: 1)
        )
        let actions = ExtensionMessageHandling.actions(for: .flowStatsBatch(batch))

        let expected: [Core.ProcessID: Core.FlowStatsDelta] = [
            Core.ProcessID("a"): Core.FlowStatsDelta(bytesUpDelta: 10, bytesDownDelta: 20),
            Core.ProcessID("b"): Core.FlowStatsDelta(bytesUpDelta: 30, bytesDownDelta: 40)
        ]
        #expect(actions == [.flowStatsDeltaReceived(expected)])
    }

    @Test("diagnosticResult maps processID, kind, passed, detail into diagnosticResultReceived")
    func diagnosticResultMapsFields() {
        let result = DiagnosticResultDTO(
            processID: ProcessIdentifierDTO("proc-1"),
            kind: .upstreamReachable,
            passed: true,
            detail: "reached in 12ms"
        )
        let actions = ExtensionMessageHandling.actions(for: .diagnosticResult(result))

        #expect(actions == [
            .diagnosticResultReceived(
                processID: Core.ProcessID("proc-1"),
                kind: .upstreamReachable,
                passed: true,
                detail: "reached in 12ms"
            )
        ])
    }

    @Test(
        "diagnosticResult kind mapping is exhaustive and 1:1 across all six DiagnosticKindDTO cases",
        arguments: [
            (DiagnosticKindDTO.ruleHit, Core.DiagnosticKind.ruleHit),
            (DiagnosticKindDTO.actuallyProxied, Core.DiagnosticKind.actuallyProxied),
            (DiagnosticKindDTO.upstreamReachable, Core.DiagnosticKind.upstreamReachable),
            (DiagnosticKindDTO.dnsResolution, Core.DiagnosticKind.dnsResolution),
            (DiagnosticKindDTO.udpIPv6QuicLeak, Core.DiagnosticKind.udpIPv6QuicLeak),
            (DiagnosticKindDTO.envConflict, Core.DiagnosticKind.envConflict)
        ]
    )
    func diagnosticKindMappingIsExhaustive(dto: DiagnosticKindDTO, expectedCore: Core.DiagnosticKind) {
        let result = DiagnosticResultDTO(processID: ProcessIdentifierDTO("p"), kind: dto, passed: false, detail: "")
        let actions = ExtensionMessageHandling.actions(for: .diagnosticResult(result))

        #expect(actions == [
            .diagnosticResultReceived(processID: Core.ProcessID("p"), kind: expectedCore, passed: false, detail: "")
        ])
    }

    @Test("engineFailure maps reason through unchanged")
    func engineFailureMapsReason() {
        let actions = ExtensionMessageHandling.actions(for: .engineFailure(reason: "transport down"))

        #expect(actions == [.engineFailure(reason: "transport down")])
    }
}
