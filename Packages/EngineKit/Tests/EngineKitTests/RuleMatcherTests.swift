import Testing
import IPCContract
@testable import EngineKit

@Suite("RuleMatcher — MatchRuleDTO: process × host × port, glob + range, first match")
struct RuleMatcherTests {

    private func rule(
        _ id: String, app: String = "*", host: String = "*",
        ports: ClosedRange<UInt16>? = nil, _ rule: ProxyRuleDTO = .proxied
    ) -> MatchRuleDTO {
        MatchRuleDTO(id: id, appPattern: app, hostPattern: host, portRange: ports, rule: rule)
    }

    @Test("wildcard-everything matches any flow")
    func matchAll() {
        #expect(RuleMatcher.matches(rule("a"), app: "com.x", host: "example.com", port: 443))
    }

    @Test("exact host is case-insensitive, only that host")
    func exactHost() {
        let r = rule("a", host: "Example.com")
        #expect(RuleMatcher.matches(r, app: "x", host: "EXAMPLE.COM", port: 443))
        #expect(!RuleMatcher.matches(r, app: "x", host: "mail.example.com", port: 443))
    }

    @Test("*.example.com matches subdomains, not the apex")
    func wildcardSubdomain() {
        let r = rule("a", host: "*.example.com")
        #expect(RuleMatcher.matches(r, app: "x", host: "mail.example.com", port: 443))
        #expect(RuleMatcher.matches(r, app: "x", host: "a.b.example.com", port: 443))
        #expect(!RuleMatcher.matches(r, app: "x", host: "example.com", port: 443))
        #expect(!RuleMatcher.matches(r, app: "x", host: "notexample.com", port: 443))
    }

    @Test("*example.com matches apex and subdomains")
    func wildcardPrefix() {
        let r = rule("a", host: "*example.com")
        #expect(RuleMatcher.matches(r, app: "x", host: "example.com", port: 443))
        #expect(RuleMatcher.matches(r, app: "x", host: "mail.example.com", port: 443))
    }

    @Test("app pattern globs on the signing identifier")
    func appGlob() {
        let r = rule("a", app: "com.google.*")
        #expect(RuleMatcher.matches(r, app: "com.google.Chrome", host: "h", port: 1))
        #expect(!RuleMatcher.matches(r, app: "com.apple.Safari", host: "h", port: 1))
    }

    @Test("nil port range = any; a range is inclusive")
    func portRange() {
        #expect(RuleMatcher.matches(rule("a", ports: nil), app: "x", host: "h", port: 65535))
        let web = rule("a", ports: 80...443)
        #expect(RuleMatcher.matches(web, app: "x", host: "h", port: 80))
        #expect(RuleMatcher.matches(web, app: "x", host: "h", port: 443))
        #expect(!RuleMatcher.matches(web, app: "x", host: "h", port: 444))
    }

    @Test("all three dimensions must match")
    func conjunction() {
        let r = rule("a", app: "com.x", host: "*.corp.net", ports: 22...22)
        #expect(RuleMatcher.matches(r, app: "com.x", host: "git.corp.net", port: 22))
        #expect(!RuleMatcher.matches(r, app: "com.y", host: "git.corp.net", port: 22))
        #expect(!RuleMatcher.matches(r, app: "com.x", host: "git.other.net", port: 22))
        #expect(!RuleMatcher.matches(r, app: "com.x", host: "git.corp.net", port: 80))
    }

    @Test("firstMatch returns the first matching rule's action, top to bottom")
    func firstMatchWins() {
        let rules = [rule("1", host: "*.internal", .direct), rule("2", host: "*", .proxied)]
        #expect(RuleMatcher.firstMatch(rules, app: "x", host: "wiki.internal", port: 443) == .direct)
        #expect(RuleMatcher.firstMatch(rules, app: "x", host: "example.com", port: 443) == .proxied)
    }

    @Test("order matters — a broad rule above a specific one shadows it")
    func orderMatters() {
        let broadFirst = [rule("1", host: "*", .proxied), rule("2", host: "*.internal", .direct)]
        #expect(RuleMatcher.firstMatch(broadFirst, app: "x", host: "wiki.internal", port: 443) == .proxied)
    }

    @Test("no match / empty list returns nil")
    func noMatch() {
        #expect(RuleMatcher.firstMatch([rule("1", app: "com.only")], app: "com.other", host: "h", port: 1) == nil)
        #expect(RuleMatcher.firstMatch([], app: "x", host: "h", port: 1) == nil)
    }
}
