public enum ProxyKindDTO: String, Sendable, Equatable, Codable {
    case socks5
    case httpConnect
}

/// 上游代理服务器的 wire-format。跟 Core.ProxyServer 是同一信息的传输孪生
/// （Core 零依赖，认不得 IPCContract 的类型，边界层负责两者互转）。
public struct ProxyServerDTO: Sendable, Equatable, Codable {
    public let id: String
    public let host: String
    public let port: UInt16
    public let kind: ProxyKindDTO
    public let username: String?
    public let password: String?

    public init(
        id: String,
        host: String,
        port: UInt16,
        kind: ProxyKindDTO,
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

/// 代理配置下发：app → extension。扩展据此知道有哪些上游、当前用哪个（`activeServerID`）。
public struct ProxyConfigMessage: Sendable, Equatable, Codable {
    public let servers: [ProxyServerDTO]
    public let activeServerID: String?

    public init(servers: [ProxyServerDTO], activeServerID: String?) {
        self.servers = servers
        self.activeServerID = activeServerID
    }

    /// 当前生效的上游（`activeServerID` 指向的那台），没有则 nil。
    public var activeServer: ProxyServerDTO? {
        guard let activeServerID else { return nil }
        return servers.first { $0.id == activeServerID }
    }
}
