import Foundation

public enum ConnectionPhaseDTO: String, Sendable, Equatable, Codable {
    case opened
    case closed
    case failed
}

/// 单条连接的生命周期事件:extension → app。每条 TCP flow 在建立(`opened`)与
/// 结束(`closed`/`failed`)时各发一条,app 侧据此渲染"每连接一行"的日志
/// (对齐 Proxifier 的 Connections 视图:进程 / 目标 / 命中动作 / 所用代理 / 状态 / 字节)。
public struct ConnectionEventDTO: Sendable, Equatable, Codable {
    public let id: String
    public let processID: ProcessIdentifierDTO
    public let targetHost: String
    public let targetPort: UInt16
    public let rule: ProxyRuleDTO
    /// 实际所用上游代理协议;直连(或代理未配好而回落直连)时为 nil。
    public let proxyKind: ProxyKindDTO?
    public let phase: ConnectionPhaseDTO
    public let bytesUp: Int64
    public let bytesDown: Int64
    /// 连接建立时间(扩展在建立 flow 时打的时间戳,同一连接的后续事件沿用同一值)。
    public let openedAt: Date
    /// 人类可读的进程名,扩展侧从 `sourceAppAuditToken` 解出可执行文件路径后取最后一段路径
    /// 分量算出来的(比如 `/Users/admin/.yunti/xray-core/xray` → `xray`)——未签名命令行程序的
    /// `sourceAppSigningIdentifier` 往往是没有意义的 `a.out`,这个字段给 UI 一个更可读的兜底。
    /// 解不出可执行文件路径时为 nil,调用方回落到 `processID.value`。
    public let processDisplayName: String?

    public init(
        id: String,
        processID: ProcessIdentifierDTO,
        targetHost: String,
        targetPort: UInt16,
        rule: ProxyRuleDTO,
        proxyKind: ProxyKindDTO?,
        phase: ConnectionPhaseDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        openedAt: Date = Date(timeIntervalSince1970: 0),
        processDisplayName: String? = nil
    ) {
        self.id = id
        self.processID = processID
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.rule = rule
        self.proxyKind = proxyKind
        self.phase = phase
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.openedAt = openedAt
        self.processDisplayName = processDisplayName
    }
}
