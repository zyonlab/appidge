public struct ProcessID: Sendable, Hashable, Codable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public struct FlowStats: Sendable, Equatable, Codable {
    public var bytesUp: Int64
    public var bytesDown: Int64

    public init(bytesUp: Int64 = 0, bytesDown: Int64 = 0) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }

    public mutating func apply(_ delta: FlowStatsDelta) {
        bytesUp += delta.bytesUpDelta
        bytesDown += delta.bytesDownDelta
    }
}

public struct FlowStatsDelta: Sendable, Equatable, Codable {
    public var bytesUpDelta: Int64
    public var bytesDownDelta: Int64

    public init(bytesUpDelta: Int64, bytesDownDelta: Int64) {
        self.bytesUpDelta = bytesUpDelta
        self.bytesDownDelta = bytesDownDelta
    }
}

public enum ProxyRule: Sendable, Equatable, Codable {
    case direct
    case proxied
    /// 拦截:命中的流量直接拒绝、不建立任何连接(对齐 Proxifier 的 Block 动作)。
    case block
}

public struct MonitoredProcess: Sendable, Equatable, Codable, Identifiable {
    public let id: ProcessID
    public var displayName: String
    public var executablePath: String
    public var rule: ProxyRule
    public var stats: FlowStats
    /// 瞬时吞吐速率(字节/秒)。每个 flow-stats 批次由 reducer 用「本批增量 ÷ 本批真实时间窗」重算;
    /// 本批没数据的进程归 0(空闲即 0)。是运行时瞬时量,**不持久化**(见 `CodingKeys` 未列入),
    /// 每次启动从 0 起、由实时流量回填——与 CLAUDE.md「stats 里的实时流量每次启动重置」一致。
    public var rateUpPerSec: Double = 0
    public var rateDownPerSec: Double = 0

    /// 刻意不含 `rateUpPerSec`/`rateDownPerSec`:①它们是瞬时量不该落盘;②省得给已有 `config.json`
    /// 增字段导致旧数据解码缺键失败(合成 Codable 只认列出的键,未列的用属性默认值 0)。
    private enum CodingKeys: String, CodingKey {
        case id, displayName, executablePath, rule, stats
    }

    public init(
        id: ProcessID,
        displayName: String,
        executablePath: String,
        rule: ProxyRule = .direct,
        stats: FlowStats = FlowStats()
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.rule = rule
        self.stats = stats
    }
}
