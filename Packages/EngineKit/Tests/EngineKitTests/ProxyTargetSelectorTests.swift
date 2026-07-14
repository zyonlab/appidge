import Testing
@testable import EngineKit

@Suite("ProxyTargetSelector — prefer hostname so the upstream proxy does DNS (no local leak)")
struct ProxyTargetSelectorTests {

    @Test("a real hostname is preferred and marked resolvedRemotely")
    func hostnamePreferred() {
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: "example.com", endpointHost: "93.184.216.34", port: 443
        )
        #expect(target == ProxyTarget(host: "example.com", port: 443, resolvedRemotely: true))
    }

    @Test("nil hostname falls back to the resolved endpoint IP, not resolved remotely")
    func nilHostnameFallsBackToIP() {
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: nil, endpointHost: "93.184.216.34", port: 443
        )
        #expect(target == ProxyTarget(host: "93.184.216.34", port: 443, resolvedRemotely: false))
    }

    @Test("empty / whitespace-only hostname is treated as absent")
    func blankHostnameFallsBack() {
        let empty = ProxyTargetSelector.selectTarget(remoteHostname: "", endpointHost: "10.0.0.1", port: 80)
        #expect(empty == ProxyTarget(host: "10.0.0.1", port: 80, resolvedRemotely: false))

        let spaces = ProxyTargetSelector.selectTarget(remoteHostname: "   ", endpointHost: "10.0.0.1", port: 80)
        #expect(spaces == ProxyTarget(host: "10.0.0.1", port: 80, resolvedRemotely: false))
    }

    @Test("an IPv4-literal hostname carries no DNS benefit: resolvedRemotely is false")
    func ipv4LiteralHostnameNotRemote() {
        // The hostname IS an IP, so there's no name for the proxy to resolve — we fall through
        // to the endpoint host and mark it not-remotely-resolved. Host value stays the IP.
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: "93.184.216.34", endpointHost: "93.184.216.34", port: 443
        )
        #expect(target.resolvedRemotely == false)
        #expect(target.host == "93.184.216.34")
        #expect(target.port == 443)
    }

    @Test("an IPv6-literal hostname (incl. bracketed) carries no DNS benefit")
    func ipv6LiteralHostnameNotRemote() {
        let plain = ProxyTargetSelector.selectTarget(
            remoteHostname: "2606:2800:220:1:248:1893:25c8:1946",
            endpointHost: "2606:2800:220:1:248:1893:25c8:1946", port: 443
        )
        #expect(plain.resolvedRemotely == false)

        let bracketed = ProxyTargetSelector.selectTarget(
            remoteHostname: "[::1]", endpointHost: "::1", port: 443
        )
        #expect(bracketed.resolvedRemotely == false)
    }

    @Test("whitespace around a real hostname is trimmed")
    func hostnameTrimmed() {
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: "  example.com  ", endpointHost: "1.2.3.4", port: 8443
        )
        #expect(target == ProxyTarget(host: "example.com", port: 8443, resolvedRemotely: true))
    }

    @Test("port is always preserved")
    func portPreserved() {
        for port: UInt16 in [1, 80, 443, 1080, 65535] {
            let target = ProxyTargetSelector.selectTarget(remoteHostname: "h.example", endpointHost: "1.1.1.1", port: port)
            #expect(target.port == port)
        }
    }
}
