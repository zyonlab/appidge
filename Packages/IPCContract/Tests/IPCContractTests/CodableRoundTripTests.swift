import Testing
import Foundation
@testable import IPCContract

@Suite("IPCContract Codable round-trip")
struct CodableRoundTripTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("RuleSetMessage round-trips — 规则下发")
    func ruleSetMessage() throws {
        let message = RuleSetMessage(
            assignments: [
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("com.example.curl"), rule: .proxied),
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("com.example.safari"), rule: .direct)
            ],
            globalProxyEnabled: true
        )
        #expect(try roundTrip(message) == message)
    }

    @Test("FlowStatsBatchMessage round-trips — 流量批量上报")
    func flowStatsBatchMessage() throws {
        let now = Date()
        let message = FlowStatsBatchMessage(
            entries: [
                FlowStatsEntryDTO(processID: ProcessIdentifierDTO("a"), bytesUpDelta: 100, bytesDownDelta: 900),
                FlowStatsEntryDTO(processID: ProcessIdentifierDTO("b"), bytesUpDelta: 0, bytesDownDelta: 42)
            ],
            windowStart: now.addingTimeInterval(-0.5),
            windowEnd: now
        )
        #expect(try roundTrip(message) == message)
    }

    @Test("DiagnosticRequestDTO and DiagnosticResultDTO round-trip — 诊断请求/结果")
    func diagnostics() throws {
        let request = DiagnosticRequestDTO(
            processID: ProcessIdentifierDTO("com.example.curl"),
            kinds: [.ruleHit, .dnsResolution, .udpIPv6QuicLeak]
        )
        #expect(try roundTrip(request) == request)

        let result = DiagnosticResultDTO(
            processID: ProcessIdentifierDTO("com.example.curl"),
            kind: .udpIPv6QuicLeak,
            passed: false,
            detail: "QUIC over UDP bypassed the proxy"
        )
        #expect(try roundTrip(result) == result)
    }

    @Test("AppToExtensionMessage envelope round-trips both cases")
    func appToExtensionEnvelope() throws {
        let ruleSet = AppToExtensionMessage.applyRuleSet(
            RuleSetMessage(assignments: [], globalProxyEnabled: false)
        )
        #expect(try roundTrip(ruleSet) == ruleSet)

        let diagnostic = AppToExtensionMessage.requestDiagnostic(
            DiagnosticRequestDTO(processID: ProcessIdentifierDTO("x"), kinds: [.upstreamReachable])
        )
        #expect(try roundTrip(diagnostic) == diagnostic)
    }

    @Test("ExtensionToAppMessage envelope round-trips all cases including engineFailure")
    func extensionToAppEnvelope() throws {
        let batch = ExtensionToAppMessage.flowStatsBatch(
            FlowStatsBatchMessage(entries: [], windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 1))
        )
        #expect(try roundTrip(batch) == batch)

        let diagnostic = ExtensionToAppMessage.diagnosticResult(
            DiagnosticResultDTO(processID: ProcessIdentifierDTO("x"), kind: .envConflict, passed: true, detail: "ok")
        )
        #expect(try roundTrip(diagnostic) == diagnostic)

        let failure = ExtensionToAppMessage.engineFailure(reason: "transport crashed")
        #expect(try roundTrip(failure) == failure)
    }

    @Test("ProxyServerDTO round-trips with and without credentials")
    func proxyServerDTORoundTrip() throws {
        let noAuth = ProxyServerDTO(id: "a", host: "127.0.0.1", port: 1080, kind: .socks5)
        #expect(try roundTrip(noAuth) == noAuth)

        let withAuth = ProxyServerDTO(
            id: "b", host: "10.0.0.1", port: 9050, kind: .socks5, username: "user", password: "secret"
        )
        #expect(try roundTrip(withAuth) == withAuth)
    }

    @Test("ProxyConfigMessage round-trips servers + active selection — 代理配置下发")
    func proxyConfigMessageRoundTrip() throws {
        let message = ProxyConfigMessage(
            servers: [
                ProxyServerDTO(id: "a", host: "127.0.0.1", port: 1080, kind: .socks5),
                ProxyServerDTO(id: "b", host: "10.0.0.1", port: 9050, kind: .socks5, username: "u", password: "p")
            ],
            activeServerID: "a"
        )
        #expect(try roundTrip(message) == message)

        let empty = ProxyConfigMessage(servers: [], activeServerID: nil)
        #expect(try roundTrip(empty) == empty)
    }

    @Test("AppToExtensionMessage.applyProxyConfig round-trips through the envelope")
    func applyProxyConfigEnvelope() throws {
        let message = AppToExtensionMessage.applyProxyConfig(
            ProxyConfigMessage(
                servers: [ProxyServerDTO(id: "a", host: "127.0.0.1", port: 1080, kind: .socks5)],
                activeServerID: "a"
            )
        )
        #expect(try roundTrip(message) == message)
    }
}
