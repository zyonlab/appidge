import Foundation

/// 纯本地 7 天试用状态机的 reduce —— 首启记名、多锚点合并/自愈、倒计时到期。全部纯函数：
/// 时间从 action 载荷（`now`）进来，reducer 不读时钟；读写锚点都以 Effect 外发、结果以 Action 回灌。
///
/// **稳定性铁律**（与授权组一致）：任何试用相位变化都不产出转发/路由 effect，试用到期只令
/// ``AppState/isLicenseActive`` 翻假，**绝不黑洞网络**（见 CLAUDE.md §5.5 fail-open）。
///
/// **防篡改边界（纯本地，诚实说明）**：靠「单调时钟高水位 + 双冗余锚点（取较早 firstLaunchAt、
/// 最高水位）+ 每次 resolve 自愈补写」挡住「调回系统时间续期」和「删单个锚点重置」。挡不住
/// root/逆向删光两处锚点、直接改锚点字节、或换新用户/新机——这类需服务端账号绑定，非本层目标。
extension Reducer {
    /// 试用组。未激活时才生效；`.licenseClockTick` 的试用分支复用 ``trialClockTick(now:_:)``。
    static func reduceTrial(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .trialLoadRequested:
            return (state, [.loadTrialAnchors])
        case .trialResolved(let anchors, let now):
            return trialResolved(anchors: anchors, now: now, state)
        default:
            return nil
        }
    }

    // MARK: 锚点合并（纯函数，测试可直接调用）

    /// 合并多份冗余锚点：取**较早**的 firstLaunchAt（篡改者删掉较早那份也无法续期）+ **最高**的
    /// clockHighWater（跨会话锁定回拨保护）。空数组 → nil（真·首次启动）。
    static func mergeTrialAnchors(_ anchors: [TrialInfo]) -> TrialInfo? {
        guard let earliest = anchors.map(\.firstLaunchAt).min() else { return nil }
        let highWater = anchors.compactMap(\.clockHighWater).max()
        return TrialInfo(firstLaunchAt: earliest, clockHighWater: highWater)
    }

    /// 据锚点 + 配置 + now 算出试用相位：剩余 >0 → `.trial(daysLeft:)`，否则 `.trialExpired`。
    static func trialPhase(_ trial: TrialInfo, config: TrialConfig, now: Date) -> LicensePhase {
        let daysLeft = trial.daysLeft(durationDays: config.durationDays, now: now)
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .trialExpired
    }

    // MARK: 解析（启动读回锚点后）

    /// 读回锚点后落相位。**已授权优先**：仅当从未激活（`license == nil` 且相位 `.unlicensed`）才进试用，
    /// 否则原样返回（licensed/grace/expired/revoked 等都不被试用覆盖）。
    /// 首启（无锚点）→ 记名 now、开满天数；后续 → 合并锚点、抬高水位、按天算相位。
    /// 两种路径都回写**全部**锚点：既锁定高水位，又把被删的那份自愈补回（"删一个不重置"的落地）。
    static func trialResolved(anchors: [TrialInfo], now: Date, _ state: AppState) -> (AppState, [Effect]) {
        guard state.license == nil, state.licensePhase == .unlicensed else {
            return (state, [])
        }
        var state = state
        if var merged = mergeTrialAnchors(anchors) {
            merged.bumpHighWater(now)
            state.trial = merged
            state.licensePhase = trialPhase(merged, config: state.trialConfig, now: now)
            return (state, [.persistTrialAnchors(merged)])
        }
        // 真·首次启动：记名并开满试用天数。
        let fresh = TrialInfo(firstLaunchAt: now, clockHighWater: now)
        state.trial = fresh
        state.licensePhase = .trial(daysLeft: state.trialConfig.durationDays)
        return (state, [.persistTrialAnchors(fresh)])
    }

    // MARK: 倒计时（由 `.licenseClockTick` 在无授权记录时委派进来）

    /// 试用倒计时：纯本地判定、不发网络。抬高水位（防回拨）后重算相位；仅在**首次**跨过到期
    /// （`.trial` → `.trialExpired`）时持久化一次（锁定进度），其余 tick 只更新内存高水位、不写盘。
    static func trialClockTick(now: Date, _ state: AppState) -> (AppState, [Effect]) {
        guard var trial = state.trial else { return (state, []) }
        let wasTrial: Bool = { if case .trial = state.licensePhase { return true } else { return false } }()
        trial.bumpHighWater(now)
        var state = state
        state.trial = trial
        let newPhase = trialPhase(trial, config: state.trialConfig, now: now)
        state.licensePhase = newPhase
        if wasTrial, newPhase == .trialExpired {
            return (state, [.persistTrialAnchors(trial)])
        }
        return (state, [])
    }
}
