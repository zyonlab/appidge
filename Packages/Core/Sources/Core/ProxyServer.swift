public struct ProxyServerID: Sendable, Hashable, Codable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// 上游代理协议类型。P0 先只做 SOCKS5（最常用、握手最简单），HTTPS/HTTP 留作后续。
public enum ProxyKind: String, Sendable, Equatable, Codable, CaseIterable {
    case socks5
}

/// 一台上游代理服务器的配置。`username`/`password` 用于需要认证的 SOCKS5（RFC 1929）。
///
/// 安全注意：`password` 是明文字段，**不应**原样写进磁盘上的持久化 JSON——
/// 持久化层要么排除它、要么走 Keychain（见 PersistedConfiguration 的处理与 P1 遗留）。
public struct ProxyServer: Sendable, Equatable, Codable, Identifiable {
    public let id: ProxyServerID
    public var host: String
    public var port: UInt16
    public var kind: ProxyKind
    public var username: String?
    public var password: String?

    public init(
        id: ProxyServerID,
        host: String,
        port: UInt16,
        kind: ProxyKind = .socks5,
        username: String? = nil,
        password: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.kind = kind
        self.username = username
        self.password = password
    }
}
