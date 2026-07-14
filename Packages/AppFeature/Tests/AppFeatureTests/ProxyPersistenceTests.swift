import Testing
import Foundation
import Core
@testable import AppFeature

@Suite("Proxy persistence — password-stripped disk storage + restorationActions")
struct ProxyPersistenceTests {

    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config.json")
    }

    @Test("PersistedConfiguration(from:) includes proxy servers (password stripped) and the active id")
    func conversionIncludesProxyServersWithoutPassword() {
        let id = ProxyServerID("s")
        var state = AppState()
        state.proxyServers[id] = ProxyServer(
            id: id, host: "proxy.example", port: 8443, kind: .socks5, username: "alice", password: "secret"
        )
        state.activeProxyServerID = id

        let config = PersistedConfiguration(from: state)

        #expect(config.proxyServers == [
            PersistedProxyServer(id: "s", host: "proxy.example", port: 8443, kind: .socks5, username: "alice")
        ])
        #expect(config.activeProxyServerID == "s")
    }

    @Test("PersistedConfiguration(from:) sorts proxy servers deterministically by id")
    func conversionSortsProxyServersById() {
        var state = AppState()
        state.proxyServers[ProxyServerID("b")] = ProxyServer(id: ProxyServerID("b"), host: "hb", port: 2)
        state.proxyServers[ProxyServerID("a")] = ProxyServer(id: ProxyServerID("a"), host: "ha", port: 1)

        let config = PersistedConfiguration(from: state)

        #expect(config.proxyServers.map(\.id) == ["a", "b"])
    }

    @Test("encoded on-disk JSON never contains the plaintext password")
    func encodedJSONHasNoPlaintextPassword() throws {
        let id = ProxyServerID("s")
        var state = AppState()
        state.proxyServers[id] = ProxyServer(
            id: id, host: "h", port: 1080, kind: .socks5, username: "u", password: "hunter2"
        )
        state.activeProxyServerID = id

        let config = PersistedConfiguration(from: state)
        let data = try JSONEncoder().encode(config)

        // Assert against the raw encoded bytes: neither the plaintext value nor a
        // "password" JSON key may appear anywhere in the persisted representation.
        #expect(data.range(of: Data("hunter2".utf8)) == nil)
        #expect(data.range(of: Data("password".utf8)) == nil)
    }

    @Test("FilePersistenceStore round-trip: password is dropped, host/port/username/kind survive")
    func fileStoreRoundTripDropsPassword() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = ProxyServerID("s")
        var state = AppState()
        state.proxyServers[id] = ProxyServer(
            id: id, host: "proxy.example", port: 8443, kind: .socks5, username: "alice", password: "hunter2"
        )
        state.activeProxyServerID = id

        let writer = FilePersistenceStore(fileURL: url)
        await writer.save(PersistedConfiguration(from: state))

        // The raw bytes on disk must not carry the plaintext password.
        let rawData = try Data(contentsOf: url)
        #expect(rawData.range(of: Data("hunter2".utf8)) == nil)

        // A fresh instance proves it survived across store instances (i.e. relaunches).
        let reader = FilePersistenceStore(fileURL: url)
        let loaded = await reader.load()

        let restored = loaded?.proxyServers.first?.toProxyServer()
        #expect(restored?.password == nil)
        #expect(restored?.host == "proxy.example")
        #expect(restored?.port == 8443)
        #expect(restored?.username == "alice")
        #expect(restored?.kind == .socks5)
        #expect(loaded?.activeProxyServerID == "s")
    }

    @Test("restorationActions emits addProxyServer per server (id-sorted) then a trailing setActiveProxyServer")
    func restorationEmitsAddThenSetActive() {
        let config = PersistedConfiguration(
            proxyServers: [
                PersistedProxyServer(id: "a", host: "10.0.0.1", port: 1080, kind: .socks5, username: nil),
                PersistedProxyServer(id: "b", host: "10.0.0.2", port: 1081, kind: .socks5, username: "u")
            ],
            activeProxyServerID: "b"
        )

        #expect(config.restorationActions() == [
            .addProxyServer(ProxyServer(id: ProxyServerID("a"), host: "10.0.0.1", port: 1080, kind: .socks5)),
            .addProxyServer(
                ProxyServer(id: ProxyServerID("b"), host: "10.0.0.2", port: 1081, kind: .socks5, username: "u")
            ),
            .setActiveProxyServer(ProxyServerID("b"))
        ])
    }

    @Test("restorationActions with a nil active id still emits setActiveProxyServer(nil) to undo reducer auto-select")
    func restorationClearsAutoSelectedActive() {
        let config = PersistedConfiguration(
            proxyServers: [PersistedProxyServer(id: "a", host: "h", port: 1, kind: .socks5, username: nil)],
            activeProxyServerID: nil
        )

        let actions = config.restorationActions()
        #expect(actions == [
            .addProxyServer(ProxyServer(id: ProxyServerID("a"), host: "h", port: 1, kind: .socks5)),
            .setActiveProxyServer(nil)
        ])

        var state = AppState()
        for action in actions {
            state = Reducer.reduce(state, action).0
        }
        // Reducer auto-selects the first added server; restoration must faithfully clear it back to nil.
        #expect(state.activeProxyServerID == nil)
    }

    @Test("replaying restorationActions through the real reducer reconstructs the servers and active selection")
    func replayReconstructsServersAndActive() {
        let config = PersistedConfiguration(
            proxyServers: [
                PersistedProxyServer(id: "a", host: "10.0.0.1", port: 1080, kind: .socks5, username: nil),
                PersistedProxyServer(id: "b", host: "10.0.0.2", port: 1081, kind: .socks5, username: "u")
            ],
            activeProxyServerID: "b"
        )

        var state = AppState()
        for action in config.restorationActions() {
            state = Reducer.reduce(state, action).0
        }

        #expect(state.proxyServers.count == 2)
        #expect(state.proxyServers[ProxyServerID("a")]?.host == "10.0.0.1")
        #expect(state.proxyServers[ProxyServerID("a")]?.password == nil)
        #expect(state.proxyServers[ProxyServerID("b")]?.username == "u")
        #expect(state.activeProxyServerID == ProxyServerID("b"))
    }

    @Test("no proxy servers means no proxy actions in restoration")
    func noProxyServersEmitsNoProxyActions() {
        let config = PersistedConfiguration()
        let actions = config.restorationActions()
        for action in actions {
            switch action {
            case .addProxyServer, .setActiveProxyServer:
                Issue.record("unexpected proxy action for a config with no proxy servers")
            default:
                break
            }
        }
    }

    @Test("a non-default routing mode is captured from state and restored")
    func routingModePersistsAndRestores() {
        var state = Core.AppState()
        state.proxyRoutingMode = .chain([Core.ProxyServerID("a"), Core.ProxyServerID("b")])
        let config = PersistedConfiguration(from: state)
        #expect(config.proxyRoutingMode == .chain([Core.ProxyServerID("a"), Core.ProxyServerID("b")]))
        #expect(config.restorationActions().contains(.setProxyRoutingMode(.chain([Core.ProxyServerID("a"), Core.ProxyServerID("b")]))))
    }

    @Test("the default single routing mode is not re-emitted on restore")
    func defaultModeNotRestored() {
        let config = PersistedConfiguration() // .single by default
        for action in config.restorationActions() {
            if case .setProxyRoutingMode = action { Issue.record("should not emit setProxyRoutingMode for default single") }
        }
    }
}
