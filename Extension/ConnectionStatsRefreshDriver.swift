import Foundation
import EngineKit

/// 活跃连接字节回填的**驱动**(差分判定在 ``EngineKit/ConnectionStatsRefresher``,有测试;
/// 拆到同类型 extension 文件是本 target 压 file_length 的既有先例)。
///
/// 要解的观感矛盾:连接事件原本只在 opened(0 字节)/closed(最终字节)两个时刻投递,
/// 长连接(IM 长连、推送通道、UDP flow)存活期间活动栏的发送/接收列一直是 0,而速率列
/// (进程级,flowStats 每 ~500ms 实时推)在跳——「速率非零、字节纹丝不动」。
/// 扩展侧 `ConnectionContext` 计数器一直实时,这里周期性把有变化的快照重发出去
/// (同 id、phase 仍 .opened,app 侧按 id upsert 原地刷新,**不改 IPC 契约**)。
///
/// 事件量:每轮只发「字节有变化」的连接——静默长连接零事件,量级与真实吞吐挂钩而非连接数。
/// 迟到回填 vs 关闭事件的投递竞态由两层兜底:发前跳过已关闭 context;app 侧 reducer
/// 拒绝用 .opened 覆盖已 closed/failed 的行(Core 有测试)。
extension ProxyExtensionProvider {
    /// 回填节奏。2s:足够「看得到长连接在动」,又比 flowStats 的 500ms 粗一档,不放大事件洪流。
    private static let statsRefreshInterval: TimeInterval = 2.0

    /// 连接进入活跃注册表(emit .opened 之后调用)。
    func registerActiveContext(_ context: ConnectionContext) {
        configLock.withLock { storedActiveContexts[context.id] = context }
    }

    /// 连接结束:出注册表并清差分登记(emitClose / UDP 中继结束时调用)。
    func unregisterActiveContext(id: String) {
        configLock.withLock {
            storedActiveContexts.removeValue(forKey: id)
            storedStatsRefresher.forget(id: id)
        }
    }

    /// startProxy 后启动周期回填;重复调用先取消上一个(start→start 防御,同 transport 先例)。
    func startConnectionStatsRefresh() {
        storedStatsRefreshTask?.cancel()
        storedStatsRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.statsRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshActiveConnectionStats()
                // 配置对账心跳搭同一个 2s tick(30 tick ≈ 60s 上报一次指纹),不另起定时器体系。
                self?.tickConfigFingerprintHeartbeat()
            }
        }
    }

    /// stopProxy:停驱动并清空注册表(新会话从零开始)。
    func stopConnectionStatsRefresh() {
        storedStatsRefreshTask?.cancel()
        storedStatsRefreshTask = nil
        configLock.withLock {
            storedActiveContexts.removeAll()
            storedStatsRefresher = ConnectionStatsRefresher()
        }
    }

    /// 一轮回填:锁内取快照 + 差分判定,锁外发事件(deliver 是 async Task,不占锁)。
    func refreshActiveConnectionStats() {
        let due: [ConnectionContext] = configLock.withLock {
            let snapshots = storedActiveContexts.values.map { context -> ConnectionStatsRefresher.Snapshot in
                let bytes = context.snapshotBytes()
                return ConnectionStatsRefresher.Snapshot(id: context.id, up: bytes.up, down: bytes.down)
            }
            let ids = storedStatsRefresher.idsNeedingRefresh(current: snapshots)
            return ids.compactMap { storedActiveContexts[$0] }
        }
        for context in due where !context.isClosed {
            emitConnectionEvent(context, phase: .opened)
        }
    }

    // MARK: - 配置对账上报(第 2 层闭环的扩展侧;心跳挂本文件的 2s tick,故编排也放这里)

    /// 任一配置 apply 落地后调用:1s 防抖合并上报一次「已落地配置」的指纹。app 侧与期望指纹
    /// 比对,不一致即全量 resync——推送是 fire-and-forget,这条上报把静默分叉压缩到秒级可见。
    func scheduleConfigFingerprintReport() {
        let shouldSchedule = configLock.withLock {
            guard !storedFingerprintReportScheduled else { return false }
            storedFingerprintReportScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.reportConfigFingerprintNow()
        }
    }

    /// 立即计算并上报当前指纹(防抖到点 / 心跳)。transport 未接通时静默跳过(app 不在,无人对账;
    /// 重连后 app 的 resync 会触发 apply → 防抖上报,闭环自动恢复)。
    func reportConfigFingerprintNow() {
        let fingerprint = configLock.withLock {
            storedFingerprintReportScheduled = false
            return configFingerprintLocked()
        }
        guard let transport else { return }
        ExtDiag.log("configFingerprint report: \(fingerprint)")
        Task { await transport.deliver(.configFingerprintReported(fingerprint)) }
    }

    /// 心跳时机:每 30 个 2s tick(≈60s)上报一次。覆盖「推送丢了且之后再无任何 apply」的
    /// 静默分叉(2026-07-28 真机事故形态)——apply 防抖上报只能确认收到的,收不到的只有心跳能暴露。
    func tickConfigFingerprintHeartbeat() {
        let due = configLock.withLock {
            storedFingerprintHeartbeatTicks += 1
            guard storedFingerprintHeartbeatTicks >= 30 else { return false }
            storedFingerprintHeartbeatTicks = 0
            return true
        }
        if due { reportConfigFingerprintNow() }
    }
}
