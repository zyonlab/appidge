import Testing
import IPCContract
@testable import EngineKit

@Suite("Proxy strategy primitives — chain / failover / round-robin (injected, no real network)")
struct ProxyStrategyTests {

    private func server(_ id: String, host: String, port: UInt16 = 1080) -> ProxyServerDTO {
        ProxyServerDTO(id: id, host: host, port: port, kind: .socks5)
    }

    // MARK: RoundRobinSelector

    @Test("round-robin cycles 0,1,2,0,1,... over a count")
    func roundRobinCycles() async {
        let selector = RoundRobinSelector()
        var picks: [Int] = []
        for _ in 0..<7 {
            if let pick = await selector.next(count: 3) { picks.append(pick) }
        }
        #expect(picks == [0, 1, 2, 0, 1, 2, 0])
    }

    @Test("round-robin with count 1 always returns 0; count 0 returns nil")
    func roundRobinEdges() async {
        let selector = RoundRobinSelector()
        #expect(await selector.next(count: 1) == 0)
        #expect(await selector.next(count: 1) == 0)
        #expect(await selector.next(count: 0) == nil)
    }

    // MARK: ChainConnector

    @Test("chain sequences hops: each proxy targets the NEXT proxy, the last targets the destination")
    func chainSequencing() async throws {
        let recorder = HopRecorder()
        let chain = [server("p1", host: "10.0.0.1"), server("p2", host: "10.0.0.2")]

        try await ChainConnector.connect(
            proxies: chain, destinationHost: "example.com", destinationPort: 443,
            hop: recorder.hop
        )

        let calls = await recorder.calls
        #expect(calls.count == 2)
        // hop 1: dial p1 fresh (no base), targeting p2's address
        #expect(calls[0].proxyID == "p1")
        #expect(calls[0].targetHost == "10.0.0.2")
        #expect(calls[0].targetPort == 1080)
        #expect(calls[0].hadBase == false)
        // hop 2: over the p1->p2 tunnel (base present), targeting the real destination
        #expect(calls[1].proxyID == "p2")
        #expect(calls[1].targetHost == "example.com")
        #expect(calls[1].targetPort == 443)
        #expect(calls[1].hadBase == true)
    }

    @Test("a single-element chain just targets the destination, no base")
    func chainSingle() async throws {
        let recorder = HopRecorder()
        try await ChainConnector.connect(
            proxies: [server("only", host: "10.0.0.9")], destinationHost: "d", destinationPort: 80, hop: recorder.hop
        )
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].targetHost == "d")
        #expect(calls[0].hadBase == false)
    }

    @Test("an empty chain throws (nothing to connect through)")
    func chainEmpty() async {
        await #expect(throws: ProxyStrategyError.self) {
            try await ChainConnector.connect(proxies: [], destinationHost: "d", destinationPort: 80) { _, _, _, _ in
                MockStream()
            }
        }
    }

    @Test("a hop failure aborts the chain and propagates")
    func chainHopFailure() async {
        let chain = [server("p1", host: "a"), server("p2", host: "b")]
        await #expect(throws: MockError.self) {
            try await ChainConnector.connect(proxies: chain, destinationHost: "d", destinationPort: 80) { proxy, _, _, _ in
                if proxy.id == "p2" { throw MockError.boom }
                return MockStream()
            }
        }
    }

    // MARK: FailoverConnector

    @Test("failover returns the first proxy that connects")
    func failoverFirstSuccess() async throws {
        let list = [server("a", host: "1"), server("b", host: "2"), server("c", host: "3")]
        let attempted = Box<[String]>([])
        let used = try await FailoverConnector.connect(proxies: list) { proxy in
            attempted.value.append(proxy.id)
            if proxy.id == "a" || proxy.id == "b" { throw MockError.boom } // a,b down; c up
            return proxy.id
        }
        #expect(used == "c")
        #expect(attempted.value == ["a", "b", "c"]) // tried in order, stopped at first success
    }

    @Test("failover throws the last error when every proxy fails")
    func failoverAllFail() async {
        let list = [server("a", host: "1"), server("b", host: "2")]
        await #expect(throws: MockError.self) {
            _ = try await FailoverConnector.connect(proxies: list) { _ in throw MockError.boom }
        }
    }

    @Test("failover over an empty list throws noProxies")
    func failoverEmpty() async {
        await #expect(throws: ProxyStrategyError.noProxies) {
            _ = try await FailoverConnector.connect(proxies: []) { (_: ProxyServerDTO) in "x" }
        }
    }
}

// MARK: - test doubles

private enum MockError: Error { case boom }

private struct MockStream: ByteStream {
    func write(_ bytes: [UInt8]) async throws {}
    func read(exactly count: Int) async throws -> [UInt8] { [] }
}

private struct HopCall: Sendable {
    let proxyID: String
    let targetHost: String
    let targetPort: UInt16
    let hadBase: Bool
}

private actor HopRecorder {
    private(set) var calls: [HopCall] = []

    func hop(_ proxy: ProxyServerDTO, _ host: String, _ port: UInt16, _ base: (any ByteStream)?) async throws -> any ByteStream {
        calls.append(HopCall(proxyID: proxy.id, targetHost: host, targetPort: port, hadBase: base != nil))
        return MockStream()
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
