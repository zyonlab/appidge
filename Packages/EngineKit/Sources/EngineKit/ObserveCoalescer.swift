import Foundation

/// 观测事件的**合并 + 节流**(纯值,给扩展的观测投递用)。
///
/// 背景:本地代理(xray/yunti)对上游建的短连接极高频(每秒上百条)。若每条都投一个带随机 id
/// 的连接事件,app 侧连接表就以同样速率**追加新行 + 全表重排**——扩展本身零开销(观测不接管
/// 数据),但 app 本体 CPU 被表格重排吃掉(真机 0.2.31 实测 ~13%)。
///
/// 两手一起治:
/// - **确定性 id**(`stableID`):同一 (进程 × 主机 × 端口) 复用同一 id → app 侧按 id upsert,
///   重复连接**原地更新那一行**(刷新时间戳),不再无限追加。语义上也更好:观测行表达的是
///   "这进程在和这些目的地通信",天然聚合(近似 Little Snitch 的按目的地归并)。
/// - **时间节流**(`shouldEmit`):同一目的地在 `interval` 内最多投一次事件——把事件速率从
///   "每连接一条"压到"每目的地每 interval 一条",与连接洪流解耦。
///
/// 无 I/O、`mutating` 纯函数,扩展在锁内持有一个实例调用。`prune` 防止 key 表无限增长。
public struct ObserveCoalescer: Sendable {
    private var lastEmit: [String: TimeInterval] = [:]
    private let interval: TimeInterval
    private let maxKeys: Int

    public init(interval: TimeInterval = 2.0, maxKeys: Int = 2000) {
        self.interval = interval
        self.maxKeys = maxKeys
    }

    /// 观测行的确定性 id:同一 (进程, 主机, 端口) 恒定 → app 侧 upsert 同一行。
    public static func stableID(processID: String, host: String, port: UInt16) -> String {
        "observe:\(processID)|\(host)|\(port)"
    }

    /// 这条观测该不该投:距上次投同一 `key` 已达 `interval` 才投(并记下本次时间)。
    /// `key` 用 ``stableID(processID:host:port:)`` 生成。
    public mutating func shouldEmit(key: String, now: TimeInterval) -> Bool {
        if let last = lastEmit[key], now - last < interval {
            return false
        }
        pruneIfNeeded(now: now)
        lastEmit[key] = now
        return true
    }

    /// key 表超过上限时,丢掉所有已过期(距今 ≥ interval,不可能再抑制新事件)的条目;
    /// 仍不够则清空(极端情况下的兜底,下一轮重新积累)。
    private mutating func pruneIfNeeded(now: TimeInterval) {
        guard lastEmit.count >= maxKeys else { return }
        lastEmit = lastEmit.filter { now - $0.value < interval }
        if lastEmit.count >= maxKeys {
            lastEmit.removeAll(keepingCapacity: true)
        }
    }
}
