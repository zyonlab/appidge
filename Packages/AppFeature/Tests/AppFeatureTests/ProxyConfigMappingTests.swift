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
