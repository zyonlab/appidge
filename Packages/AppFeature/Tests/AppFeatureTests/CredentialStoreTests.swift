import Testing
import Foundation
import Core
@testable import AppFeature

@Suite("CredentialStore — passwords live in the store, never in the on-disk config")
struct CredentialStoreTests {

    @Test("save then read a password by id; unknown id reads nil")
    func saveRead() async {
        let store = InMemoryCredentialStore()
        await store.savePassword("hunter2", for: Core.ProxyServerID("a"))
        #expect(await store.password(for: Core.ProxyServerID("a")) == "hunter2")
        #expect(await store.password(for: Core.ProxyServerID("unknown")) == nil)
    }

    @Test("saving nil deletes any stored password")
    func saveNilDeletes() async {
        let store = InMemoryCredentialStore()
        await store.savePassword("x", for: Core.ProxyServerID("a"))
        await store.savePassword(nil, for: Core.ProxyServerID("a"))
        #expect(await store.password(for: Core.ProxyServerID("a")) == nil)
    }

    @Test("deletePassword removes it")
    func deletePassword() async {
        let store = InMemoryCredentialStore()
        await store.savePassword("x", for: Core.ProxyServerID("a"))
        await store.deletePassword(for: Core.ProxyServerID("a"))
        #expect(await store.password(for: Core.ProxyServerID("a")) == nil)
    }

    @Test("saveCredentials(from:) stores each server's password; a nil-password server stores nothing")
    func saveCredentialsFromServers() async {
        let store = InMemoryCredentialStore()
        let withPw = Core.ProxyServer(id: Core.ProxyServerID("a"), host: "h", port: 1, username: "u", password: "secret")
        let noPw = Core.ProxyServer(id: Core.ProxyServerID("b"), host: "h", port: 2)
        await PersistedConfiguration.saveCredentials(from: [withPw, noPw], to: store)

        #expect(await store.password(for: Core.ProxyServerID("a")) == "secret")
        #expect(await store.password(for: Core.ProxyServerID("b")) == nil)
    }

    @Test("saveCredentials deletes a previously stored password when the server no longer has one")
    func saveCredentialsDeletesStale() async {
        let store = InMemoryCredentialStore()
        await store.savePassword("old", for: Core.ProxyServerID("a"))
        let noPw = Core.ProxyServer(id: Core.ProxyServerID("a"), host: "h", port: 1, username: "u", password: nil)
        await PersistedConfiguration.saveCredentials(from: [noPw], to: store)
        #expect(await store.password(for: Core.ProxyServerID("a")) == nil)
    }

    @Test("restorationActions(rehydrating:) fills passwords from the store; ordering matches the sync variant")
    func restorationRehydrates() async {
        let config = PersistedConfiguration(
            proxyServers: [
                PersistedProxyServer(id: "a", host: "h1", port: 1, kind: .socks5, username: "u1"),
                PersistedProxyServer(id: "b", host: "h2", port: 2, kind: .socks5, username: nil)
            ],
            activeProxyServerID: "a"
        )
        let store = InMemoryCredentialStore()
        await store.savePassword("pw-a", for: Core.ProxyServerID("a")) // only 'a' has a stored credential

        let actions = await config.restorationActions(rehydratingCredentialsFrom: store)

        // same shape/order as the synchronous variant, only passwords differ
        let syncKinds = config.restorationActions().map(actionTag)
        #expect(actions.map(actionTag) == syncKinds)

        var restoredPasswords: [String: String?] = [:]
        for action in actions {
            if case .addProxyServer(let server) = action {
                restoredPasswords[server.id.value] = server.password
            }
        }
        #expect(restoredPasswords["a"] == "pw-a")
        #expect(restoredPasswords["b"] == .some(nil))
    }

    @Test("the credential-rehydrating restore path (the one the app actually runs) still emits the routing mode")
    func rehydratingPreservesRoutingMode() async {
        var state = Core.AppState()
        state.proxyServers[Core.ProxyServerID("a")] = Core.ProxyServer(id: Core.ProxyServerID("a"), host: "h", port: 1)
        state.proxyServers[Core.ProxyServerID("b")] = Core.ProxyServer(id: Core.ProxyServerID("b"), host: "h", port: 2)
        state.proxyRoutingMode = .failover([Core.ProxyServerID("a"), Core.ProxyServerID("b")])
        let config = PersistedConfiguration(from: state)

        let actions = await config.restorationActions(rehydratingCredentialsFrom: InMemoryCredentialStore())

        #expect(actions.contains(.setProxyRoutingMode(.failover([Core.ProxyServerID("a"), Core.ProxyServerID("b")]))))
    }

    @Test("on-disk config still has no plaintext password even with the credential path in play")
    func diskHasNoPassword() throws {
        let server = Core.ProxyServer(
            id: Core.ProxyServerID("a"), host: "h", port: 1, kind: .socks5, username: "u", password: "TOPSECRET"
        )
        var state = Core.AppState()
        state.proxyServers[server.id] = server
        let config = PersistedConfiguration(from: state)

        let data = try JSONEncoder().encode(config)
        let json = String(bytes: data, encoding: .utf8) ?? ""
        #expect(!json.contains("TOPSECRET"))
        #expect(!json.contains("password"))
    }

    /// 只关心 action 的种类/顺序，不比较 payload（密码不同是预期）。
    private func actionTag(_ action: Core.Action) -> String {
        switch action {
        case .addProxyServer: "addProxyServer"
        case .setActiveProxyServer: "setActiveProxyServer"
        case .directoryScanned: "directoryScanned"
        case .processDiscovered: "processDiscovered"
        case .assignRule: "assignRule"
        case .onboardingCompleted: "onboardingCompleted"
        default: "other"
        }
    }
}
