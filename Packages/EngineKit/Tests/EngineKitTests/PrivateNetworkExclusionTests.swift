import Testing
@testable import EngineKit

/// Pure, stateless classification of whether a flow's destination host sits in a
/// private-network / link-local block. Every case is a plain `#expect` against
/// `PrivateNetworkExclusion.isPrivateNetwork(host:)`.
///
/// This is the address-judgment complement to `LoopbackDetector` (which only owns
/// 127.0.0.0/8 and ::1): "local dev server / LAN device should not be proxied" is a real
/// scenario the loopback block alone does not cover (see PROGRESS.md
/// "防环设计定论" §"本地开发服务别走代理"). The covered ranges are pinned by that
/// design note and must not be extended or narrowed without an explicit, test-visible diff:
/// IPv4 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`;
/// IPv6 unique-local `fc00::/7`. `::1` is deliberately NOT covered here — that's
/// `LoopbackDetector`'s job, and the two detectors are called independently by the integrator.
@Suite("PrivateNetworkExclusion — pure host classification")
struct PrivateNetworkExclusionTests {

    // MARK: - 10.0.0.0/8

    @Test("the entire 10.0.0.0/8 block is private", arguments: [
        "10.0.0.0",
        "10.0.0.1",
        "10.20.30.40",
        "10.255.255.255"
    ])
    func tenSlashEightBlock(host: String) {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("addresses adjacent to 10.0.0.0/8 are not private", arguments: [
        "9.255.255.255",
        "11.0.0.0"
    ])
    func tenSlashEightAdjacent(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    // MARK: - 172.16.0.0/12 (not byte-aligned — high nibble of the second octet must be checked)

    @Test("the entire 172.16.0.0/12 block is private", arguments: [
        "172.16.0.0",
        "172.20.1.2",
        "172.31.255.255"
    ])
    func oneSeventyTwoSlashTwelveBlock(host: String) {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("addresses adjacent to 172.16.0.0/12 are not private", arguments: [
        "172.15.255.255",
        "172.32.0.0"
    ])
    func oneSeventyTwoSlashTwelveAdjacent(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    // MARK: - 192.168.0.0/16

    @Test("the entire 192.168.0.0/16 block is private", arguments: [
        "192.168.0.0",
        "192.168.1.1",
        "192.168.255.255"
    ])
    func oneNinetyTwoSlashSixteenBlock(host: String) {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("addresses adjacent to 192.168.0.0/16 are not private", arguments: [
        "192.167.255.255",
        "192.169.0.0"
    ])
    func oneNinetyTwoSlashSixteenAdjacent(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    // MARK: - 169.254.0.0/16 link-local

    @Test("the entire 169.254.0.0/16 link-local block is private", arguments: [
        "169.254.0.0",
        "169.254.1.1",
        "169.254.255.255"
    ])
    func linkLocalBlock(host: String) {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("addresses adjacent to 169.254.0.0/16 are not private", arguments: [
        "169.253.255.255",
        "169.255.0.0"
    ])
    func linkLocalAdjacent(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    // MARK: - IPv6 fc00::/7 unique-local

    @Test("the fc00::/7 unique-local block is private", arguments: [
        "fc00::",
        "fc00::1",
        "fd00::1",
        "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
    ])
    func uniqueLocalBlock(host: String) {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("addresses adjacent to fc00::/7 are not private", arguments: [
        "fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        "fe00::"
    ])
    func uniqueLocalAdjacent(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("bracketed IPv6 unique-local literal is recognized")
    func bracketedUniqueLocal() {
        #expect(PrivateNetworkExclusion.isPrivateNetwork(host: "[fd00::1]"))
    }

    // MARK: - Loopback is explicitly NOT this detector's job

    @Test("::1 and localhost are not private — that's LoopbackDetector's responsibility", arguments: [
        "::1",
        "localhost",
        "127.0.0.1"
    ])
    func loopbackIsNotOurJob(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    // MARK: - Public addresses and non-IP hostnames

    @Test("ordinary public addresses are not private", arguments: [
        "8.8.8.8",
        "1.1.1.1",
        "2001:db8::1",
        "fe80::1"
    ])
    func publicAddressesAreNotPrivate(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("non-IP hostnames are never classified as private, even if they look like one", arguments: [
        "example.com",
        "192.168.mycompany.com",
        "10.0.0.1.example.com"
    ])
    func hostnamesAreNotPrivate(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }

    @Test("malformed or empty input is not private", arguments: [
        "",
        "   ",
        "10",
        "10.0.0",
        "999.0.0.1",
        "not-a-host"
    ])
    func malformedInputIsNotPrivate(host: String) {
        #expect(!PrivateNetworkExclusion.isPrivateNetwork(host: host))
    }
}
