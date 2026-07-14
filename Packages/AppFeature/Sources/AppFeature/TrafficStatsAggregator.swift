import Core

/// 纯全局流量计算：给定当前每进程统计，算出合计、Top-N 排行，以及（由两次快照 + 经过秒数）
/// 得出的上/下行吞吐速率。零副作用、零时钟读取（时间由参数传入），全部确定性可单测。
///
/// 这是未来「菜单栏全局吞吐 / 全局统计面板」的纯计算地基；接线（定时采样、驱动 UI）由协调者后续做。
public enum TrafficStatsAggregator {

    /// 一段窗口内的上/下行吞吐速率（字节每秒）。纯值类型。
    public struct ThroughputRate: Sendable, Equatable {
        public let bytesUpPerSecond: Double
        public let bytesDownPerSecond: Double

        public init(bytesUpPerSecond: Double, bytesDownPerSecond: Double) {
            self.bytesUpPerSecond = bytesUpPerSecond
            self.bytesDownPerSecond = bytesDownPerSecond
        }
    }

    /// 跨所有进程累加上/下行字节；空输入 → (0, 0)。
    public static func totals(_ processes: [Core.MonitoredProcess]) -> (up: Int64, down: Int64) {
        processes.reduce(into: (up: Int64(0), down: Int64(0))) { acc, process in
            acc.up += process.stats.bytesUp
            acc.down += process.stats.bytesDown
        }
    }

    /// 总吞吐（上+下）最大的前 `limit` 个进程，降序；吞吐相等时按 `id.value` 升序打破平局，
    /// 保证结果确定。`limit <= 0` 或空输入 → []；`limit` 大于进程数则返回全部（仍已排序）。
    public static func topByThroughput(
        _ processes: [Core.MonitoredProcess],
        limit: Int
    ) -> [Core.MonitoredProcess] {
        guard limit > 0 else { return [] }
        let sorted = processes.sorted { lhs, rhs in
            let lhsThroughput = lhs.stats.bytesUp + lhs.stats.bytesDown
            let rhsThroughput = rhs.stats.bytesUp + rhs.stats.bytesDown
            if lhsThroughput != rhsThroughput {
                return lhsThroughput > rhsThroughput // 吞吐降序
            }
            return lhs.id.value < rhs.id.value // 平局：id 升序，确定性
        }
        return Array(sorted.prefix(limit))
    }

    /// 由两次累计快照与经过秒数算出速率：`(current - previous) / elapsed`。
    /// - `elapsedSeconds <= 0` → 全 0（不除零）。
    /// - 差值按轴独立钳到 0：容忍计数器重置 / 进程消失（current < previous），绝不出负数。
    public static func rate(
        previous: (up: Int64, down: Int64),
        current: (up: Int64, down: Int64),
        elapsedSeconds: Double
    ) -> ThroughputRate {
        guard elapsedSeconds > 0 else {
            return ThroughputRate(bytesUpPerSecond: 0, bytesDownPerSecond: 0)
        }
        let upDelta = max(0, current.up - previous.up)
        let downDelta = max(0, current.down - previous.down)
        return ThroughputRate(
            bytesUpPerSecond: Double(upDelta) / elapsedSeconds,
            bytesDownPerSecond: Double(downDelta) / elapsedSeconds
        )
    }
}
