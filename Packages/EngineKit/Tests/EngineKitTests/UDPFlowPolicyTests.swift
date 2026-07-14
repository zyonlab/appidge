import Testing
import IPCContract
@testable import EngineKit

/// UDP 接管决策的穷举:每进程规则 × 全局 UDP 策略 × 上游是否 SOCKS5。own 组件永远放行,
/// 每进程 block 永远拦,proxied 才看策略;proxySOCKS5 只有上游是 SOCKS5 才真代理、否则止漏。
@Suite("UDPFlowPolicy — per-process rule × global UDP policy × upstream kind")
struct UDPFlowPolicyTests {
    private let own: Set<String> = ["com.appidge.app", "com.appidge.app.ProxyExtension"]

    private func d(
        _ rule: ProxyRuleDTO?, _ policy: UDPPolicyDTO, socks5: Bool = true, source: String = "com.acme.app"
    ) -> UDPFlowPolicy.Disposition {
        UDPFlowPolicy.disposition(
            sourceIdentifier: source, ownIdentifiers: own,
            perProcessRule: rule, udpPolicy: policy, upstreamIsSOCKS5: socks5
        )
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
}
