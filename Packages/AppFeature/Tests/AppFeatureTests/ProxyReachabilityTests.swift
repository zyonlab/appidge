import Testing
@testable import AppFeature

@Suite("ProxyChecker + MockProxyReachabilityProbe — probe 结果映射成终态，mock 可脚本化并记录调用")
struct ProxyReachabilityTests {

    // MARK: - ProxyChecker：probe 结果 → 状态映射

    @Test("probe 说可达 → .reachable")
    func probeReachableMapsToReachable() async {
        let probe = MockProxyReachabilityProbe(results: ["127.0.0.1:1080": true])
        let status = await ProxyChecker.check(host: "127.0.0.1", port: 1080, using: probe)
        #expect(status == .reachable)
    }

    @Test("probe 说不可达 → .unreachable")
    func probeUnreachableMapsToUnreachable() async {
        let probe = MockProxyReachabilityProbe(results: ["10.0.0.1:9999": false])
        let status = await ProxyChecker.check(host: "10.0.0.1", port: 9999, using: probe)
        #expect(status == .unreachable)
    }

    @Test("check 永远返回终态，绝不停在 .idle/.checking")
    func checkReturnsTerminalStatus() async {
        let probe = MockProxyReachabilityProbe(results: ["a:1": true, "b:2": false])
        let hit = await ProxyChecker.check(host: "a", port: 1, using: probe)
        let miss = await ProxyChecker.check(host: "b", port: 2, using: probe)
        #expect(hit != .idle && hit != .checking)
        #expect(miss != .idle && miss != .checking)
    }

    // MARK: - MockProxyReachabilityProbe：脚本化返回 + 默认值

    @Test("mock 对精确 host:port 返回脚本化的值")
    func mockReturnsScriptedValueForExactKey() async {
        let probe = MockProxyReachabilityProbe(results: ["proxy.example.com:8080": true])
        let reachable = await probe.isReachable(host: "proxy.example.com", port: 8080)
        #expect(reachable == true)
    }

    @Test("mock 对未预置的 key 走合理默认值（false）")
    func mockDefaultsToFalseForUnknownKey() async {
        let probe = MockProxyReachabilityProbe(results: ["known:1": true])
        let unknownHost = await probe.isReachable(host: "unknown", port: 1)
        let unknownPort = await probe.isReachable(host: "known", port: 2)
        #expect(unknownHost == false)
        #expect(unknownPort == false)
    }

    @Test("host 相同但 port 不同视为不同 key，各自独立脚本化")
    func mockDistinguishesPortOnSameHost() async {
        let probe = MockProxyReachabilityProbe(results: ["h:1": true, "h:2": false])
        let one = await probe.isReachable(host: "h", port: 1)
        let two = await probe.isReachable(host: "h", port: 2)
        #expect(one == true)
        #expect(two == false)
    }

    // MARK: - MockProxyReachabilityProbe：记录调用

    @Test("mock 记录它被调用时的 host/port")
    func mockRecordsCallArguments() async {
        let probe = MockProxyReachabilityProbe(results: ["127.0.0.1:1080": true])
        _ = await ProxyChecker.check(host: "127.0.0.1", port: 1080, using: probe)
        let calls = await probe.calls
        #expect(calls.count == 1)
        #expect(calls.first?.host == "127.0.0.1")
        #expect(calls.first?.port == 1080)
    }

    @Test("mock 按调用顺序累积多次调用")
    func mockAccumulatesCallsInOrder() async {
        let probe = MockProxyReachabilityProbe()
        _ = await probe.isReachable(host: "first", port: 1)
        _ = await probe.isReachable(host: "second", port: 2)
        let calls = await probe.calls
        #expect(calls.count == 2)
        #expect(calls.map(\.host) == ["first", "second"])
        #expect(calls.map(\.port) == [1, 2])
    }
}
