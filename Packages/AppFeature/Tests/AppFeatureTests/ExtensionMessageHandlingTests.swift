import Testing
import Foundation
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

        #expect(actions == [.flowStatsDeltaReceived([:], intervalSeconds: 1)]) // 窗 0→1s
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
        #expect(actions == [.flowStatsDeltaReceived(expected, intervalSeconds: 1)]) // 窗 0→1s
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

    @Test("connectionEvent maps every field into a connectionEventReceived action")
    func connectionEventMapsFields() {
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = ConnectionEventDTO(
            id: "c1", processID: ProcessIdentifierDTO("com.x"), targetHost: "example.com", targetPort: 443,
            rule: .proxied, proxyKind: .httpConnect, phase: .closed, bytesUp: 12, bytesDown: 34,
            openedAt: openedAt
        )
        let actions = ExtensionMessageHandling.actions(for: .connectionEvent(dto))

        #expect(actions == [.connectionEventReceived(Core.ConnectionLogEntry(
            id: "c1", processID: Core.ProcessID("com.x"), host: "example.com", port: 443,
            rule: .proxied, proxyKind: .httpConnect, phase: .closed, bytesUp: 12, bytesDown: 34,
            openedAt: openedAt
        ))])
    }

    @Test("connectionEvent carries processDisplayName through to the Core entry, nil when absent")
    func connectionEventMapsProcessDisplayName() {
        let named = ConnectionEventDTO(
            id: "c4", processID: ProcessIdentifierDTO("a.out"), targetHost: "h", targetPort: 80,
            rule: .proxied, proxyKind: .socks5, phase: .opened, bytesUp: 0, bytesDown: 0,
            processDisplayName: "xray"
        )
        guard case .connectionEventReceived(let namedEntry) = ExtensionMessageHandling.actions(for: .connectionEvent(named)).first else {
            Issue.record("expected connectionEventReceived"); return
        }
        #expect(namedEntry.processDisplayName == "xray")

        let unnamed = ConnectionEventDTO(
            id: "c5", processID: ProcessIdentifierDTO("com.x"), targetHost: "h", targetPort: 80,
            rule: .direct, proxyKind: nil, phase: .opened, bytesUp: 0, bytesDown: 0
        )
        guard case .connectionEventReceived(let unnamedEntry) = ExtensionMessageHandling.actions(for: .connectionEvent(unnamed)).first else {
            Issue.record("expected connectionEventReceived"); return
        }
        #expect(unnamedEntry.processDisplayName == nil)
    }

    @Test("loopDetected maps to a loopWarningRaised action carrying the signature")
    func loopDetectedMapsToWarning() {
        let actions = ExtensionMessageHandling.actions(for: .loopDetected(
            signature: "10.0.0.1:1080", processID: ProcessIdentifierDTO("a.out"), executablePath: "/opt/xray"
        ))
        #expect(actions == [.loopWarningRaised(
            signature: "10.0.0.1:1080", processID: Core.ProcessID("a.out"), executablePath: "/opt/xray"
        )])
    }

    @Test("a blocked connection event maps rule .block through to Core (proxyKind nil)")
    func connectionEventBlockedMapsRule() {
        let dto = ConnectionEventDTO(
            id: "c3", processID: ProcessIdentifierDTO("com.ads"), targetHost: "ads.example.com", targetPort: 443,
            rule: .block, proxyKind: nil, phase: .closed, bytesUp: 0, bytesDown: 0
        )
        let actions = ExtensionMessageHandling.actions(for: .connectionEvent(dto))
        guard case .connectionEventReceived(let entry) = actions.first else {
            Issue.record("expected connectionEventReceived"); return
        }
        #expect(entry.rule == .block)
        #expect(entry.proxyKind == nil)
    }

    @Test("a direct connection event maps proxyKind nil")
    func connectionEventDirectNilKind() {
        let dto = ConnectionEventDTO(
            id: "c2", processID: ProcessIdentifierDTO("p"), targetHost: "h", targetPort: 80,
            rule: .direct, proxyKind: nil, phase: .opened, bytesUp: 0, bytesDown: 0
        )
        let actions = ExtensionMessageHandling.actions(for: .connectionEvent(dto))
        guard case .connectionEventReceived(let entry) = actions.first else {
            Issue.record("expected connectionEventReceived"); return
        }
        #expect(entry.proxyKind == nil)
        #expect(entry.rule == .direct)
        #expect(entry.phase == .opened)
    }

    @Test(
        "connection phase maps 1:1 across all cases",
        arguments: [
            (ConnectionPhaseDTO.opened, Core.ConnectionPhase.opened),
            (ConnectionPhaseDTO.closed, Core.ConnectionPhase.closed),
            (ConnectionPhaseDTO.failed, Core.ConnectionPhase.failed)
        ]
    )
    func phaseMapping(dto: ConnectionPhaseDTO, core: Core.ConnectionPhase) {
        let event = ConnectionEventDTO(
            id: "c", processID: ProcessIdentifierDTO("p"), targetHost: "h", targetPort: 1,
            rule: .direct, proxyKind: nil, phase: dto, bytesUp: 0, bytesDown: 0
        )
        guard case .connectionEventReceived(let entry) = ExtensionMessageHandling.actions(for: .connectionEvent(event)).first else {
            Issue.record("expected connectionEventReceived"); return
        }
        #expect(entry.phase == core)
    }

    @Test(
        "diagnosticRequestMessage kind mapping is exhaustive and 1:1, the reverse of the incoming mapping",
        arguments: [
            (Core.DiagnosticKind.ruleHit, DiagnosticKindDTO.ruleHit),
            (Core.DiagnosticKind.actuallyProxied, DiagnosticKindDTO.actuallyProxied),
            (Core.DiagnosticKind.upstreamReachable, DiagnosticKindDTO.upstreamReachable),
            (Core.DiagnosticKind.dnsResolution, DiagnosticKindDTO.dnsResolution),
            (Core.DiagnosticKind.udpIPv6QuicLeak, DiagnosticKindDTO.udpIPv6QuicLeak),
            (Core.DiagnosticKind.envConflict, DiagnosticKindDTO.envConflict)
        ]
    )
    func diagnosticRequestKindMappingIsExhaustive(coreKind: Core.DiagnosticKind, expectedDTO: DiagnosticKindDTO) {
        let message = ExtensionMessageHandling.diagnosticRequestMessage(
            processID: Core.ProcessID("p"), kinds: [coreKind]
        )
        #expect(message == .requestDiagnostic(
            DiagnosticRequestDTO(processID: ProcessIdentifierDTO("p"), kinds: [expectedDTO])
        ))
    }

    @Test("diagnosticRequestMessage preserves kind order and processID")
    func diagnosticRequestMessagePreservesOrderAndProcessID() {
        let message = ExtensionMessageHandling.diagnosticRequestMessage(
            processID: Core.ProcessID("proc-42"),
            kinds: [.dnsResolution, .ruleHit, .envConflict]
        )
        #expect(message == .requestDiagnostic(
            DiagnosticRequestDTO(
                processID: ProcessIdentifierDTO("proc-42"),
                kinds: [.dnsResolution, .ruleHit, .envConflict]
            )
        ))
    }
}
