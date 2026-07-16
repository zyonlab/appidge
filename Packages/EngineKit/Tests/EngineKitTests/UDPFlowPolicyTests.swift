import Testing
import IPCContract
@testable import EngineKit

/// UDP 接管决策的穷举:每进程规则 × 全局 UDP 策略 × 上游是否 SOCKS5。own 组件永远放行,
/// 每进程 block 永远拦,proxied 才看策略;proxySOCKS5 只有上游是 SOCKS5 才真代理、否则止漏。
@Suite("UDPFlowPolicy — per-process rule × global UDP policy × upstream kind")
struct UDPFlowPolicyTests {
    private let own: Set<String> = ["com.appidge.app", "com.appidge.app.ProxyExtension"]

    private func d(
        _ rule: ProxyRuleDTO?, _ policy: UDPPolicyDTO, socks5: Bool = true, source: String = "com.acme.app",
        matchRules: [MatchRuleDTO] = []
    ) -> UDPFlowPolicy.Disposition {
        UDPFlowPolicy.disposition(
            sourceIdentifier: source, ownIdentifiers: own,
            matchRules: matchRules,
            perProcessRule: rule, udpPolicy: policy, upstreamIsSOCKS5: socks5
        )
    }

    private func rule(
        _ app: String, host: String = "*", port: ClosedRange<UInt16>? = nil, _ action: ProxyRuleDTO
    ) -> MatchRuleDTO {
        MatchRuleDTO(id: app, appPattern: app, hostPattern: host, portRange: port, rule: action)
    }

    @Test("our own components are always allowed direct (loop hardening wins over everything)")
    func ownAlwaysDirect() {
        #expect(d(.proxied, .proxySOCKS5, source: "com.appidge.app.ProxyExtension") == .allowDirect)
        #expect(d(.block, .block, source: "com.appidge.app") == .allowDirect)
    }

    @Test("a direct process (or no rule) is always allowDirect regardless of policy")
    func directAlwaysDirect() {
        #expect(d(.direct, .block) == .allowDirect)
        #expect(d(nil, .proxySOCKS5) == .allowDirect)
    }

    @Test("a per-process block rule always blocks, whatever the UDP policy")
    func perProcessBlockAlwaysBlocks() {
        #expect(d(.block, .block) == .block)
        #expect(d(.block, .direct) == .block)
        #expect(d(.block, .proxySOCKS5) == .block)
    }

    @Test("proxied + policy .block → block (stop the QUIC leak)")
    func proxiedBlockPolicy() {
        #expect(d(.proxied, .block) == .block)
    }

    @Test("proxied + policy .direct → allowDirect (escape hatch for UDP-needing apps)")
    func proxiedDirectPolicy() {
        #expect(d(.proxied, .direct) == .allowDirect)
    }

    @Test("proxied + policy .proxySOCKS5 → proxy when the upstream is SOCKS5")
    func proxiedProxyPolicyWithSocks5() {
        #expect(d(.proxied, .proxySOCKS5, socks5: true) == .proxy)
    }

    @Test("proxied + policy .proxySOCKS5 but upstream is NOT SOCKS5 → block (can't proxy UDP, so stop the leak)")
    func proxiedProxyPolicyWithoutSocks5() {
        #expect(d(.proxied, .proxySOCKS5, socks5: false) == .block)
    }

    // MARK: - 规则表的 app 维度也参与 UDP 决策(修 QUIC 泄漏:经规则表 proxied 的进程 UDP 曾被放行)

    @Test("a host-agnostic match rule (app × * × any-port) drives the UDP decision — proxied app leaks no QUIC")
    func matchRuleProxiedBlocksUDP() {
        // 进程只有规则表里的「走代理」(UI 的主要入口),没有每进程规则——修复前被当成"无规则"放行。
        #expect(d(nil, .block, matchRules: [rule("com.acme.app", .proxied)]) == .block)
        #expect(d(nil, .proxySOCKS5, socks5: true, matchRules: [rule("com.acme.app", .proxied)]) == .proxy)
    }

    @Test("match rule glob matches the app pattern")
    func matchRuleGlob() {
        #expect(d(nil, .block, matchRules: [rule("com.acme.*", .proxied)]) == .block)
    }

    @Test("match rule outranks the per-process rule (same top-to-bottom recency order as TCP)")
    func matchRuleOutranksPerProcess() {
        // 规则表的派生规则在表首 = 最新意图;每进程规则只是兜底。
        #expect(d(.proxied, .block, matchRules: [rule("com.acme.app", .direct)]) == .allowDirect)
        #expect(d(.direct, .block, matchRules: [rule("com.acme.app", .block)]) == .block)
    }

    @Test("host- or port-specific rules do NOT drive UDP (no single destination to match); falls through")
    func hostSpecificRulesAreIgnoredForUDP() {
        #expect(d(nil, .block, matchRules: [rule("com.acme.app", host: "example.com", .proxied)]) == .allowDirect)
        #expect(d(nil, .block, matchRules: [rule("com.acme.app", port: 443...443, .proxied)]) == .allowDirect)
    }

    @Test("own components still bypass even when a match rule would proxy them")
    func ownBypassBeatsMatchRules() {
        #expect(d(nil, .block, source: "com.appidge.app", matchRules: [rule("*", .proxied)]) == .allowDirect)
    }
}
