import Foundation
import IPCContract

/// 转发/路由骨架：actor 化以隔离于主线程，按固定节奏批量上报计量，不是每包一个 IPC。
/// 安全兜底是架构约束：forward 异常时 fail-open（回直连重试），并上报 engineFailure。
public actor FlowRouter {
    private let transport: any Transport
    private let flushInterval: TimeInterval
    private var pending: [ProcessIdentifierDTO: (up: Int64, down: Int64)] = [:]
    private var windowStart: Date
    private var lastFlush: Date

    public private(set) var isHealthy: Bool = true

    public init(transport: any Transport, flushInterval: TimeInterval = 0.5, now: Date) {
        self.transport = transport
        self.flushInterval = flushInterval
        self.windowStart = now
        self.lastFlush = now
    }

    public func route(
        processID: ProcessIdentifierDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        rule: ProxyRuleDTO,
        now: Date
    ) async {
        do {
            try await transport.forward(processID: processID, bytesUp: bytesUp, bytesDown: bytesDown, via: rule)
        } catch {
            isHealthy = false
            try? await transport.forward(processID: processID, bytesUp: bytesUp, bytesDown: bytesDown, via: .direct)
            await transport.deliver(.engineFailure(reason: String(describing: error)))
        }
        accumulate(processID: processID, bytesUp: bytesUp, bytesDown: bytesDown)
        await flushIfDue(now: now)
    }

    /// 生产环境由外部周期性心跳驱动；测试直接调用以确定性地推进时间。
    public func tick(now: Date) async {
        await flushIfDue(now: now)
    }

    public func flush(now: Date) async {
        defer {
            windowStart = now
            lastFlush = now
        }
        guard !pending.isEmpty else { return }
        let entries = pending.map { id, delta in
            FlowStatsEntryDTO(processID: id, bytesUpDelta: delta.up, bytesDownDelta: delta.down)
        }
        pending.removeAll()
        let batch = FlowStatsBatchMessage(entries: entries, windowStart: windowStart, windowEnd: now)
        await transport.deliver(.flowStatsBatch(batch))
    }

    private func accumulate(processID: ProcessIdentifierDTO, bytesUp: Int64, bytesDown: Int64) {
        var entry = pending[processID] ?? (0, 0)
        entry.up += bytesUp
        entry.down += bytesDown
        pending[processID] = entry
    }

    private func flushIfDue(now: Date) async {
        guard now.timeIntervalSince(lastFlush) >= flushInterval else { return }
        await flush(now: now)
    }
}
