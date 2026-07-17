import Darwin
import Foundation

/// 纯函数分类:目的地址是否**非单播**(组播 / 广播)。这类地址只在本地链路/本地网段有意义,
/// 代理/拦截它们既无意义也有害——mDNS(`224.0.0.251` / `ff02::fb`)、SSDP(`239.255.255.250`)、
/// DHCP 广播(`255.255.255.255`)都是系统/局域网发现的基础设施,被拦截会直接破坏系统功能。
///
/// 与 ``LoopbackDetector``(127/8、::1)、``PrivateNetworkExclusion``(RFC1918、链路本地、
/// ULA)正交,三者由集成方各自独立调用;那两个类型的覆盖范围被设计笔记钉死,所以组播/广播
/// 单独立一个类型,不去扩它们。
///
/// 覆盖:
/// - IPv4 组播 `224.0.0.0/4`(首字节 224...239)
/// - IPv4 受限广播 `255.255.255.255`
/// - IPv6 组播 `ff00::/8`
///
/// 无状态、零 I/O(不做 DNS 解析),任何隔离域可安全调用。主机名(非 IP 字面量)一律返回 false。
public enum NonUnicastExclusion {

    /// - Parameter host: 裸主机名或 IP 字面量(IPv6 可带方括号),不含端口,不是 URL。
    public static func isNonUnicast(host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidate = stripBrackets(trimmed)
        return isIPv4Multicast(candidate) || isIPv4LimitedBroadcast(candidate) || isIPv6Multicast(candidate)
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func ipv4Octets(_ candidate: String) -> [UInt8]? {
        var addr = in_addr()
        let result = candidate.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    private static func isIPv4Multicast(_ candidate: String) -> Bool {
        guard let octets = ipv4Octets(candidate) else { return false }
        // 224.0.0.0/4:首字节高 4 位为 1110(224...239)。
        return (octets[0] & 0xF0) == 0xE0
    }

    private static func isIPv4LimitedBroadcast(_ candidate: String) -> Bool {
        guard let octets = ipv4Octets(candidate) else { return false }
        return octets == [255, 255, 255, 255]
    }

    private static func isIPv6Multicast(_ candidate: String) -> Bool {
        var addr = in6_addr()
        let result = candidate.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return bytes[0] == 0xFF
    }
}
