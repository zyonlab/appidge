import Foundation
import Testing
@testable import Core

/// 试用状态机 reduce：首启记名 → .trial(daysLeft)，多锚点合并/自愈，倒计时 tick，到期落 .trialExpired，
/// 已授权时不进 trial，且任何 trial 相位都不产出网络/转发 effect（绝不黑洞）。全部纯函数、时间从载荷进。
@Suite("Reducer — 7-day trial state machine (pure, local anti-tamper)")
struct TrialReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    let day: TimeInterval = 86_400

    private func anchor(_ firstLaunch: Date, highWater: Date? = nil) -> TrialInfo {
        TrialInfo(firstLaunchAt: firstLaunch, clockHighWater: highWater)
    }

    // MARK: 首启记名

    @Test("first launch (no anchors) names now, opens trial with full duration, and persists BOTH anchors")
    func firstLaunchNamesIt() {
        let (next, effects) = Reducer.reduce(AppState(), .trialResolved(anchors: [], now: t0))
        #expect(next.licensePhase == .trial(daysLeft: 7))
        #expect(next.trial?.firstLaunchAt == t0)
        #expect(next.trial?.clockHighWater == t0)
        #expect(next.isLicenseActive)                                  // 试用期功能开放
        #expect(effects == [.persistTrialAnchors(next.trial!)])        // 记名落两锚点
    }

    @Test("first launch honors injected short duration (staging 1-day trial)")
    func firstLaunchShortDuration() {
        var state = AppState()
        state.trialConfig = TrialConfig(durationDays: 1)
        let (next, _) = Reducer.reduce(state, .trialResolved(anchors: [], now: t0))
        #expect(next.licensePhase == .trial(daysLeft: 1))
    }

    @Test("trialLoadRequested emits the loadTrialAnchors effect, no state change")
    func loadRequested() {
        let (next, effects) = Reducer.reduce(AppState(), .trialLoadRequested)
        #expect(next == AppState())
        #expect(effects == [.loadTrialAnchors])
    }

    // MARK: 后续启动 / 边界

    @Test("subsequent launch on day 6 → trial(1); day 7 → trialExpired")
    func subsequentLaunchBoundaries() {
        let a = anchor(t0)
        let (day6, _) = Reducer.reduce(AppState(), .trialResolved(anchors: [a], now: t0.addingTimeInterval(6 * day)))
        #expect(day6.licensePhase == .trial(daysLeft: 1))
        #expect(day6.isLicenseActive)

        let (day7, _) = Reducer.reduce(AppState(), .trialResolved(anchors: [a], now: t0.addingTimeInterval(7 * day)))
        #expect(day7.licensePhase == .trialExpired)
        #expect(!day7.isLicenseActive)                                 // 到期锁付费能力
    }

    @Test("resolve re-persists (self-heals) anchors so a deleted anchor is rewritten on next launch")
    func resolveSelfHeals() {
        let a = anchor(t0, highWater: t0.addingTimeInterval(2 * day))
        let (next, effects) = Reducer.reduce(AppState(), .trialResolved(anchors: [a], now: t0.addingTimeInterval(3 * day)))
        #expect(next.trial?.firstLaunchAt == t0)
        // 高水位被 now 抬到第 3 天，且回写两锚点（App 侧据此把缺失的那个锚点补回）
        #expect(next.trial?.clockHighWater == t0.addingTimeInterval(3 * day))
        #expect(effects == [.persistTrialAnchors(next.trial!)])
    }

    @Test("deleting one anchor still counts as started — two anchors take the EARLIER firstLaunchAt")
    func twoAnchorsTakeEarlier() {
        // 篡改者删了较早的锚点，留下较晚的想续期；只要任一存在即算已开始，且合并取较早。
        let earlier = anchor(t0)
        let later = anchor(t0.addingTimeInterval(4 * day))
        let (next, _) = Reducer.reduce(
            AppState(), .trialResolved(anchors: [later, earlier], now: t0.addingTimeInterval(6 * day))
        )
        #expect(next.trial?.firstLaunchAt == t0)                       // 取较早
        #expect(next.licensePhase == .trial(daysLeft: 1))              // 按较早锚点算，不给续期
    }

    @Test("clock-rollback across restart is frozen by merged high-water, not reset")
    func rollbackAcrossRestartFrozen() {
        // 上次会话高水位停在第 5 天；用户把系统时间调回首日再启动。
        let a = anchor(t0, highWater: t0.addingTimeInterval(5 * day))
        let (next, _) = Reducer.reduce(AppState(), .trialResolved(anchors: [a], now: t0.addingTimeInterval(1 * day)))
        #expect(next.licensePhase == .trial(daysLeft: 2))              // 冻结在第 5 天视角，不回血成 daysLeft 6/7
        #expect(next.trial?.clockHighWater == t0.addingTimeInterval(5 * day))
    }

    // MARK: 倒计时 tick + 到期落地

    @Test("clock tick counts the trial down and persists on the expiry transition")
    func tickCountsDownAndExpires() {
        // 从第 6 天（trial 1）起步
        var state = AppState()
        state.trial = anchor(t0, highWater: t0.addingTimeInterval(6 * day))
        state.licensePhase = .trial(daysLeft: 1)

        // tick 到第 6.5 天：仍 trial(1)，纯内存抬水位、不写盘
        let (mid, midEffects) = Reducer.reduce(state, .licenseClockTick(now: t0.addingTimeInterval(6 * day + 12 * 3600)))
        #expect(mid.licensePhase == .trial(daysLeft: 1))
        #expect(midEffects.isEmpty)

        // tick 越过到期日：落 .trialExpired 并持久化（锁定进度）
        let (expired, expiredEffects) = Reducer.reduce(state, .licenseClockTick(now: t0.addingTimeInterval(7 * day + 1)))
        #expect(expired.licensePhase == .trialExpired)
        #expect(!expired.isLicenseActive)
        #expect(expiredEffects == [.persistTrialAnchors(expired.trial!)])
    }

    @Test("clock tick while already trialExpired stays expired and does not re-persist")
    func tickWhileExpiredStable() {
        var state = AppState()
        state.trial = anchor(t0, highWater: t0.addingTimeInterval(8 * day))
        state.licensePhase = .trialExpired
        let (next, effects) = Reducer.reduce(state, .licenseClockTick(now: t0.addingTimeInterval(9 * day)))
        #expect(next.licensePhase == .trialExpired)
        #expect(effects.isEmpty)
    }

    // MARK: 已授权优先于试用

    @Test("resolve is a no-op when a license record exists (activated users never enter trial)")
    func licensedBeatsTrial() {
        var state = AppState()
        state.license = LicenseInfo(
            licenseKey: "K1", instanceId: "i1", status: .active,
            activations: 1, activationLimit: 3, lastValidatedAt: t0
        )
        state.licensePhase = .licensed
        let (next, effects) = Reducer.reduce(state, .trialResolved(anchors: [], now: t0))
        #expect(next.licensePhase == .licensed)                        // 不被 trial 覆盖
        #expect(next.trial == nil)
        #expect(effects.isEmpty)
    }

    @Test("resolve is a no-op when phase is not unlicensed (e.g. expired/revoked license)")
    func nonUnlicensedBeatsTrial() {
        for phase in [LicensePhase.expired, .revoked, .activating] {
            var state = AppState()
            state.licensePhase = phase
            let (next, effects) = Reducer.reduce(state, .trialResolved(anchors: [anchor(t0)], now: t0))
            #expect(next.licensePhase == phase)
            #expect(next.trial == nil)
            #expect(effects.isEmpty)
        }
    }

    // MARK: 解耦 / fail-open

    @Test("no trial action ever emits a networking/forwarding effect (never black-holes)")
    func trialNeverEmitsNetworkingEffect() {
        var expiring = AppState()
        expiring.trial = anchor(t0, highWater: t0.addingTimeInterval(6 * day))
        expiring.licensePhase = .trial(daysLeft: 1)
        let actions: [Action] = [
            .trialResolved(anchors: [], now: t0),
            .trialResolved(anchors: [anchor(t0)], now: t0.addingTimeInterval(7 * day)),
            .licenseClockTick(now: t0.addingTimeInterval(8 * day))
        ]
        for action in actions {
            let (_, effects) = Reducer.reduce(expiring, action)
            for effect in effects {
                switch effect {
                case .applyRuleSet, .applyProxyConfig, .applyRoutingMode, .applyUDPPolicy,
                     .applyPacketCapture, .applyProcessOriginExclusions:
                    Issue.record("trial action \(action) emitted networking effect \(effect)")
                default:
                    break
                }
            }
        }
    }

    @Test("resetState (profile switch) preserves trial phase, record and config (account-level)")
    func resetPreservesTrial() {
        var state = AppState()
        state.trialConfig = TrialConfig(durationDays: 14)
        state.trial = anchor(t0, highWater: t0.addingTimeInterval(day))
        state.licensePhase = .trial(daysLeft: 6)
        state.proxyServers[ProxyServerID("a")] = ProxyServer(id: ProxyServerID("a"), host: "h", port: 1)
        let (reset, _) = Reducer.reduce(state, .resetState)
        #expect(reset.licensePhase == .trial(daysLeft: 6))
        #expect(reset.trial == state.trial)
        #expect(reset.trialConfig == TrialConfig(durationDays: 14))
        #expect(reset.proxyServers.isEmpty)   // 档案态照常清掉
    }

    @Test("isLicenseActive: .trial → true, .trialExpired → false")
    func capabilityGating() {
        var t = AppState(); t.licensePhase = .trial(daysLeft: 3)
        #expect(t.isLicenseActive)
        var e = AppState(); e.licensePhase = .trialExpired
        #expect(!e.isLicenseActive)
    }

    @Test("trial phases are never validate-due (no server license to validate)")
    func trialNotValidateDue() {
        var t = AppState(); t.licensePhase = .trial(daysLeft: 3)
        #expect(!t.isValidateDue(now: t0.addingTimeInterval(30 * day)))
        var e = AppState(); e.licensePhase = .trialExpired
        #expect(!e.isValidateDue(now: t0.addingTimeInterval(30 * day)))
    }
}
