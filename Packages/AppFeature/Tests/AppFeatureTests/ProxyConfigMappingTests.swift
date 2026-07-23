import Testing
import Core
import IPCContract
@testable import AppFeature

@Suite("ProxyConfigMapping — pure translation from Core proxy state to IPCContract wire message")
struct ProxyConfigMappingTests {

    @Test("empty server list produces applyProxyConfig with no servers and nil active id")
    func emptyServers() {
        let message = ProxyConfigMapping.proxyConfigMessage(servers: [], activeID: nil)
        #expect(message == .applyProxyConfig(ProxyConfigMessage(servers: [], activeServerID: nil)))
    }

    @Test("a server without credentials maps host/port/kind, leaving username/password nil")
    func serverWithoutCredentials() {
        let server = Core.ProxyServer(
            id: Core.ProxyServerID("s1"), host: "127.0.0.1", port: 1080, kind: .socks5
        )
        let message = ProxyConfigMapping.proxyConfigMessage(servers: [server], activeID: nil)

        #expect(message == .applyProxyConfig(ProxyConfigMessage(
            servers: [ProxyServerDTO(id: "s1", host: "127.0.0.1", port: 1080, kind: .socks5)],
            activeServerID: nil
        )))
    }

    @Test("a server with credentials carries username and password onto the DTO")
    func serverWithCredentials() {
        let server = Core.ProxyServer(
            id: Core.ProxyServerID("s2"), host: "proxy.example", port: 8443, kind: .socks5,
            username: "alice", password: "hunter2"
        )
        let message = ProxyConfigMapping.proxyConfigMessage(servers: [server], activeID: nil)

        #expect(message == .applyProxyConfig(ProxyConfigMessage(
            servers: [ProxyServerDTO(
                id: "s2", host: "proxy.example", port: 8443, kind: .socks5,
                username: "alice", password: "hunter2"
            )],
            activeServerID: nil
        )))
    }

    @Test("multiple servers preserve order and the active id is passed through unchanged")
    func multipleServersPreserveOrderAndActiveID() {
        let first = Core.ProxyServer(id: Core.ProxyServerID("a"), host: "10.0.0.1", port: 1080)
        let second = Core.ProxyServer(id: Core.ProxyServerID("b"), host: "10.0.0.2", port: 1081)
        let message = ProxyConfigMapping.proxyConfigMessage(
            servers: [first, second], activeID: Core.ProxyServerID("b")
        )

        #expect(message == .applyProxyConfig(ProxyConfigMessage(
            servers: [
                ProxyServerDTO(id: "a", host: "10.0.0.1", port: 1080, kind: .socks5),
                ProxyServerDTO(id: "b", host: "10.0.0.2", port: 1081, kind: .socks5)
            ],
            activeServerID: "b"
        )))
    }

    @Test(
        "routingModeMessage maps every Core.ProxyRoutingMode into applyRoutingMode",
        arguments: [
            (Core.ProxyRoutingMode.single, ProxyRoutingModeDTO.single),
            (Core.ProxyRoutingMode.chain([Core.ProxyServerID("a"), Core.ProxyServerID("b")]), ProxyRoutingModeDTO.chain(["a", "b"])),
            (Core.ProxyRoutingMode.failover([Core.ProxyServerID("a")]), ProxyRoutingModeDTO.failover(["a"])),
            (Core.ProxyRoutingMode.loadBalance([Core.ProxyServerID("x"), Core.ProxyServerID("y")]), ProxyRoutingModeDTO.loadBalance(["x", "y"]))
        ]
    )
    func routingModeMapping(core: Core.ProxyRoutingMode, dto: ProxyRoutingModeDTO) {
        #expect(ProxyConfigMapping.routingModeMessage(core) == .applyRoutingMode(dto))
    }

    @Test("packetCaptureMessage maps the bool into setPacketCapture", arguments: [true, false])
    func packetCaptureMapping(enabled: Bool) {
        #expect(ProxyConfigMapping.packetCaptureMessage(enabled) == .setPacketCapture(enabled))
    }

    @Test(
        "udpPolicyMessage maps every Core.UDPPolicy into setUDPPolicy",
        arguments: [
            (Core.UDPPolicy.block, UDPPolicyDTO.block),
            (Core.UDPPolicy.direct, UDPPolicyDTO.direct),
            (Core.UDPPolicy.proxySOCKS5, UDPPolicyDTO.proxySOCKS5)
        ]
    )
    func udpPolicyMapping(core: Core.UDPPolicy, dto: UDPPolicyDTO) {
        #expect(ProxyConfigMapping.udpPolicyMessage(core) == .setUDPPolicy(dto))
    }

    @Test("processOriginExclusionsMessage maps identifiers + executablePaths into applyProcessOriginExclusions (order-independent)")
    func processOriginExclusionsMapping() {
        let discovery = Core.OriginExclusionDiscovery(
            identifiers: ["com.example.xray", "com.example.v2ray"],
            executablePaths: ["/usr/local/bin/xray"]
        )
        let message = ProxyConfigMapping.processOriginExclusionsMessage(
            direct: discovery,
            hardBypass: Core.OriginExclusionDiscovery(executablePaths: ["/opt/loop"]),
            hostAppBundlePath: "/Applications/appidge.app"
        )
        guard case .applyProcessOriginExclusions(let payload) = message else {
            Issue.record("expected applyProcessOriginExclusions envelope")
            return
        }
        #expect(Set(payload.identifiers) == ["com.example.xray", "com.example.v2ray"])
        #expect(Set(payload.executablePaths) == ["/usr/local/bin/xray"])
        #expect(Set(payload.hardBypassExecutablePaths) == ["/opt/loop"])
        #expect(payload.hostAppBundlePath == "/Applications/appidge.app")
    }

    @Test("processOriginExclusionsMessage on an empty discovery maps to empty lists")
    func processOriginExclusionsMappingEmpty() {
        let message = ProxyConfigMapping.processOriginExclusionsMessage(direct: Core.OriginExclusionDiscovery(), hardBypass: Core.OriginExclusionDiscovery())
        #expect(message == .applyProcessOriginExclusions(ProcessOriginExclusionMessage(identifiers: [], executablePaths: [])))
    }

    @Test(
        "ProxyKind maps 1:1 to ProxyKindDTO across all cases",
        arguments: [
            (Core.ProxyKind.socks5, ProxyKindDTO.socks5),
            (Core.ProxyKind.httpConnect, ProxyKindDTO.httpConnect)
        ]
    )
    func kindMapping(coreKind: Core.ProxyKind, expectedDTO: ProxyKindDTO) {
        let server = Core.ProxyServer(id: Core.ProxyServerID("k"), host: "h", port: 1, kind: coreKind)
        let message = ProxyConfigMapping.proxyConfigMessage(servers: [server], activeID: nil)

        guard case .applyProxyConfig(let config) = message else {
            Issue.record("expected applyProxyConfig envelope")
            return
        }
        #expect(config.servers.first?.kind == expectedDTO)
    }
}
