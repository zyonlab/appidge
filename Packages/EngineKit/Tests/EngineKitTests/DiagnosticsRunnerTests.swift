import Testing
import Foundation
import IPCContract
@testable import EngineKit

/// Deterministic stand-in for ``CurrentRuleLookup``: no real rule-set store, just a fixed
/// dictionary handed in by the test.
private actor FakeRuleLookup: CurrentRuleLookup {
    private let rules: [ProcessIdentifierDTO: ProxyRuleDTO]

    init(rules: [ProcessIdentifierDTO: ProxyRuleDTO]) {
        self.rules = rules
    }

    func currentRule(for processID: ProcessIdentifierDTO) async -> ProxyRuleDTO? {
        rules[processID]
    }
}

/// Deterministic stand-in for ``RecentRoutingLookup``.
private actor FakeRoutingLookup: RecentRoutingLookup {
    private let answers: [ProcessIdentifierDTO: Bool?]

    init(answers: [ProcessIdentifierDTO: Bool?]) {
        self.answers = answers
    }

    func wasRecentlyProxied(processID: ProcessIdentifierDTO) async -> Bool? {
        answers[processID] ?? nil
    }
}

/// Deterministic stand-in for ``UpstreamProbing`` — never touches Network.framework.
private struct FakeUpstreamProbe: UpstreamProbing {
    let reachable: Bool

    func canReach(host: String, port: UInt16) async -> Bool {
        reachable
    }
}

/// Deterministic stand-in for ``DNSResolving`` — never performs a real lookup.
private struct FakeDNSResolver: DNSResolving {
    let resolves: Bool

    func resolves(host: String) async -> Bool {
        resolves
    }
}

/// Deterministic stand-in for ``EnvironmentReading`` — never reads ``ProcessInfo``.
private struct FakeEnvironmentReader: EnvironmentReading {
    let environment: [String: String]

    func currentEnvironment() async -> [String: String] {
        environment
    }
}

@Suite("DiagnosticsRunner — protocol-injected diagnostics, no real network/DNS in tests")
struct DiagnosticsRunnerTests {

    private let processID = ProcessIdentifierDTO("com.example.target")

    // MARK: - ruleHit

    @Test("ruleHit passes when a rule is currently assigned to the process")
    func ruleHitPassesWhenAssigned() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [processID: .proxied]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.ruleHit])
        #expect(results.count == 1)
        #expect(results[0].kind == .ruleHit)
        #expect(results[0].passed == true)
        #expect(results[0].detail.contains("proxied"))
    }

    @Test("ruleHit fails when no rule is assigned — defaults apply")
    func ruleHitFailsWhenUnassigned() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.ruleHit])
        #expect(results[0].passed == false)
        #expect(results[0].detail.contains("默认") || results[0].detail.lowercased().contains("default"))
    }

    // MARK: - actuallyProxied

    @Test("actuallyProxied passes when the routing tracker recorded a proxied flow")
    func actuallyProxiedPassesWhenRecentlyProxied() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [processID: true]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.actuallyProxied])
        #expect(results[0].passed == true)
    }

    @Test("actuallyProxied fails when the routing tracker recorded a direct flow")
    func actuallyProxiedFailsWhenRecentlyDirect() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [processID: false]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.actuallyProxied])
        #expect(results[0].passed == false)
    }

    @Test("actuallyProxied fails with a distinct detail when there is no routing history at all")
    func actuallyProxiedFailsWhenNoHistory() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [processID: Optional<Bool>.none]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.actuallyProxied])
        #expect(results[0].passed == false)
        #expect(results[0].detail.contains("历史") || results[0].detail.lowercased().contains("history") || results[0].detail.lowercased().contains("no record"))
    }

    // MARK: - upstreamReachable

    @Test("upstreamReachable passes when the probe reports reachable")
    func upstreamReachablePasses() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.upstreamReachable])
        #expect(results[0].passed == true)
    }

    @Test("upstreamReachable fails when the probe reports unreachable")
    func upstreamReachableFails() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: false),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.upstreamReachable])
        #expect(results[0].passed == false)
    }

    // MARK: - dnsResolution

    @Test("dnsResolution passes when the resolver reports success")
    func dnsResolutionPasses() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.dnsResolution])
        #expect(results[0].passed == true)
    }

    @Test("dnsResolution fails when the resolver reports failure")
    func dnsResolutionFails() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: false),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.dnsResolution])
        #expect(results[0].passed == false)
    }

    // MARK: - udpIPv6QuicLeak (honest, always-known-limitation)

    @Test("udpIPv6QuicLeak always reports the known NETransparentProxyProvider TCP-only limitation")
    func udpIPv6QuicLeakIsHonestlyUnsupported() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.udpIPv6QuicLeak])
        #expect(results[0].passed == false)
        #expect(results[0].detail.contains("TCP"))
        #expect(results[0].detail.contains("NETransparentProxyProvider"))
    }

    // MARK: - envConflict

    @Test("envConflict passes when no known proxy env vars are set")
    func envConflictPassesWhenClean() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.envConflict])
        #expect(results[0].passed == true)
    }

    @Test("envConflict fails when HTTP_PROXY is set alongside HTTPS_PROXY")
    func envConflictFailsWhenProxyVarsSet() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [
                "HTTP_PROXY": "http://127.0.0.1:8080",
                "HTTPS_PROXY": "http://127.0.0.1:8080"
            ])
        )

        let results = await runner.run(processID: processID, kinds: [.envConflict])
        #expect(results[0].passed == false)
        #expect(results[0].detail.contains("HTTP_PROXY"))
    }

    @Test("envConflict detail honestly notes it only sees the extension's own process environment")
    func envConflictDocumentsItsOwnProcessLimitation() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [:]),
            routingLookup: FakeRoutingLookup(answers: [:]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let results = await runner.run(processID: processID, kinds: [.envConflict])
        #expect(
            results[0].detail.contains("扩展") || results[0].detail.lowercased().contains("extension process")
        )
    }

    // MARK: - multiple kinds in one call

    @Test("run(kinds:) returns one result per requested kind, in order, all tagged with the process id")
    func runReturnsOneResultPerKindInOrder() async {
        let runner = DiagnosticsRunner(
            ruleLookup: FakeRuleLookup(rules: [processID: .direct]),
            routingLookup: FakeRoutingLookup(answers: [processID: true]),
            upstreamProbe: FakeUpstreamProbe(reachable: true),
            dnsResolver: FakeDNSResolver(resolves: true),
            environmentReader: FakeEnvironmentReader(environment: [:])
        )

        let kinds: [DiagnosticKindDTO] = [.ruleHit, .actuallyProxied, .upstreamReachable, .dnsResolution, .udpIPv6QuicLeak, .envConflict]
        let results = await runner.run(processID: processID, kinds: kinds)

        #expect(results.map(\.kind) == kinds)
        #expect(results.allSatisfy { $0.processID == processID })
    }
}

// MARK: - AppliedRuleSetStore (real CurrentRuleLookup)

@Suite("AppliedRuleSetStore — real CurrentRuleLookup backed by the latest applied RuleSetMessage")
struct AppliedRuleSetStoreTests {

    @Test("apply(_:) then currentRule(for:) returns the assigned rule")
    func appliedRuleIsRetrievable() async {
        let store = AppliedRuleSetStore()
        let target = ProcessIdentifierDTO("com.example.target")
        let ruleSet = RuleSetMessage(
            assignments: [RuleAssignmentDTO(processID: target, rule: .proxied)]
        )

        await store.apply(ruleSet)
        let rule = await store.currentRule(for: target)
        #expect(rule == .proxied)
    }

    @Test("currentRule(for:) returns nil for a process never covered by any applied rule set")
    func unknownProcessHasNoRule() async {
        let store = AppliedRuleSetStore()
        let rule = await store.currentRule(for: ProcessIdentifierDTO("com.example.unknown"))
        #expect(rule == nil)
    }

    @Test("a later apply(_:) replaces an earlier assignment for the same process")
    func laterApplyReplacesEarlierAssignment() async {
        let store = AppliedRuleSetStore()
        let target = ProcessIdentifierDTO("com.example.target")

        await store.apply(RuleSetMessage(
            assignments: [RuleAssignmentDTO(processID: target, rule: .direct)]
        ))
        await store.apply(RuleSetMessage(
            assignments: [RuleAssignmentDTO(processID: target, rule: .proxied)]
        ))

        let rule = await store.currentRule(for: target)
        #expect(rule == .proxied)
    }

    @Test("apply stores the match-rule table; matchRule evaluates it first-match")
    func matchRuleEvaluation() async {
        let store = AppliedRuleSetStore()
        await store.apply(RuleSetMessage(
            assignments: [],
            matchRules: [
                MatchRuleDTO(id: "1", appPattern: "*", hostPattern: "*.internal", portRange: nil, rule: .direct),
                MatchRuleDTO(id: "2", appPattern: "*", hostPattern: "*", portRange: nil, rule: .proxied)
            ]
        ))
        #expect(await store.matchRule(app: "x", host: "wiki.internal", port: 443) == .direct)
        #expect(await store.matchRule(app: "x", host: "example.com", port: 443) == .proxied)
    }

    @Test("a later apply replaces the match-rule table too (no stale rules)")
    func matchRuleReplaced() async {
        let store = AppliedRuleSetStore()
        await store.apply(RuleSetMessage(
            assignments: [],
            matchRules: [MatchRuleDTO(id: "old", appPattern: "*", hostPattern: "*", portRange: nil, rule: .proxied)]
        ))
        await store.apply(RuleSetMessage(assignments: [], matchRules: []))
        #expect(await store.matchRule(app: "x", host: "example.com", port: 443) == nil)
    }
}

// MARK: - RoutingHistoryTracker (real RecentRoutingLookup)

@Suite("RoutingHistoryTracker — real RecentRoutingLookup backed by recorded routing outcomes")
struct RoutingHistoryTrackerTests {

    @Test("record(processID:wasProxied:) then wasRecentlyProxied(processID:) returns the recorded value")
    func recordedOutcomeIsRetrievable() async {
        let tracker = RoutingHistoryTracker()
        let target = ProcessIdentifierDTO("com.example.target")

        await tracker.record(processID: target, wasProxied: true)
        let result = await tracker.wasRecentlyProxied(processID: target)
        #expect(result == true)
    }

    @Test("wasRecentlyProxied(processID:) returns nil for a process with no recorded history")
    func unknownProcessHasNoHistory() async {
        let tracker = RoutingHistoryTracker()
        let result = await tracker.wasRecentlyProxied(processID: ProcessIdentifierDTO("com.example.unknown"))
        #expect(result == nil)
    }

    @Test("the most recent record(processID:wasProxied:) call wins")
    func mostRecentRecordWins() async {
        let tracker = RoutingHistoryTracker()
        let target = ProcessIdentifierDTO("com.example.target")

        await tracker.record(processID: target, wasProxied: true)
        await tracker.record(processID: target, wasProxied: false)

        let result = await tracker.wasRecentlyProxied(processID: target)
        #expect(result == false)
    }
}
