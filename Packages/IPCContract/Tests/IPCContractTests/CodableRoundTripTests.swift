import Testing
import Foundation
@testable import IPCContract

@Suite("IPCContract Codable round-trip")
struct CodableRoundTripTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("RuleSetMessage round-trips — 规则下发（含细粒度规则表）")
    func ruleSetMessage() throws {
        let message = RuleSetMessage(
            assignments: [
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("com.example.curl"), rule: .proxied),
                RuleAssignmentDTO(processID: ProcessIdentifierDTO("com.example.safari"), rule: .direct)
            ],
            matchRules: [
                MatchRuleDTO(id: "r1", appPattern: "*", hostPattern: "*.corp.net", portRange: 22...22, rule: .direct),
                MatchRuleDTO(id: "r2", appPattern: "com.google.*", hostPattern: "*", portRange: nil, rule: .proxied)
            ]
        )
        #expect(try roundTrip(message) == message)
    }

    @Test("MatchRuleDTO round-trips with and without a port range")
    func matchRuleDTORoundTrip() throws {
        let ranged = MatchRuleDTO(id: "a", appPattern: "*", hostPattern: "*.x", portRange: 80...443, rule: .proxied)
        #expect(try roundTrip(ranged) == ranged)
        let anyPort = MatchRuleDTO(id: "b", appPattern: "*", hostPattern: "*", portRange: nil, rule: .direct)
        #expect(try roundTrip(anyPort) == anyPort)
        let blocked = MatchRuleDTO(id: "c", appPattern: "*", hostPattern: "ads.*", portRange: nil, rule: .block)
        #expect(try roundTrip(blocked) == blocked)
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
            RuleSetMessage(assignments: [])
        )
        #expect(try roundTrip(ruleSet) == ruleSet)

        let diagnostic = AppToExtensionMessage.requestDiagnostic(
            DiagnosticRequestDTO(processID: ProcessIdentifierDTO("x"), kinds: [.upstreamReachable])
        )
        #expect(try roundTrip(diagnostic) == diagnostic)

        let routing = AppToExtensionMessage.applyRoutingMode(.chain(["a", "b"]))
        #expect(try roundTrip(routing) == routing)

        let capture = AppToExtensionMessage.setPacketCapture(true)
        #expect(try roundTrip(capture) == capture)

        for policy in [UDPPolicyDTO.block, .direct, .proxySOCKS5] {
            let msg = AppToExtensionMessage.setUDPPolicy(policy)
            #expect(try roundTrip(msg) == msg)
        }
    }

    @Test("ProxyRoutingModeDTO round-trips every case")
    func routingModeRoundTrip() throws {
        for mode: ProxyRoutingModeDTO in [.single, .chain(["a", "b"]), .failover(["a"]), .loadBalance(["a", "b", "c"])] {
            #expect(try roundTrip(mode) == mode)
        }
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

        let loop = ExtensionToAppMessage.loopDetected(
            signature: "10.0.0.1:1080", processID: ProcessIdentifierDTO("a.out"), executablePath: "/usr/local/bin/xray"
        )
        #expect(try roundTrip(loop) == loop)

        let event = ExtensionToAppMessage.connectionEvent(
            ConnectionEventDTO(
                id: "c1", processID: ProcessIdentifierDTO("com.x"), targetHost: "example.com",
                targetPort: 443, rule: .proxied, proxyKind: .socks5, phase: .opened, bytesUp: 0, bytesDown: 0
            )
        )
        #expect(try roundTrip(event) == event)
    }

    @Test("ConnectionEventDTO round-trips across phases, with and without a proxy kind")
    func connectionEventRoundTrip() throws {
        let proxied = ConnectionEventDTO(
            id: "a", processID: ProcessIdentifierDTO("p"), targetHost: "h", targetPort: 80,
            rule: .proxied, proxyKind: .httpConnect, phase: .closed, bytesUp: 123, bytesDown: 456,
            openedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(try roundTrip(proxied) == proxied) // 含 openedAt 时间戳一并 round-trip

        let direct = ConnectionEventDTO(
            id: "b", processID: ProcessIdentifierDTO("p"), targetHost: "h", targetPort: 80,
            rule: .direct, proxyKind: nil, phase: .failed, bytesUp: 0, bytesDown: 0
        )
        #expect(try roundTrip(direct) == direct)
    }

    @Test("ConnectionEventDTO carries an optional processDisplayName, round-trips with and without it")
    func connectionEventProcessDisplayNameRoundTrip() throws {
        let named = ConnectionEventDTO(
            id: "c", processID: ProcessIdentifierDTO("a.out"), targetHost: "h", targetPort: 80,
            rule: .proxied, proxyKind: .socks5, phase: .opened, bytesUp: 0, bytesDown: 0,
            processDisplayName: "xray"
        )
        #expect(try roundTrip(named) == named)
        #expect(named.processDisplayName == "xray")

        let unnamed = ConnectionEventDTO(
            id: "d", processID: ProcessIdentifierDTO("com.example"), targetHost: "h", targetPort: 80,
            rule: .direct, proxyKind: nil, phase: .opened, bytesUp: 0, bytesDown: 0
        )
        #expect(try roundTrip(unnamed) == unnamed)
        #expect(unnamed.processDisplayName == nil)
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

    @Test("ProcessOriginExclusionMessage round-trips, including the empty case — 动态来源排除标识")
    func processOriginExclusionMessageRoundTrip() throws {
        let populated = ProcessOriginExclusionMessage(identifiers: ["com.example.xray", "com.example.v2ray"])
        #expect(try roundTrip(populated) == populated)

        let empty = ProcessOriginExclusionMessage(identifiers: [])
        #expect(try roundTrip(empty) == empty)
    }

    @Test("ProcessOriginExclusionMessage carries executablePaths alongside identifiers — 第二排除信号")
    func processOriginExclusionMessageWithPathsRoundTrip() throws {
        let message = ProcessOriginExclusionMessage(
            identifiers: ["com.example.yunti"],
            executablePaths: ["/usr/local/bin/xray", "/usr/local/bin/xray-helper"],
            hostAppBundlePath: "/Applications/appidge.app"
        )
        #expect(try roundTrip(message) == message)
        #expect(message.executablePaths.count == 2)
        #expect(message.hostAppBundlePath == "/Applications/appidge.app")
    }

    @Test("AppToExtensionMessage.applyProcessOriginExclusions round-trips through the envelope")
    func applyProcessOriginExclusionsEnvelope() throws {
        let message = AppToExtensionMessage.applyProcessOriginExclusions(
            ProcessOriginExclusionMessage(identifiers: ["com.example.xray"])
        )
        #expect(try roundTrip(message) == message)
    }
}
