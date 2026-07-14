import Testing
import IPCContract
@testable import EngineKit

/// 路由解析是 openRemote 之前唯一的决策点：把"用户选的模式 + 当前下发的上游清单"
/// 压成一条扩展能直接执行的 `ResolvedRoute`。这里穷举它的降级契约（认不得的 id 丢掉、
/// 解析空了回落到 active、再没 active 就直连），扩展现场就不必再处理这些边角。
@Suite("ProxyRouteResolver — mode + servers → one executable route, with fallbacks")
struct ProxyRouteResolverTests {

    private func server(_ id: String, _ host: String = "h", _ port: UInt16 = 1080) -> ProxyServerDTO {
        ProxyServerDTO(id: id, host: host, port: port, kind: .socks5)
    }

    // MARK: single

    @Test("single mode with a resolvable active id → single(active)")
    func singleWithActive() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(mode: .single, servers: [a, server("b")], activeServerID: "a")
        #expect(route == .single(a))
    }

    @Test("single mode with nil active → direct")
    func singleNilActive() {
        let route = ProxyRouteResolver.resolve(mode: .single, servers: [server("a")], activeServerID: nil)
        #expect(route == .direct)
    }

    @Test("single mode whose active id is not among the servers → direct")
    func singleUnknownActive() {
        let route = ProxyRouteResolver.resolve(mode: .single, servers: [server("a")], activeServerID: "ghost")
        #expect(route == .direct)
    }

    // MARK: chain

    @Test("chain resolves ids in the given order, not the servers' order")
    func chainPreservesGivenOrder() {
        let a = server("a"), b = server("b"), c = server("c")
        let route = ProxyRouteResolver.resolve(
            mode: .chain(["c", "a"]), servers: [a, b, c], activeServerID: "b"
        )
        #expect(route == .chain([c, a]))
    }

    @Test("chain drops ids that don't resolve, keeping the rest in order")
    func chainDropsUnknownIDs() {
        let a = server("a"), b = server("b")
        let route = ProxyRouteResolver.resolve(
            mode: .chain(["a", "ghost", "b"]), servers: [a, b], activeServerID: nil
        )
        #expect(route == .chain([a, b]))
    }

    @Test("a chain that resolves to exactly one proxy collapses to single(that proxy)")
    func chainOfOneCollapsesToSingle() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(
            mode: .chain(["a", "ghost"]), servers: [a], activeServerID: nil
        )
        #expect(route == .single(a))
    }

    @Test("a chain whose ids all fail to resolve falls back to the single active server")
    func chainEmptyFallsBackToActive() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(
            mode: .chain(["x", "y"]), servers: [a], activeServerID: "a"
        )
        #expect(route == .single(a))
    }

    @Test("a chain that resolves to nothing with no active server → direct")
    func chainEmptyNoActiveIsDirect() {
        let route = ProxyRouteResolver.resolve(
            mode: .chain(["x"]), servers: [server("a")], activeServerID: nil
        )
        #expect(route == .direct)
    }

    // MARK: failover

    @Test("failover keeps every resolvable proxy, in order")
    func failoverInOrder() {
        let a = server("a"), b = server("b")
        let route = ProxyRouteResolver.resolve(
            mode: .failover(["b", "a"]), servers: [a, b], activeServerID: nil
        )
        #expect(route == .failover([b, a]))
    }

    @Test("failover drops unknown ids")
    func failoverDropsUnknown() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(
            mode: .failover(["a", "ghost"]), servers: [a], activeServerID: nil
        )
        #expect(route == .failover([a]))
    }

    @Test("a single-element failover stays failover (not collapsed) so the candidate set is faithful")
    func failoverOfOneStaysFailover() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(mode: .failover(["a"]), servers: [a], activeServerID: nil)
        #expect(route == .failover([a]))
    }

    @Test("an empty failover list falls back to the single active server")
    func failoverEmptyFallsBackToActive() {
        let a = server("a")
        let route = ProxyRouteResolver.resolve(mode: .failover([]), servers: [a], activeServerID: "a")
        #expect(route == .single(a))
    }

    // MARK: loadBalance

    @Test("loadBalance keeps every resolvable proxy, in order")
    func loadBalanceInOrder() {
        let a = server("a"), b = server("b")
        let route = ProxyRouteResolver.resolve(
            mode: .loadBalance(["a", "b"]), servers: [a, b], activeServerID: nil
        )
        #expect(route == .loadBalance([a, b]))
    }

    @Test("loadBalance drops unknown ids")
    func loadBalanceDropsUnknown() {
        let b = server("b")
        let route = ProxyRouteResolver.resolve(
            mode: .loadBalance(["ghost", "b"]), servers: [b], activeServerID: nil
        )
        #expect(route == .loadBalance([b]))
    }

    @Test("an empty loadBalance list with no active server → direct")
    func loadBalanceEmptyNoActiveIsDirect() {
        let route = ProxyRouteResolver.resolve(mode: .loadBalance([]), servers: [server("a")], activeServerID: nil)
        #expect(route == .direct)
    }
}
