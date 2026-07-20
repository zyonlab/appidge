import Foundation

public enum ConnectionPhaseDTO: String, Sendable, Equatable, Codable {
    case opened
    case closed
    case failed
}

/// 单条连接的生命周期事件:extension → app。每条 TCP flow 在建立(`opened`)与
/// 结束(`closed`/`failed`)时各发一条,app 侧据此渲染"每连接一行"的日志
/// (对齐 Proxifier 的 Connections 视图:进程 / 目标 / 命中动作 / 所用代理 / 状态 / 字节)。
/// 上游路由模式的 wire 表示(供 app 侧本地化上游标签前缀)。`.single` 无前缀,其余带模式前缀。
public enum UpstreamKindDTO: String, Sendable, Equatable, Codable {
    case single, chain, failover, loadBalance
}

public struct ConnectionEventDTO: Sendable, Equatable, Codable {
    public let id: String
    public let processID: ProcessIdentifierDTO
    public let targetHost: String
    public let targetPort: UInt16
    public let rule: ProxyRuleDTO
    /// 实际所用上游代理协议;直连(或代理未配好而回落直连)时为 nil。
    public let proxyKind: ProxyKindDTO?
    /// 实际走的上游的**内容部分**(语言中立):单台/故障转移/负载均衡=`host:port`、代理链=`A → B`。
    /// 模式前缀不在这里(见 `upstreamKind`)——由 app 侧按当前语言本地化拼接。直连时为 nil。
    public let upstreamLabel: String?
    /// 上游的路由模式(用于 app 侧本地化「代理链/故障转移/负载均衡」前缀);单台 = `.single`(无前缀),
    /// 直连 = nil。Optional → 旧 wire 数据解码为 nil。
    public let upstreamKind: UpstreamKindDTO?
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
        processDisplayName: String? = nil,
        upstreamLabel: String? = nil,
        upstreamKind: UpstreamKindDTO? = nil
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
        self.upstreamLabel = upstreamLabel
        self.upstreamKind = upstreamKind
    }
}
