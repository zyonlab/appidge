import Foundation

/// 活跃连接字节回填的**差分判定**(纯值,给扩展的周期回填驱动用)。
///
/// 背景:连接事件原本只在 `opened`(0 字节)和 `closed/failed`(最终字节)两个时刻投递——
/// 长连接(IM 长连、推送通道、UDP flow)存活的整个期间,活动栏的发送/接收列一直是 0,
/// 与进程级速率(flowStats 每 ~500ms 实时推)形成「速率在跳、字节纹丝不动」的矛盾观感。
/// 扩展侧 `ConnectionContext` 的计数器一直是实时的,缺的只是把快照周期性发出去。
///
/// 本类型决定「哪些连接该回填」:与上次发射的快照比,任一方向字节有变化才发——
/// 静默的长连接不产生任何事件,事件量与活跃连接数解耦、与真实吞吐挂钩。
/// 从未发过且仍是 0/0 的不发(`opened` 事件已经展示过 0/0)。
///
/// 无 I/O、`mutating` 纯函数,扩展在锁内持有一个实例调用(同 ``ObserveCoalescer`` 先例)。
/// 连接关闭时必须 ``forget(id:)``,防登记表随连接churn无限增长。
public struct ConnectionStatsRefresher: Sendable {
    /// 一条活跃连接的当前字节快照。
    public struct Snapshot: Sendable, Equatable {
        public let id: String
        public let up: Int64
        public let down: Int64

        public init(id: String, up: Int64, down: Int64) {
            self.id = id
            self.up = up
            self.down = down
        }
    }

    private var lastEmitted: [String: (up: Int64, down: Int64)] = [:]

    public init() {}

    /// 需要回填的连接 id(顺序与输入一致):字节自上次发射后有变化的。返回前登记新快照——
    /// 调用方**必须**对返回的每个 id 真的发事件,否则下轮不会再提醒。
    public mutating func idsNeedingRefresh(current: [Snapshot]) -> [String] {
        var due: [String] = []
        for snapshot in current {
            let changed: Bool
            if let last = lastEmitted[snapshot.id] {
                changed = last.up != snapshot.up || last.down != snapshot.down
            } else {
                changed = snapshot.up != 0 || snapshot.down != 0
            }
            if changed {
                lastEmitted[snapshot.id] = (snapshot.up, snapshot.down)
                due.append(snapshot.id)
            }
        }
        return due
    }

    /// 连接关闭后清掉登记(closed 事件自带最终字节,不归本机制管)。
    public mutating func forget(id: String) {
        lastEmitted.removeValue(forKey: id)
    }
}
