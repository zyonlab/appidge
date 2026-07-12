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
}

public struct MonitoredProcess: Sendable, Equatable, Codable {
    public let id: ProcessID
    public var displayName: String
    public var executablePath: String
    public var rule: ProxyRule
    public var stats: FlowStats

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
