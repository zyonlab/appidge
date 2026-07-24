import Foundation
import Testing
@testable import Core

/// TrialInfo 纯值语义：referenceNow / bumpHighWater 防回拨（复用 LicenseInfo 同一算法）+
/// daysLeft 的 ceil 边界。全部纯函数，用固定时刻驱动，不碰时钟/存储。
@Suite("TrialInfo — monotonic high-water anti-rollback & ceil day math")
struct TrialInfoTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    let day: TimeInterval = 86_400

    private func trial(_ firstLaunch: Date, highWater: Date? = nil) -> TrialInfo {
        TrialInfo(firstLaunchAt: firstLaunch, clockHighWater: highWater)
    }

    // MARK: referenceNow / bumpHighWater（与 LicenseInfo 同构：取 max，回拨只前进不回血）

    @Test("referenceNow = max(now, highWater, firstLaunchAt)")
    func referenceNowTakesMax() {
        let info = trial(t0, highWater: t0.addingTimeInterval(5 * day))
        // now 领先高水位 → 用 now
        #expect(info.referenceNow(t0.addingTimeInterval(6 * day)) == t0.addingTimeInterval(6 * day))
        // now 落后高水位（回拨）→ 冻结到高水位
        #expect(info.referenceNow(t0.addingTimeInterval(1 * day)) == t0.addingTimeInterval(5 * day))
        // now 早于 firstLaunchAt（极端回拨）→ 用 firstLaunchAt 兜底，elapsed 永不为负
        #expect(trial(t0).referenceNow(t0.addingTimeInterval(-day)) == t0)
    }

    @Test("bumpHighWater only advances, never retreats")
    func bumpAdvancesOnly() {
        var info = trial(t0, highWater: t0.addingTimeInterval(3 * day))
        info.bumpHighWater(t0.addingTimeInterval(1 * day)) // 回拨：不动
        #expect(info.clockHighWater == t0.addingTimeInterval(3 * day))
        info.bumpHighWater(t0.addingTimeInterval(4 * day)) // 前进：抬高
        #expect(info.clockHighWater == t0.addingTimeInterval(4 * day))
        var fresh = trial(t0, highWater: nil)
        fresh.bumpHighWater(t0.addingTimeInterval(day)) // nil → 初始化
        #expect(fresh.clockHighWater == t0.addingTimeInterval(day))
    }

    // MARK: daysLeft ceil 边界（durationDays=7，firstLaunch=t0）

    @Test("daysLeft ceil boundaries: day0=7, day5=2, day6=1, just-before-expiry=1, expiry=0")
    func daysLeftBoundaries() {
        let info = trial(t0)
        #expect(info.daysLeft(durationDays: 7, now: t0) == 7)                              // 首日
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(5 * day)) == 2)  // 第5天
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(6 * day)) == 1)  // 第6天（最后一天）
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(6 * day + 23 * 3600)) == 1) // 到期前一刻
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(7 * day)) == 0)  // 到期日
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(7 * day + 1)) == 0) // 已过期
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(30 * day)) == 0)    // 远超期
    }

    @Test("injected short duration (staging 1-day trial) collapses fast")
    func shortDuration() {
        let info = trial(t0)
        #expect(info.daysLeft(durationDays: 1, now: t0) == 1)
        #expect(info.daysLeft(durationDays: 1, now: t0.addingTimeInterval(day - 1)) == 1)
        #expect(info.daysLeft(durationDays: 1, now: t0.addingTimeInterval(day)) == 0)
    }

    @Test("clock rollback freezes progress: rewinding now cannot buy back days")
    func rollbackFreeze() {
        // 高水位停在第 5 天；把系统时间调回第 1 天。
        let info = trial(t0, highWater: t0.addingTimeInterval(5 * day))
        let rolledBack = info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(1 * day))
        let honest = info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(5 * day))
        #expect(rolledBack == honest)  // 回拨取更小值，不回血
        #expect(rolledBack == 2)
    }

    @Test("sub-day rollback within ceil granularity never yields an extra day")
    func subDayToleranceStable() {
        // 高水位在第 6 天 12h（remaining 12h → daysLeft 1）；回拨几小时仍在同一「天」桶里。
        let hw = t0.addingTimeInterval(6 * day + 12 * 3600)
        let info = trial(t0, highWater: hw)
        #expect(info.daysLeft(durationDays: 7, now: hw) == 1)
        #expect(info.daysLeft(durationDays: 7, now: t0.addingTimeInterval(6 * day + 6 * 3600)) == 1) // 回拨 6h → 仍 1
    }

    // MARK: 多锚点合并（取较早 firstLaunchAt + 最高 highWater）

    @Test("mergeTrialAnchors: earliest firstLaunchAt + highest highWater; empty → nil")
    func mergeAnchors() {
        #expect(Reducer.mergeTrialAnchors([]) == nil)
        let a = trial(t0.addingTimeInterval(2 * day), highWater: t0.addingTimeInterval(3 * day))
        let b = trial(t0, highWater: t0.addingTimeInterval(5 * day))
        let merged = Reducer.mergeTrialAnchors([a, b])
        #expect(merged?.firstLaunchAt == t0)                              // 取较早
        #expect(merged?.clockHighWater == t0.addingTimeInterval(5 * day)) // 取最高水位
        // 单锚点存在即可（删一个仍算已开始）
        #expect(Reducer.mergeTrialAnchors([a])?.firstLaunchAt == a.firstLaunchAt)
    }
}
