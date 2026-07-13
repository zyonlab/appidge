import Testing
@testable import EngineKit

/// Pure, stateless upstream-endpoint matching — every case is a plain `#expect` against
/// `UpstreamExclusion.isUpstream(host:port:upstreams:)`.
///
/// This is called from the extension's flow-routing path to force connections *to a
/// configured upstream proxy* direct, so the extension→upstream hop cannot itself be
/// re-captured and re-proxied into an infinite loop (see
/// `docs/proxifier-feature-alignment.md` §6b). It complements `LoopbackDetector`:
/// loopback exclusion only *coincidentally* covers the case where the upstream happens to
/// be `127.0.0.1`; this covers an explicitly configured, possibly non-loopback upstream
/// (e.g. a corporate `10.x` proxy) that loopback would miss.
@Suite("UpstreamExclusion — pure upstream-endpoint matching")
struct UpstreamExclusionTests {

    private func endpoint(_ host: String, _ port: UInt16) -> UpstreamEndpoint {
        UpstreamEndpoint(host: host, port: port)
    }

    // MARK: - Host AND port must both match

    @Test("exact host + port match is an upstream connection")
    func exactMatch() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("10.0.0.1", 1080)]
        #expect(UpstreamExclusion.isUpstream(host: "10.0.0.1", port: 1080, upstreams: upstreams))
    }

    @Test("same host but a different port is NOT the upstream (must not force direct)")
    func sameHostDifferentPort() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("10.0.0.1", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "10.0.0.1", port: 443, upstreams: upstreams))
    }

    @Test("same port but a different host is NOT the upstream")
    func samePortDifferentHost() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("10.0.0.1", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "10.0.0.2", port: 1080, upstreams: upstreams))
    }

    // MARK: - IPv4 address normalization (not naive string equality)

    @Test("IPv4 in non-canonical leading-zero form matches its canonical form")
    func ipv4NonCanonicalForm() {
        // inet_pton normalizes 127.000.000.001 and 127.0.0.1 to the same 4 bytes.
        let upstreams: Set<UpstreamEndpoint> = [endpoint("127.0.0.1", 1080)]
        #expect(UpstreamExclusion.isUpstream(host: "127.000.000.001", port: 1080, upstreams: upstreams))
    }

    @Test("IPv4 normalization also applies when the upstream is the non-canonical side")
    func ipv4NonCanonicalUpstreamSide() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("127.000.000.001", 1080)]
        #expect(UpstreamExclusion.isUpstream(host: "127.0.0.1", port: 1080, upstreams: upstreams))
    }

    // MARK: - IPv6 address normalization

    @Test("IPv6 compressed vs fully-expanded forms match")
    func ipv6CompressedVsExpanded() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("::1", 1080)]
        #expect(UpstreamExclusion.isUpstream(host: "0:0:0:0:0:0:0:1", port: 1080, upstreams: upstreams))
    }

    @Test("bracketed IPv6 literal matches the same address written without brackets")
    func ipv6BracketedVsBare() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("[::1]", 1080)]
        #expect(UpstreamExclusion.isUpstream(host: "::1", port: 1080, upstreams: upstreams))
    }

    @Test("a non-loopback IPv6 upstream matches across compressed / expanded textual forms")
    func ipv6NonLoopbackForms() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("2001:db8::1", 8080)]
        #expect(UpstreamExclusion.isUpstream(
            host: "2001:0db8:0000:0000:0000:0000:0000:0001", port: 8080, upstreams: upstreams
        ))
    }

    // MARK: - Hostname comparison (case-insensitive, textual — no DNS resolution)

    @Test("hostnames match case-insensitively")
    func hostnameCaseInsensitive() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("Proxy.Corp", 3128)]
        #expect(UpstreamExclusion.isUpstream(host: "proxy.corp", port: 3128, upstreams: upstreams))
    }

    @Test("different hostnames do not match")
    func differentHostnames() {
        let upstreams: Set<UpstreamEndpoint> = [endpoint("proxy.corp", 3128)]
        #expect(!UpstreamExclusion.isUpstream(host: "other.corp", port: 3128, upstreams: upstreams))
    }

    @Test("a hostname upstream is not matched by an IP-literal destination and vice versa")
    func ipLiteralVsHostname() {
        // Pure/textual only — we do NOT resolve "localhost" to 127.0.0.1 (no DNS, no I/O).
        // Whoever wires this in must pass the destination in the same address family the
        // upstream is configured with (see integration note in the PR).
        let ipUpstream: Set<UpstreamEndpoint> = [endpoint("127.0.0.1", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "localhost", port: 1080, upstreams: ipUpstream))

        let hostnameUpstream: Set<UpstreamEndpoint> = [endpoint("localhost", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "127.0.0.1", port: 1080, upstreams: hostnameUpstream))
    }

    // MARK: - IPv4-mapped IPv6 decision (pinned)

    @Test("IPv4 and its IPv4-mapped IPv6 form are deliberately NOT the same host")
    func ipv4MappedIsDistinct() {
        // Decision (pinned): ::ffff:127.0.0.1 parses to a 16-byte IPv6 address whose bytes
        // differ from the 4-byte IPv4 127.0.0.1, so we treat them as different hosts. This
        // is consistent with LoopbackDetector, which deliberately keeps ::ffff:127.0.0.1
        // OUT of the loopback block. Changing this must be an explicit, test-visible diff.
        let ipv4Upstream: Set<UpstreamEndpoint> = [endpoint("127.0.0.1", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "::ffff:127.0.0.1", port: 1080, upstreams: ipv4Upstream))

        let mappedUpstream: Set<UpstreamEndpoint> = [endpoint("::ffff:127.0.0.1", 1080)]
        #expect(!UpstreamExclusion.isUpstream(host: "127.0.0.1", port: 1080, upstreams: mappedUpstream))
    }

    // MARK: - Multiple upstreams / empty set

    @Test("matches any one endpoint in a multi-upstream set")
    func matchesAnyInSet() {
        let upstreams: Set<UpstreamEndpoint> = [
            endpoint("10.0.0.1", 1080),
            endpoint("proxy.corp", 3128),
            endpoint("::1", 9050)
        ]
        #expect(UpstreamExclusion.isUpstream(host: "proxy.corp", port: 3128, upstreams: upstreams))
        #expect(UpstreamExclusion.isUpstream(host: "0:0:0:0:0:0:0:1", port: 9050, upstreams: upstreams))
    }

    @Test("matches none of the endpoints in a multi-upstream set")
    func matchesNoneInSet() {
        let upstreams: Set<UpstreamEndpoint> = [
            endpoint("10.0.0.1", 1080),
            endpoint("proxy.corp", 3128)
        ]
        // Right host / wrong port for the first, wrong host for the second → no match.
        #expect(!UpstreamExclusion.isUpstream(host: "10.0.0.1", port: 3128, upstreams: upstreams))
    }

    @Test("an empty upstream set never matches")
    func emptySet() {
        #expect(!UpstreamExclusion.isUpstream(host: "10.0.0.1", port: 1080, upstreams: []))
    }

    // MARK: - The motivating scenario: a non-loopback upstream that loopback exclusion misses

    @Test("a non-loopback corporate upstream (10.x) is matched — loopback exclusion would miss it")
    func corporateNonLoopbackUpstream() {
        // LoopbackDetector.isLoopback("10.20.30.40") is false, so without this explicit
        // guard the extension→upstream hop to a corporate proxy could be re-proxied.
        let upstreams: Set<UpstreamEndpoint> = [endpoint("10.20.30.40", 8080)]
        #expect(UpstreamExclusion.isUpstream(host: "10.20.30.40", port: 8080, upstreams: upstreams))
        #expect(!UpstreamExclusion.isUpstream(host: "10.20.30.40", port: 443, upstreams: upstreams))
    }
}
