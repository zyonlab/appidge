import Foundation

/// 授权状态机的 reduce —— 校验 + 生命周期（恢复 / 时钟推进 / 购买 / 持久化失败）这一组。
/// 激活/停用组见 `ReducerLicense.swift`。同样是纯函数，时间从 `now` 载荷进来。
extension Reducer {
    /// 校验 + 生命周期组。
    static func reduceLicenseValidation(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .licenseValidateRequested(let now):
            return licenseValidateRequested(now: now, state)
        case .licenseValidateSucceeded(let response, let now):
            return licenseValidateSucceeded(response: response, now: now, state)
        case .licenseValidateFailed(let failure, let now):
            return licenseValidateFailed(failure, now: now, state)
        case .licenseLoadRequested:
            return (state, [.loadPersistedLicense])
        case .licenseRestored(let info, let now):
            return licenseRestored(info, now: now, state)
        case .licenseClockTick(let now):
            return licenseClockTick(now: now, state)
        case .licensePurchaseRequested(let url):
            return (state, [.openCheckout(url: url)])
        case .licensePersistenceFailed(let operation):
            // 保存失败不锁当前会话；clear 失败时 handler 已先写 revoked tombstone，旧 active
            // 记录不会复活。两者都保留明确日志，便于诊断真实 Keychain 故障。
            return (state, [.log("license keychain \(operation.rawValue) failed")])
        default:
            return nil
        }
    }

    // MARK: 校验

    /// 请求例行/恢复校验：licensed/grace 乐观保留访问；expired 也允许请求，但记录 status
    /// 仍是 expired，因此 `.validating` 在途不会暂时打开付费 gate。revoked 永不自动解锁。
    static func licenseValidateRequested(now: Date, _ state: AppState) -> (AppState, [Effect]) {
        guard let info = state.license else { return (state, []) }
        switch state.licensePhase {
        case .licensed, .gracePeriod, .expired:
            break
        case .unlicensed, .activating, .validating, .deactivating, .revoked, .recoverableError,
             .trial, .trialExpired:
            return (state, [])
        }
        var state = state
        state.licensePhase = .validating
        return (state, [.validateLicense(licenseKey: info.licenseKey, instanceId: info.instanceId)])
    }

    /// 校验成功：更新记录并依 status（叠加本地到期判断）落 licensed/expired/revoked，持久化。
    static func licenseValidateSucceeded(response: LicenseResponse, now: Date, _ state: AppState) -> (AppState, [Effect]) {
        guard var info = state.license else { return (state, []) }
        info.status = response.status
        info.instanceId = response.instanceId
        info.expiresAt = response.expiresAt
        info.activations = response.activations
        info.activationLimit = response.activationLimit
        info.lastValidatedAt = response.validatedAt
        info.bumpHighWater(now)
        var state = state
        state.license = info
        state.licensePhase = phase(for: response.status, info: info, now: now)
        return (state, [.persistLicense(info)])
    }

    /// 校验失败：明确 revoked/expired 锁定；暂时性失败按宽限窗口判定——窗口内进 `.gracePeriod`
    /// （仍放行），已超窗口或已过订阅日期落 `.expired`。**绝不因上游抖动直接锁定**。
    static func licenseValidateFailed(
        _ failure: LicenseValidationFailure, now: Date, _ state: AppState
    ) -> (AppState, [Effect]) {
        guard var info = state.license else { return (state, []) }
        var state = state
        switch failure {
        case .revoked:
            info.status = .revoked
            state.license = info
            state.licensePhase = .revoked
        case .expired:
            info.status = .expired
            state.license = info
            state.licensePhase = .expired
        case .transient:
            info.bumpHighWater(now)
            state.license = info
            let exhausted = info.status == .expired
                || info.isExpiredByDate(now)
                || info.graceElapsed(now) > AppState.licenseGracePeriod
            state.licensePhase = exhausted ? .expired : .gracePeriod
        }
        return (state, [.persistLicense(info)])
    }

    // MARK: 生命周期

    /// 启动恢复：无记录 → `.unlicensed`；有记录 → 抬高水位后依状态与宽限窗口算初始相位。
    /// 终态（expired/revoked）把 status 写实并持久化，避免下次启动重算。
    static func licenseRestored(_ info: LicenseInfo?, now: Date, _ state: AppState) -> (AppState, [Effect]) {
        guard var info else {
            var state = state
            state.license = nil
            state.licensePhase = .unlicensed
            return (state, [])
        }
        info.bumpHighWater(now)
        let restored = restoredPhase(info, now: now)
        if restored == .expired { info.status = .expired }
        if restored == .revoked { info.status = .revoked }
        var state = state
        state.license = info
        state.licensePhase = restored
        let persist: [Effect] = (restored == .expired || restored == .revoked) ? [.persistLicense(info)] : []
        return (state, persist)
    }

    /// 恢复相位判定：明确终态优先，其次本地到期，再次宽限耗尽（离线/关机期间宽限已过）→ expired；
    /// 否则 licensed（可能已到校验周期，交给 App 调度器随后校验）。
    static func restoredPhase(_ info: LicenseInfo, now: Date) -> LicensePhase {
        if info.status == .revoked { return .revoked }
        if info.status == .expired || info.isExpiredByDate(now) { return .expired }
        if info.graceElapsed(now) > AppState.licenseGracePeriod { return .expired }
        return .licensed
    }

    /// 时钟推进：纯本地判定，不发网络。抬高水位（防回拨），licensed/gracePeriod 期间若本地到期
    /// 或宽限耗尽 → 落 `.expired` 并持久化；其余相位只更新内存高水位、不写盘（免每 tick 写 Keychain）。
    static func licenseClockTick(now: Date, _ state: AppState) -> (AppState, [Effect]) {
        // 无授权记录时，同一 tick 驱动试用倒计时（纯本地，不发网络）。
        guard var info = state.license else {
            switch state.licensePhase {
            case .trial, .trialExpired:
                return trialClockTick(now: now, state)
            default:
                return (state, [])
            }
        }
        info.bumpHighWater(now)
        var state = state
        state.license = info
        let expiredNow: Bool
        switch state.licensePhase {
        case .licensed:
            expiredNow = info.isExpiredByDate(now)
        case .gracePeriod:
            expiredNow = info.isExpiredByDate(now) || info.graceElapsed(now) > AppState.licenseGracePeriod
        default:
            expiredNow = false
        }
        if expiredNow {
            info.status = .expired
            state.license = info
            state.licensePhase = .expired
            return (state, [.persistLicense(info)])
        }
        return (state, [])
    }
}
