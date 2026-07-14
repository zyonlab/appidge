import Foundation

public enum ConnectionPhase: Sendable, Equatable, Codable {
    case opened
    case closed
    case failed
}

/// 连接日志里的一行:一条 TCP 连接的身份 + 目标 + 决策 + 当前状态/字节。按连接 id 去重更新
/// (opened → closed/failed 更新同一行,不新增)。是扩展 `ConnectionEventDTO` 在 Core 侧的孪生。
public struct ConnectionLogEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let processID: ProcessID
    public let host: String
    public let port: UInt16
    public let rule: ProxyRule
    public let proxyKind: ProxyKind?
    public var phase: ConnectionPhase
    public var bytesUp: Int64
    public var bytesDown: Int64
    /// 连接建立时间(扩展打的时间戳);连接列表按它排序 + 显示时间列。旧持久化条目没有此字段,
    /// 解码时回落到 epoch 0(ConnectionLogFileStore 会跳过解不了的行,不影响新条目)。
    public var openedAt: Date

    public init(
        id: String, processID: ProcessID, host: String, port: UInt16,
        rule: ProxyRule, proxyKind: ProxyKind?, phase: ConnectionPhase,
        bytesUp: Int64, bytesDown: Int64, openedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.processID = processID
        self.host = host
        self.port = port
        self.rule = rule
        self.proxyKind = proxyKind
        self.phase = phase
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.openedAt = openedAt
    }
}
