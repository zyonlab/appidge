import Testing
@testable import Core

@Suite("Reducer — proxy server configuration")
struct ProxyServerReducerTests {

    private func makeServer(_ id: String, host: String = "127.0.0.1", port: UInt16 = 1080) -> ProxyServer {
        ProxyServer(id: ProxyServerID(id), host: host, port: port, kind: .socks5)
    }

    /// 期望的"把当前完整代理配置推给扩展"effect：servers 按 id 排序（确定），active 原样。
    private func configEffect(_ servers: [ProxyServer], active: ProxyServerID?) -> Effect {
        .applyProxyConfig(servers: servers.sorted { $0.id.value < $1.id.value }, activeID: active)
    }

    @Test("addProxyServer inserts by id and emits a config-push effect with the new config")
    func addProxyServer() {
        let server = makeServer("a")
        let (next, effects) = Reducer.reduce(AppState(), .addProxyServer(server))
        #expect(next.proxyServers[ProxyServerID("a")] == server)
        #expect(effects == [configEffect([server], active: ProxyServerID("a"))])
    }

    @Test("adding the first proxy server auto-selects it as active")
    func firstAddedBecomesActive() {
        let server = makeServer("a")
        let (next, _) = Reducer.reduce(AppState(), .addProxyServer(server))
        #expect(next.activeProxyServerID == ProxyServerID("a"))
    }

    @Test("adding a second proxy server does not steal active from the first")
    func secondAddedDoesNotStealActive() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        (state, _) = Reducer.reduce(state, .addProxyServer(makeServer("b")))
        #expect(state.activeProxyServerID == ProxyServerID("a"))
        #expect(state.proxyServers.count == 2)
    }

    @Test("updateProxyServer replaces an existing server by id, leaves others untouched")
    func updateProxyServer() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a", host: "10.0.0.1")))
        (state, _) = Reducer.reduce(state, .addProxyServer(makeServer("b", host: "10.0.0.2")))
        let bBefore = state.proxyServers[ProxyServerID("b")]

        let updated = ProxyServer(id: ProxyServerID("a"), host: "10.0.0.9", port: 9050, kind: .socks5)
        let (next, effects) = Reducer.reduce(state, .updateProxyServer(updated))
        #expect(next.proxyServers[ProxyServerID("a")]?.host == "10.0.0.9")
        #expect(next.proxyServers[ProxyServerID("a")]?.port == 9050)
        #expect(next.proxyServers[ProxyServerID("b")] == bBefore)
        #expect(effects == [configEffect([updated, next.proxyServers[ProxyServerID("b")]!], active: ProxyServerID("a"))])
    }

    @Test("updateProxyServer for an unknown id is a no-op, no insert, no effect")
    func updateUnknownIsNoOp() {
        let (next, effects) = Reducer.reduce(AppState(), .updateProxyServer(makeServer("ghost")))
        #expect(next.proxyServers.isEmpty)
        #expect(effects.isEmpty)
    }

    @Test("removeProxyServer drops it and clears active if it was the active one")
    func removeActiveClearsActive() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        (state, _) = Reducer.reduce(state, .removeProxyServer(ProxyServerID("a")))
        #expect(state.proxyServers.isEmpty)
        #expect(state.activeProxyServerID == nil)
    }

    @Test("removing a non-active server leaves active intact")
    func removeNonActiveKeepsActive() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        (state, _) = Reducer.reduce(state, .addProxyServer(makeServer("b")))
        (state, _) = Reducer.reduce(state, .removeProxyServer(ProxyServerID("b")))
        #expect(state.activeProxyServerID == ProxyServerID("a"))
        #expect(state.proxyServers[ProxyServerID("a")] != nil)
    }

    @Test("setActiveProxyServer to a known id sets it")
    func setActiveKnown() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        (state, _) = Reducer.reduce(state, .addProxyServer(makeServer("b")))
        let (next, effects) = Reducer.reduce(state, .setActiveProxyServer(ProxyServerID("b")))
        #expect(next.activeProxyServerID == ProxyServerID("b"))
        #expect(effects == [configEffect(Array(next.proxyServers.values), active: ProxyServerID("b"))])
    }

    @Test("setActiveProxyServer to nil clears the active selection")
    func setActiveNil() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        #expect(state.activeProxyServerID == ProxyServerID("a"))
        (state, _) = Reducer.reduce(state, .setActiveProxyServer(nil))
        #expect(state.activeProxyServerID == nil)
    }

    @Test("setActiveProxyServer to an unknown id is rejected, keeps prior active, no effect")
    func setActiveUnknownRejected() {
        let (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        let (next, effects) = Reducer.reduce(state, .setActiveProxyServer(ProxyServerID("nope")))
        #expect(next.activeProxyServerID == ProxyServerID("a"))
        #expect(effects.isEmpty)
    }

    @Test("removeProxyServer emits the config-push effect reflecting the removal")
    func removeEmitsConfigPush() {
        var (state, _) = Reducer.reduce(AppState(), .addProxyServer(makeServer("a")))
        (state, _) = Reducer.reduce(state, .addProxyServer(makeServer("b")))
        let (next, effects) = Reducer.reduce(state, .removeProxyServer(ProxyServerID("b")))
        #expect(effects == [configEffect(Array(next.proxyServers.values), active: ProxyServerID("a"))])
    }

    @Test("removeProxyServer for an unknown id is a no-op, no effect")
    func removeUnknownIsNoOp() {
        let (next, effects) = Reducer.reduce(AppState(), .removeProxyServer(ProxyServerID("ghost")))
        #expect(next.proxyServers.isEmpty)
        #expect(effects.isEmpty)
    }

    @Test("proxy server carries optional username/password for authenticated SOCKS5")
    func serverCarriesCredentials() {
        let server = ProxyServer(
            id: ProxyServerID("auth"), host: "10.0.0.1", port: 1080, kind: .socks5,
            username: "user", password: "secret"
        )
        let (next, _) = Reducer.reduce(AppState(), .addProxyServer(server))
        #expect(next.proxyServers[ProxyServerID("auth")]?.username == "user")
        #expect(next.proxyServers[ProxyServerID("auth")]?.password == "secret")
    }
}
