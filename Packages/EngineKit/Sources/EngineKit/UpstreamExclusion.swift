import Darwin
import Foundation

/// A configured upstream proxy endpoint, identified by host + port. `host` may be an IPv4
/// literal, an IPv6 literal (optionally bracketed), or a DNS hostname — matching normalizes
/// each form (see `UpstreamExclusion`). Value type, safe to share across isolation domains.
public struct UpstreamEndpoint: Sendable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Pure, stateless decision of whether a flow's destination targets one of the configured
/// upstream proxies — in which case the connection must bypass the proxy (force `.direct`)
/// so the extension→upstream hop can't itself be re-captured and re-proxied into an
/// infinite loop (see `docs/proxifier-feature-alignment.md` §6b).
///
/// This is the explicit, non-coincidental complement to `LoopbackDetector`. Loopback
/// exclusion only *happens* to protect the loop today because the default upstream is
/// `127.0.0.1:1080`; once the upstream is configurable (`Core.ProxyServer` /
/// `IPCContract.ProxyConfigMessage`) a non-loopback upstream (e.g. a corporate `10.x`
/// proxy) would not be covered by loopback at all. This guard covers it by matching the
/// destination against the applied set of upstream endpoints.
///
/// No state, no I/O (no DNS resolution): safe to call from any isolation domain. Because it
/// never resolves names, host matching is purely textual/address-normalized — a hostname
/// upstream is only matched by a destination expressed as that same hostname, not by its
/// resolved IP (the integrator must feed destinations in the family the upstream is
/// configured with; see the PR's integration note).
public enum UpstreamExclusion {

    /// True if `destinationHost`:`destinationPort` matches any configured upstream, meaning
    /// this connection must be forced direct to avoid a forwarding loop.
    ///
    /// - Parameters:
    ///   - destinationHost: a bare hostname or IP literal (optionally bracketed for IPv6,
    ///     e.g. `"[::1]"`), with no port. Not a URL.
    ///   - destinationPort: the connection's destination port.
    ///   - upstreams: the set of currently configured upstream endpoints. Empty → always
    ///     false.
    public static func isUpstream(
        host destinationHost: String,
        port destinationPort: UInt16,
        upstreams: Set<UpstreamEndpoint>
    ) -> Bool {
        // Port is the cheap discriminator; only normalize the host when the port matches.
        upstreams.contains { $0.port == destinationPort && sameHost($0.host, destinationHost) }
    }

    /// Whether two host strings denote the same host, comparing on normalized address bytes
    /// for IP literals and case-insensitively for DNS hostnames.
    private static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)

        if let leftV4 = ipv4Bytes(left) {
            // lhs is IPv4: equal only to the same IPv4. A different family — including an
            // IPv4-mapped IPv6 form such as ::ffff:127.0.0.1 — is deliberately NOT equal,
            // mirroring LoopbackDetector's choice to keep ::ffff:127.0.0.1 out of loopback.
            guard let rightV4 = ipv4Bytes(right) else { return false }
            return leftV4 == rightV4
        }

        if let leftV6 = ipv6Bytes(left) {
            guard let rightV6 = ipv6Bytes(right) else { return false }
            return leftV6 == rightV6
        }

        // Neither side is an IP literal → compare as DNS hostnames, case-insensitively.
        // (If exactly one side were an IP literal, a guard above already returned false,
        // and an IP string never equals a hostname string here anyway.)
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    /// Trim incidental whitespace, then strip a single pair of IPv6 brackets so `[::1]`
    /// normalizes to `::1` before `inet_pton` (which does not accept brackets).
    private static func normalize(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripBrackets(trimmed)
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// The 4 network bytes of a strict dotted-quad IPv4 literal, or nil if not IPv4.
    /// `inet_pton` normalizes non-canonical forms (e.g. leading zeros `127.000.000.001`)
    /// to the same bytes, which is exactly the equality we want.
    private static func ipv4Bytes(_ candidate: String) -> [UInt8]? {
        var addr = in_addr()
        let result = candidate.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    /// The 16 network bytes of an IPv6 literal, or nil if not IPv6. `inet_pton` normalizes
    /// any valid textual form (compressed or fully expanded) to the same bytes.
    private static func ipv6Bytes(_ candidate: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = candidate.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }
}
