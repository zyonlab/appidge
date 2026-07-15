import Darwin
import Foundation

/// Pure, stateless classification of whether a flow's destination host sits in a
/// private-network / link-local address block.
///
/// Called from the extension's flow-routing path (`Extension/ProxyExtensionProvider.swift`,
/// wired up by the integrator, not here) to force destinations on the local network direct
/// regardless of the assigned `ProxyRule` — proxying a LAN dev server or a printer at
/// `192.168.x.x` makes no sense and often can't even reach the proxy's upstream. This is the
/// explicit, non-coincidental complement to `LoopbackDetector`: loopback only covers
/// 127.0.0.0/8 / ::1, which says nothing about "local network but not this machine" (see
/// PROGRESS.md "防环设计定论" §"本地开发服务别走代理"). The two detectors are orthogonal and
/// are called independently by the integrator — this type intentionally does not import or
/// re-implement `LoopbackDetector`'s ::1 / 127.0.0.0/8 judgment.
///
/// The covered ranges are pinned by that design note and must not be extended or narrowed
/// without an explicit, test-visible diff:
/// - IPv4 private: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
/// - IPv4 link-local: `169.254.0.0/16`
/// - IPv6 unique-local: `fc00::/7`
///
/// No state, no I/O (no DNS resolution): safe to call from any isolation domain.
public enum PrivateNetworkExclusion {

    /// - Parameter host: a bare hostname or IP literal (optionally bracketed for IPv6,
    ///   e.g. `"[fd00::1]"`), with no port. Not a URL.
    public static func isPrivateNetwork(host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let candidate = stripBrackets(trimmed)
        return isIPv4Private(candidate) || isIPv6UniqueLocal(candidate)
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// `inet_pton` requires a strict dotted-quad (rejects shorthand like "10.1" and rejects
    /// non-numeric labels like "192.168.mycompany.com"), which is exactly what we want —
    /// flow hosts arrive fully qualified, and a hostname that merely looks IP-shaped must
    /// never be misread as one.
    private static func isIPv4Private(_ candidate: String) -> Bool {
        var addr = in_addr()
        let result = candidate.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return false }
        let octets = withUnsafeBytes(of: addr.s_addr) { Array($0) }

        let first = octets[0]
        let second = octets[1]

        if first == 10 { return true }
        // 172.16.0.0/12: the second octet's high 4 bits must be 0001 (16...31).
        if first == 172, (second & 0xF0) == 0x10 { return true }
        if first == 192, second == 168 { return true }
        // 169.254.0.0/16 link-local.
        if first == 169, second == 254 { return true }
        return false
    }

    /// fc00::/7: the top 7 bits of the address must be `1111110`, i.e. the first byte is
    /// `0xFC` or `0xFD` (the 8th bit — the low bit of the first byte — is unconstrained by
    /// a /7 mask, but for this block that bit only ever distinguishes 0xFC from 0xFD, both
    /// of which are in-range; masking the first byte with 0xFE isolates exactly those 7 bits).
    private static func isIPv6UniqueLocal(_ candidate: String) -> Bool {
        var addr = in6_addr()
        let result = candidate.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return (bytes[0] & 0xFE) == 0xFC
    }
}
