import Testing
@testable import EngineKit

@Suite("ConnectionStatsRefresher — 活跃连接字节回填的差分判定")
struct ConnectionStatsRefresherTests {

    private func snap(_ id: String, up: Int64, down: Int64) -> ConnectionStatsRefresher.Snapshot {
        ConnectionStatsRefresher.Snapshot(id: id, up: up, down: down)
    }

    @Test("从未发过且仍是 0/0 的连接不回填(opened 事件已展示过 0/0)")
    func zeroBytesNeverEmittedIsQuiet() {
        var refresher = ConnectionStatsRefresher()
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 0, down: 0)]).isEmpty)
    }

    @Test("字节出现增长即回填;回填后未再变化则不重复发")
    func emitsOnGrowthThenQuietWhenUnchanged() {
        var refresher = ConnectionStatsRefresher()
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 100, down: 0)]) == ["a"])
        // 同快照再问:已登记,不重复发
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 100, down: 0)]).isEmpty)
        // 任一方向再增长 → 再发
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 100, down: 50)]) == ["a"])
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 100, down: 50)]).isEmpty)
    }

    @Test("多连接独立判定:只有变化的那些进回填清单,顺序与输入一致")
    func multipleConnectionsIndependent() {
        var refresher = ConnectionStatsRefresher()
        _ = refresher.idsNeedingRefresh(current: [snap("a", up: 10, down: 10), snap("b", up: 5, down: 0)])
        let due = refresher.idsNeedingRefresh(current: [
            snap("a", up: 10, down: 10),   // 没变
            snap("b", up: 5, down: 9),     // 变了
            snap("c", up: 0, down: 0),     // 新连接,还没字节
            snap("d", up: 1, down: 0)      // 新连接,已有字节
        ])
        #expect(due == ["b", "d"])
    }

    @Test("forget 清掉登记:同 id 若再次出现按「从未发过」判定(防关闭后登记表泄漏)")
    func forgetRemovesBookkeeping() {
        var refresher = ConnectionStatsRefresher()
        _ = refresher.idsNeedingRefresh(current: [snap("a", up: 10, down: 0)])
        refresher.forget(id: "a")
        // 登记被清:0/0 视为从未发过 → 不发;有字节 → 发
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 0, down: 0)]).isEmpty)
        #expect(refresher.idsNeedingRefresh(current: [snap("a", up: 10, down: 0)]) == ["a"])
    }
}
