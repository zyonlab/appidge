import Testing
@testable import EngineKit

/// Pure classification, no actor/state involved — every case is a plain #expect against
/// LoopbackDetector.isLoopback(host:). This will be called from the extension's flow-routing
/// path to force loopback traffic direct regardless of the assigned rule (see CLAUDE.md §4).
@Suite("LoopbackDetector — pure host classification")
struct LoopbackDetectorTests {

    @Test("127.0.0.1 is loopback")
    func standardIPv4Loopback() {
        #expect(LoopbackDetector.isLoopback(host: "127.0.0.1"))
    }

    @Test("the entire 127.0.0.0/8 block is loopback", arguments: [
        "127.0.0.0",
        "127.0.0.1",
        "127.1.2.3",
        "127.255.255.254",
        "127.255.255.255"
    ])
    func wholeLoopbackBlock(host: String) {
        #expect(LoopbackDetector.isLoopback(host: host))
    }

    @Test("::1 is loopback")
    func ipv6Loopback() {
        #expect(LoopbackDetector.isLoopback(host: "::1"))
    }

    @Test("::1 written in fully expanded form is still recognized as loopback")
    func ipv6LoopbackExpandedForm() {
        #expect(LoopbackDetector.isLoopback(host: "0:0:0:0:0:0:0:1"))
    }

    @Test("bracketed IPv6 loopback literal is recognized")
    func bracketedIPv6Loopback() {
        #expect(LoopbackDetector.isLoopback(host: "[::1]"))
    }

    @Test("localhost is loopback, case-insensitively", arguments: ["localhost", "LOCALHOST", "Localhost"])
    func localhostHostname(host: String) {
        #expect(LoopbackDetector.isLoopback(host: host))
    }

    @Test("localhost surrounded by incidental whitespace is still loopback")
    func localhostWithWhitespace() {
        #expect(LoopbackDetector.isLoopback(host: "  localhost  "))
    }

    @Test("ordinary private and public addresses are not loopback", arguments: [
        "10.0.0.5",
        "192.168.1.1",
        "8.8.8.8",
        "2001:db8::1",
        "172.16.0.1"
    ])
    func nonLoopbackAddresses(host: String) {
        #expect(!LoopbackDetector.isLoopback(host: host))
    }

    @Test("addresses adjacent to the 127.0.0.0/8 block are not loopback", arguments: [
        "126.255.255.255",
        "128.0.0.0"
    ])
    func adjacentBlocksAreNotLoopback(host: String) {
        #expect(!LoopbackDetector.isLoopback(host: host))
    }

    @Test("IPv6 addresses other than ::1 are not loopback", arguments: [
        "::2",
        "fe80::1",
        "::ffff:127.0.0.1"
    ])
    func otherIPv6NotLoopback(host: String) {
        #expect(!LoopbackDetector.isLoopback(host: host))
    }

    @Test("malformed or empty input is not loopback", arguments: [
        "",
        "   ",
        "127",
        "127.0.0",
        "not-a-host",
        "127.0.0.1.5",
        "999.0.0.1"
    ])
    func malformedInputIsNotLoopback(host: String) {
        #expect(!LoopbackDetector.isLoopback(host: host))
    }

    @Test("hostnames that merely contain 'localhost' as a substring are not loopback")
    func substringIsNotEnough() {
        #expect(!LoopbackDetector.isLoopback(host: "notlocalhost.example.com"))
        #expect(!LoopbackDetector.isLoopback(host: "localhost.evil.com"))
    }
}
