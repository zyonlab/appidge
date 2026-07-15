import Testing
import Core
@testable import AppFeature

@Suite("LocalProxyOriginDiscovery + MockLocalProcessIdentityResolver — 只在 active 上游指向本机时查询,查不到就是空结果")
struct LocalProxyOriginDiscoveryTests {

    private func state(host: String, port: UInt16, id: String = "a", makeActive: Bool = true) -> Core.AppState {
        var state = Core.AppState()
        let serverID = Core.ProxyServerID(id)
        state.proxyServers[serverID] = Core.ProxyServer(id: serverID, host: host, port: port)
        if makeActive {
            state.activeProxyServerID = serverID
        }
        return state
    }

    // MARK: - 回环字面量识别

    @Test("127.0.0.1 视为本机回环")
    func recognizesIPv4Loopback() {
        #expect(LocalProxyOriginDiscovery.isLocalLoopback(host: "127.0.0.1"))
    }

    @Test("::1 视为本机回环")
    func recognizesIPv6Loopback() {
        #expect(LocalProxyOriginDiscovery.isLocalLoopback(host: "::1"))
    }

    @Test("localhost 视为本机回环")
    func recognizesLocalhostLiteral() {
        #expect(LocalProxyOriginDiscovery.isLocalLoopback(host: "localhost"))
    }

    @Test("远程地址(域名/公网 IP/私网段)不视为本机回环")
    func rejectsNonLoopbackHosts() {
        #expect(!LocalProxyOriginDiscovery.isLocalLoopback(host: "proxy.example.com"))
        #expect(!LocalProxyOriginDiscovery.isLocalLoopback(host: "1.2.3.4"))
        #expect(!LocalProxyOriginDiscovery.isLocalLoopback(host: "10.0.0.1")) // 私网段判定是 EngineKit 的职责,这里不覆盖
    }

    // MARK: - discover:active 是本地回环 → 查询并返回身份

    @Test("active 上游是 127.0.0.1 → 查询该端口,返回签名标识 + 可执行文件路径")
    func discoversWhenActiveIsIPv4Loopback() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: "com.example.xray", executablePath: "/usr/local/bin/xray")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "127.0.0.1", port: 1080), using: resolver
        )
        #expect(result.identifiers == ["com.example.xray"])
        #expect(result.executablePaths == ["/usr/local/bin/xray"])
        #expect(await resolver.calls == [1080])
    }

    @Test("active 上游是 ::1 → 也会查询")
    func discoversWhenActiveIsIPv6Loopback() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1089: LocalProcessIdentity(signingIdentifier: "com.example.yunti")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "::1", port: 1089), using: resolver
        )
        #expect(result.identifiers == ["com.example.yunti"])
        #expect(await resolver.calls == [1089])
    }

    @Test("active 上游是 localhost → 也会查询")
    func discoversWhenActiveIsLocalhostLiteral() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            8080: LocalProcessIdentity(signingIdentifier: "com.example.v2ray")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "localhost", port: 8080), using: resolver
        )
        #expect(result.identifiers == ["com.example.v2ray"])
        #expect(await resolver.calls == [8080])
    }

    @Test("resolver 只查到可执行文件路径、没有签名标识(未签名进程)→ discovery 只带路径")
    func discoversPathOnlyForUnsignedProcess() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: nil, executablePath: "/usr/local/bin/a.out")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "127.0.0.1", port: 1080), using: resolver
        )
        #expect(result.identifiers.isEmpty)
        #expect(result.executablePaths == ["/usr/local/bin/a.out"])
    }

    // MARK: - discover:active 不是本地 → 不查询

    @Test("active 上游是远程地址 → 不查询,返回空结果")
    func doesNotQueryWhenActiveIsRemote() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: "should-not-be-seen")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "proxy.example.com", port: 1080), using: resolver
        )
        #expect(result == OriginExclusionDiscovery())
        #expect(await resolver.calls.isEmpty)
    }

    @Test("active 上游是私网段(如 10.x)→ 不查询——那是 EngineKit 地址判定的职责,这里不重复覆盖")
    func doesNotQueryForPrivateRangeAddresses() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: "should-not-be-seen")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "10.0.0.1", port: 1080), using: resolver
        )
        #expect(result == OriginExclusionDiscovery())
        #expect(await resolver.calls.isEmpty)
    }

    // MARK: - discover:没有 active server → 不查询

    @Test("没有配置任何代理服务器 → 不查询,返回空结果")
    func doesNotQueryWhenNoServersConfigured() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: "should-not-be-seen")
        ])
        let result = await LocalProxyOriginDiscovery.discover(state: Core.AppState(), using: resolver)
        #expect(result == OriginExclusionDiscovery())
        #expect(await resolver.calls.isEmpty)
    }

    @Test("配置了代理服务器但没有 active(未选中)→ 不查询")
    func doesNotQueryWhenNoActiveServerSelected() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [
            1080: LocalProcessIdentity(signingIdentifier: "should-not-be-seen")
        ])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "127.0.0.1", port: 1080, makeActive: false), using: resolver
        )
        #expect(result == OriginExclusionDiscovery())
        #expect(await resolver.calls.isEmpty)
    }

    // MARK: - discover:resolver 返回 nil → 视为「没发现」,空结果(不是错误/不 throw)

    @Test("active 是本地但 resolver 查不到监听者(未预置端口)→ 空结果")
    func returnsEmptyWhenResolverFindsNoListener() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [:])
        let result = await LocalProxyOriginDiscovery.discover(
            state: state(host: "127.0.0.1", port: 1080), using: resolver
        )
        #expect(result == OriginExclusionDiscovery())
        #expect(await resolver.calls == [1080]) // 仍然发起了查询,只是查不到——不是"提前短路"
    }

    // MARK: - MockLocalProcessIdentityResolver:脚本化返回 + 调用记录

    @Test("mock 对精确端口返回脚本化的身份,未预置端口返回 nil")
    func mockReturnsScriptedValueForExactPort() async {
        let resolver = MockLocalProcessIdentityResolver(scripted: [1080: LocalProcessIdentity(signingIdentifier: "known")])
        #expect(await resolver.identity(forListeningPort: 1080) == LocalProcessIdentity(signingIdentifier: "known"))
        #expect(await resolver.identity(forListeningPort: 9999) == nil)
    }

    @Test("mock 按调用顺序累积被查询过的端口")
    func mockAccumulatesCallsInOrder() async {
        let resolver = MockLocalProcessIdentityResolver()
        _ = await resolver.identity(forListeningPort: 1)
        _ = await resolver.identity(forListeningPort: 2)
        #expect(await resolver.calls == [1, 2])
    }
}
