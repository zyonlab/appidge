import Testing
import IPCContract
@testable import EngineKit

/// UDP 接管决策的穷举:proxied/block 的进程 → 拦截止漏;direct/无规则 → 放行直连;
/// 我们自己组件 → 永远放行(转发环硬化优先于规则)。
@Suite("UDPFlowPolicy — block proxied/blocked UDP to stop QUIC leaking, allow the rest direct")
struct UDPFlowPolicyTests {
    private let own: Set<String> = ["com.appidge.app", "com.appidge.app.ProxyExtension"]

    @Test("a proxied process's UDP is blocked (forces QUIC fallback to TCP)")
    func proxiedBlocked() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.acme.app", ownIdentifiers: own, perProcessRule: .proxied) == .block)
    }

    @Test("a blocked process's UDP is blocked too (whole process denied)")
    func blockRuleBlocks() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.acme.app", ownIdentifiers: own, perProcessRule: .block) == .block)
    }

    @Test("a direct process's UDP is allowed to go direct")
    func directAllowed() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.acme.app", ownIdentifiers: own, perProcessRule: .direct) == .allowDirect)
    }

    @Test("no explicit rule defaults to allow-direct")
    func noRuleAllows() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.acme.app", ownIdentifiers: own, perProcessRule: nil) == .allowDirect)
    }

    @Test("our own components are always allowed direct, even if a stray proxied rule names them (loop hardening wins)")
    func ownComponentsAlwaysDirect() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.appidge.app.ProxyExtension", ownIdentifiers: own, perProcessRule: .proxied) == .allowDirect)
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.appidge.app", ownIdentifiers: own, perProcessRule: .block) == .allowDirect)
    }

    @Test("empty own-identifier set means only the rule decides")
    func emptyOwnSet() {
        #expect(UDPFlowPolicy.disposition(sourceIdentifier: "com.appidge.app", ownIdentifiers: [], perProcessRule: .proxied) == .block)
    }
}
