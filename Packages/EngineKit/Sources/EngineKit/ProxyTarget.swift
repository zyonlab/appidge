import Darwin
import Foundation

/// 交给上游代理去 CONNECT 的目标地址。`resolvedRemotely == true` 表示我们把一个**主机名**
/// 交给了代理（由代理解析 DNS，本地不泄漏查询）；false 表示只有 IP 可用（本地已解析过）。
public struct ProxyTarget: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let resolvedRemotely: Bool

    public init(host: String, port: UInt16, resolvedRemotely: Bool) {
        self.host = host
        self.port = port
        self.resolvedRemotely = resolvedRemotely
    }
}

/// 为"走上游代理"的连接选择 CONNECT 目标，尽量让 DNS 发生在代理端（DNS-over-proxy，
/// 堵住本地明文 DNS 泄漏）。
///
/// 扩展在 flow 层同时能拿到原始主机名（`NEAppProxyFlow.remoteHostname`，可能为空）和已解析的
/// endpoint（host 常是 IP 字面量）。把**主机名**交给代理 → 代理远程解析（不泄漏）；只有 IP 时
/// 退回传 IP。纯函数，无 I/O、无状态：扩展读 `remoteHostname` 后调用它，那段 glue 由集成方接。
public enum ProxyTargetSelector {

    /// - Parameters:
    ///   - remoteHostname: 原始主机名，可能为 nil / 空白 / 本身就是 IP 字面量。
    ///   - endpointHost: 已解析 endpoint 的 host（通常是 IP 字面量），兜底用。
    ///   - port: 目标端口，原样保留。
    /// - Returns: 优先用非空、非 IP 字面量的主机名（`resolvedRemotely = true`）；否则退回
    ///   `endpointHost`（`resolvedRemotely = false`）。IP 字面量当作"没有名字可解析"处理。
    public static func selectTarget(remoteHostname: String?, endpointHost: String, port: UInt16) -> ProxyTarget {
        let trimmed = remoteHostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, !isIPLiteral(trimmed) {
            return ProxyTarget(host: trimmed, port: port, resolvedRemotely: true)
        }
        return ProxyTarget(host: endpointHost, port: port, resolvedRemotely: false)
    }

    /// 用 `inet_pton` 严判 IPv4/IPv6 字面量（同 ``LoopbackDetector`` 的手法），带方括号的
    /// IPv6（`[::1]`）先脱括号再判。
    private static func isIPLiteral(_ host: String) -> Bool {
        let candidate = stripBrackets(host)
        var v4 = in_addr()
        if candidate.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if candidate.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }
}
