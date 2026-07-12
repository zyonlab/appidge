import Foundation

public struct FlowStatsEntryDTO: Sendable, Equatable, Codable {
    public let processID: ProcessIdentifierDTO
    public let bytesUpDelta: Int64
    public let bytesDownDelta: Int64

    public init(processID: ProcessIdentifierDTO, bytesUpDelta: Int64, bytesDownDelta: Int64) {
        self.processID = processID
        self.bytesUpDelta = bytesUpDelta
        self.bytesDownDelta = bytesDownDelta
    }
}

/// 流量批量上报：extension → app。按固定节奏聚合后一次性发出，不是每包一次。
public struct FlowStatsBatchMessage: Sendable, Equatable, Codable {
    public let entries: [FlowStatsEntryDTO]
    public let windowStart: Date
    public let windowEnd: Date

    public init(entries: [FlowStatsEntryDTO], windowStart: Date, windowEnd: Date) {
        self.entries = entries
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}
