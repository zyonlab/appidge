import Darwin
import Foundation

/// Pure, stateless classification of whether a flow's destination host is loopback.
///
/// Called from the extension's flow-routing path (`Extension/ProxyExtensionProvider.swift`,
/// wired up by the integrator, not here) to force loopback traffic direct regardless of the
/// assigned `ProxyRule` — proxying 127.0.0.0/8 / ::1 / localhost would break local dev servers,
/// IPC over loopback sockets, etc. No state, no I/O: safe to call from any isolation domain.
public enum LoopbackDetector {

    /// - Parameter host: a bare hostname or IP literal (optionally bracketed for IPv6,
    ///   e.g. `"[::1]"`), with no port. Not a URL.
    public static func isLoopback(host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.caseInsensitiveCompare("localhost") == .orderedSame {
            return true
        }

        let candidate = stripBrackets(trimmed)
        return isIPv4Loopback(candidate) || isIPv6Loopback(candidate)
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// Whole 127.0.0.0/8 block is loopback, not just 127.0.0.1. `inet_pton` requires a
    /// strict dotted-quad (rejects shorthand like "127.1"), which is what we want here —
    /// flow hosts arrive fully qualified.
    private static func isIPv4Loopback(_ candidate: String) -> Bool {
        var addr = in_addr()
        let result = candidate.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return false }
        let firstOctet = withUnsafeBytes(of: addr.s_addr) { $0[0] }
        return firstOctet == 127
    }

    /// Only ::1 is the IPv6 loopback address. `inet_pton` normalizes any valid textual
    /// form (compressed or fully expanded) to the same 16 bytes, so this also matches
    /// "0:0:0:0:0:0:0:1" etc. for free.
    private static func isIPv6Loopback(_ candidate: String) -> Bool {
        var addr = in6_addr()
        let result = candidate.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}
