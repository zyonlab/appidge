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
    /// 人类可读的进程名(见 `IPCContract.ConnectionEventDTO.processDisplayName` 的同款注释)——
    /// 未签名命令行程序的 `processID.value` 常是没有意义的 `a.out`,这个字段是更可读的兜底。
    /// 解不出时为 nil,调用方回落到 `processID.value`。
    public var processDisplayName: String?
    /// 实际走的上游可读标签(单台 host:port / 链 / 故障转移 / 负载均衡);直连或未知为 nil。
    /// 让日志/详情能看出「走了哪台、哪种路由模式」。旧持久化条目无此字段 → 解码为 nil。
    public var upstreamLabel: String?

    public init(
        id: String, processID: ProcessID, host: String, port: UInt16,
        rule: ProxyRule, proxyKind: ProxyKind?, phase: ConnectionPhase,
        bytesUp: Int64, bytesDown: Int64, openedAt: Date = Date(timeIntervalSince1970: 0),
        processDisplayName: String? = nil, upstreamLabel: String? = nil
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
        self.processDisplayName = processDisplayName
        self.upstreamLabel = upstreamLabel
    }

    /// 应用重启后从磁盘回灌历史连接日志时用:仍停在 `opened` 阶段的记录不可能真的还活着——
    /// 它所属的 flow 随上一次 app/扩展进程的生命周期一起没了,不会再收到 close 事件,永远
    /// 停在"活动"(绿色圆点)会误导用户以为它现在还在跑。回灌前统一改判成 `closed`;
    /// 已经是终态(`closed`/`failed`)的原样保留,不重复判定。
    public func normalizedForRestore() -> ConnectionLogEntry {
        guard phase == .opened else { return self }
        var copy = self
        copy.phase = .closed
        return copy
    }
}
