import Testing
import Core
@testable import AppFeature

@Suite("TrafficStatsAggregator — 纯全局流量计算（合计 / Top-N / 速率）")
struct TrafficStatsAggregatorTests {

    /// 造一个只关心 id 与上下行字节的进程，其余字段取默认。
    private func proc(_ id: String, up: Int64, down: Int64) -> Core.MonitoredProcess {
        Core.MonitoredProcess(
            id: Core.ProcessID(id),
            displayName: id,
            executablePath: "/bin/\(id)",
            stats: Core.FlowStats(bytesUp: up, bytesDown: down)
        )
    }

    // MARK: - totals

    @Test("合计：跨进程累加上下行")
    func totalsSumsAllProcesses() {
        let processes = [
            proc("a", up: 10, down: 100),
            proc("b", up: 20, down: 200),
            proc("c", up: 3, down: 30)
        ]
        let result = TrafficStatsAggregator.totals(processes)
        #expect(result.up == 33)
        #expect(result.down == 330)
    }

    @Test("合计：空输入 → (0,0)")
    func totalsEmptyIsZero() {
        let result = TrafficStatsAggregator.totals([])
        #expect(result.up == 0)
        #expect(result.down == 0)
    }

    // MARK: - topByThroughput

    @Test("Top-N：按总吞吐（上+下）降序")
    func topByThroughputOrdersDescending() {
        let processes = [
            proc("low", up: 1, down: 1),      // 2
            proc("high", up: 100, down: 100), // 200
            proc("mid", up: 10, down: 40)     // 50
        ]
        let top = TrafficStatsAggregator.topByThroughput(processes, limit: 3)
        #expect(top.map { $0.id.value } == ["high", "mid", "low"])
    }

    @Test("Top-N：吞吐相等时按 id.value 升序打破平局（确定性）")
    func topByThroughputBreaksTiesByID() {
        let processes = [
            proc("b", up: 50, down: 50), // 100
            proc("a", up: 40, down: 60), // 100
            proc("c", up: 30, down: 70)  // 100
        ]
        let top = TrafficStatsAggregator.topByThroughput(processes, limit: 3)
        #expect(top.map { $0.id.value } == ["a", "b", "c"])
    }

    @Test("Top-N：只取前 limit 个")
    func topByThroughputRespectsLimit() {
        let processes = [
            proc("a", up: 1, down: 1),     // 2
            proc("b", up: 10, down: 10),   // 20
            proc("c", up: 100, down: 100), // 200
            proc("d", up: 5, down: 5)      // 10
        ]
        let top = TrafficStatsAggregator.topByThroughput(processes, limit: 2)
        #expect(top.map { $0.id.value } == ["c", "b"])
    }

    @Test("Top-N：limit 大于进程数 → 返回全部（仍已排序）")
    func topByThroughputLimitLargerThanCount() {
        let processes = [
            proc("a", up: 1, down: 1),   // 2
            proc("b", up: 9, down: 9)    // 18
        ]
        let top = TrafficStatsAggregator.topByThroughput(processes, limit: 10)
        #expect(top.map { $0.id.value } == ["b", "a"])
    }

    @Test("Top-N：limit <= 0 → 空", arguments: [0, -1, -100])
    func topByThroughputNonPositiveLimit(limit: Int) {
        let processes = [proc("a", up: 1, down: 1), proc("b", up: 2, down: 2)]
        #expect(TrafficStatsAggregator.topByThroughput(processes, limit: limit).isEmpty)
    }

    @Test("Top-N：空输入 → 空")
    func topByThroughputEmptyInput() {
        #expect(TrafficStatsAggregator.topByThroughput([], limit: 5).isEmpty)
    }

    // MARK: - rate

    @Test("速率：(current - previous) / elapsed")
    func rateIsDeltaOverElapsed() {
        let rate = TrafficStatsAggregator.rate(
            previous: (up: 100, down: 1000),
            current: (up: 300, down: 3000),
            elapsedSeconds: 2
        )
        #expect(rate.bytesUpPerSecond == 100)   // (300-100)/2
        #expect(rate.bytesDownPerSecond == 1000) // (3000-1000)/2
    }

    @Test("速率：elapsedSeconds == 0 → 全 0（不除零）")
    func rateZeroElapsedIsZero() {
        let rate = TrafficStatsAggregator.rate(
            previous: (up: 0, down: 0),
            current: (up: 500, down: 500),
            elapsedSeconds: 0
        )
        #expect(rate.bytesUpPerSecond == 0)
        #expect(rate.bytesDownPerSecond == 0)
    }

    @Test("速率：elapsedSeconds < 0 → 全 0")
    func rateNegativeElapsedIsZero() {
        let rate = TrafficStatsAggregator.rate(
            previous: (up: 0, down: 0),
            current: (up: 500, down: 500),
            elapsedSeconds: -3
        )
        #expect(rate.bytesUpPerSecond == 0)
        #expect(rate.bytesDownPerSecond == 0)
    }

    @Test("速率：current < previous（计数器重置/进程消失）→ 钳到 0，不出负数")
    func rateClampsCounterReset() {
        let rate = TrafficStatsAggregator.rate(
            previous: (up: 1000, down: 5000),
            current: (up: 10, down: 20),
            elapsedSeconds: 1
        )
        #expect(rate.bytesUpPerSecond == 0)
        #expect(rate.bytesDownPerSecond == 0)
    }

    @Test("速率：只有下行重置时，上行仍正常计算")
    func rateClampsPerAxisIndependently() {
        let rate = TrafficStatsAggregator.rate(
            previous: (up: 100, down: 5000),
            current: (up: 300, down: 20), // up 增长，down 重置
            elapsedSeconds: 2
        )
        #expect(rate.bytesUpPerSecond == 100) // (300-100)/2
        #expect(rate.bytesDownPerSecond == 0) // 钳到 0
    }

    @Test("ThroughputRate 值语义相等")
    func throughputRateEquatable() {
        #expect(
            TrafficStatsAggregator.ThroughputRate(bytesUpPerSecond: 1.5, bytesDownPerSecond: 2.5)
                == TrafficStatsAggregator.ThroughputRate(bytesUpPerSecond: 1.5, bytesDownPerSecond: 2.5)
        )
    }

    // MARK: - 端到端：两次快照的真实多进程场景

    @Test("真实场景：两次快照的合计差 → 速率")
    func realisticSnapshotPairYieldsRate() {
        let snapshot1 = [
            proc("chrome", up: 1_000, down: 20_000),
            proc("mail", up: 500, down: 4_000),
            proc("ssh", up: 200, down: 300)
        ]
        let snapshot2 = [
            proc("chrome", up: 3_000, down: 60_000),
            proc("mail", up: 900, down: 8_000),
            proc("ssh", up: 200, down: 300) // 无变化
        ]

        let before = TrafficStatsAggregator.totals(snapshot1) // (1700, 24300)
        let after = TrafficStatsAggregator.totals(snapshot2)   // (4100, 68300)
        #expect(before.up == 1_700)
        #expect(before.down == 24_300)
        #expect(after.up == 4_100)
        #expect(after.down == 68_300)

        // 5 秒窗口：up 差 2400 → 480/s，down 差 44000 → 8800/s
        let rate = TrafficStatsAggregator.rate(previous: before, current: after, elapsedSeconds: 5)
        #expect(rate.bytesUpPerSecond == 480)
        #expect(rate.bytesDownPerSecond == 8_800)

        // Top-2 应是 chrome 后跟 mail
        let top = TrafficStatsAggregator.topByThroughput(snapshot2, limit: 2)
        #expect(top.map { $0.id.value } == ["chrome", "mail"])
    }
}
