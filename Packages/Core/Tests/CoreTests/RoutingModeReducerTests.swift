import Testing
@testable import Core

@Suite("Reducer — proxy routing mode")
struct RoutingModeReducerTests {

    @Test("default routing mode is single")
    func defaultsToSingle() {
        #expect(AppState().proxyRoutingMode == .single)
    }

    @Test("setProxyRoutingMode stores it and emits an applyRoutingMode effect")
    func setMode() {
        let mode = ProxyRoutingMode.chain([ProxyServerID("a"), ProxyServerID("b")])
        let (next, effects) = Reducer.reduce(AppState(), .setProxyRoutingMode(mode))
        #expect(next.proxyRoutingMode == mode)
        #expect(effects == [.applyRoutingMode(mode)])
    }

    @Test("switching between modes replaces the mode and re-pushes")
    func switchModes() {
        var (state, _) = Reducer.reduce(AppState(), .setProxyRoutingMode(.failover([ProxyServerID("a")])))
        let (next, effects) = Reducer.reduce(state, .setProxyRoutingMode(.loadBalance([ProxyServerID("a"), ProxyServerID("b")])))
        #expect(next.proxyRoutingMode == .loadBalance([ProxyServerID("a"), ProxyServerID("b")]))
        #expect(effects == [.applyRoutingMode(.loadBalance([ProxyServerID("a"), ProxyServerID("b")]))])
    }

    @Test("setting back to single re-pushes single")
    func backToSingle() {
        var (state, _) = Reducer.reduce(AppState(), .setProxyRoutingMode(.chain([ProxyServerID("a")])))
        let (next, effects) = Reducer.reduce(state, .setProxyRoutingMode(.single))
        #expect(next.proxyRoutingMode == .single)
        #expect(effects == [.applyRoutingMode(.single)])
    }
}
