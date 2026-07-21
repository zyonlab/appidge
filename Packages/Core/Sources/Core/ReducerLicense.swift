import Foundation

/// 授权状态机的 reduce —— 激活 / 停用这一组，加共享构造/相位辅助。校验 + 生命周期组见
/// `ReducerLicenseValidation.swift`。全部是纯函数：时间从 action 载荷进来（`now`），reducer
/// 不读时钟；网络/Keychain 都以 Effect 外发、结果以 Action 回灌。
///
/// **稳定性铁律**：授权与网络接管彻底解耦——这里任何相位变化都不产生转发/路由 effect，
/// 授权服务失败绝不黑洞网络（见 CLAUDE.md §5.5）。
extension Reducer {
    /// 激活 / 停用组。分成两组只为把每个 switch 的分支数压在 cyclomatic_complexity 阈值内。
    static func reduceLicenseFlow(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .licenseActivateRequested(let key):
            return licenseActivateRequested(key, state)
        case .licenseActivateSucceeded(let key, let response, let now):
            return licenseActivateSucceeded(key: key, response: response, now: now, state)
        case .licenseActivateFailed(let failure):
            return licenseActivateFailed(failure, state)
        case .licenseDeactivateRequested:
            return licenseDeactivateRequested(state)
        case .licenseDeactivateSucceeded:
            return licenseDeactivateSucceeded(state)
        case .licenseDeactivateFailed(let transient):
            return licenseDeactivateFailed(transient: transient, state)
        default:
            return nil
        }
    }

    // MARK: 激活

    /// 请求激活：相位进 `.activating`，产出调 facade activate 的 effect（instanceName/appVersion
    /// 由 App 层注入）。key 先不落地，成功回灌时才写记录。
    static func licenseActivateRequested(_ key: String, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.licensePhase = .activating
        return (state, [.activateLicense(licenseKey: key)])
    }

    /// 激活成功：据服务端响应建记录、依 status 落相位，并持久化到 Keychain。
    static func licenseActivateSucceeded(
        key: String, response: LicenseResponse, now: Date, _ state: AppState
    ) -> (AppState, [Effect]) {
        let info = makeInfo(licenseKey: key, response: response, now: now)
        var state = state
        state.license = info
        state.licensePhase = phase(for: response.status, info: info, now: now)
        return (state, [.persistLicense(info)])
    }

    /// 激活失败：明确 revoked/expired 锁定；其余（限额/无效/暂时性）落可恢复错误，允许重试。
    /// 激活期没有既有授权，不涉及宽限。
    static func licenseActivateFailed(_ failure: LicenseActivationFailure, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        switch failure {
        case .revoked:
            state.licensePhase = .revoked
        case .expired:
            state.licensePhase = .expired
        case .activationLimit, .invalidLicense, .transient:
            state.licensePhase = .recoverableError(failure.rawValue)
        }
        return (state, [.log("license activate failed: \(failure.rawValue)")])
    }

    // MARK: 停用

    /// 请求停用：相位进 `.deactivating`（保留访问直到确认），产出调 facade deactivate 的 effect。
    static func licenseDeactivateRequested(_ state: AppState) -> (AppState, [Effect]) {
        guard let info = state.license else { return (state, []) }
        var state = state
        state.licensePhase = .deactivating
        return (state, [.deactivateLicense(licenseKey: info.licenseKey, instanceId: info.instanceId)])
    }

    /// 停用成功：清空本地记录、落 `.unlicensed`，清 Keychain。
    static func licenseDeactivateSucceeded(_ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.license = nil
        state.licensePhase = .unlicensed
        return (state, [.persistLicense(nil)])
    }

    /// 停用失败不误锁：仍有记录则回落 `.licensed`（保留访问、允许重试），否则 `.unlicensed`。
    static func licenseDeactivateFailed(transient: Bool, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.licensePhase = state.license == nil ? .unlicensed : .licensed
        return (state, [.log("license deactivate failed (transient: \(transient))")])
    }

    // MARK: 共享辅助

    /// 据服务端响应 + 回显 key + 本地 now 构造本地记录（高水位初值 = max(now, validatedAt)）。
    static func makeInfo(licenseKey: String, response: LicenseResponse, now: Date) -> LicenseInfo {
        LicenseInfo(
            licenseKey: licenseKey,
            instanceId: response.instanceId,
            status: response.status,
            expiresAt: response.expiresAt,
            activations: response.activations,
            activationLimit: response.activationLimit,
            lastValidatedAt: response.validatedAt,
            clockHighWater: max(now, response.validatedAt)
        )
    }

    /// 据稳定化 status（并叠加本地"是否已过订阅日期"判断）决定相位。
    static func phase(for status: LicenseStatus, info: LicenseInfo, now: Date) -> LicensePhase {
        switch status {
        case .revoked:
            return .revoked
        case .expired:
            return .expired
        case .active:
            return info.isExpiredByDate(now) ? .expired : .licensed
        }
    }
}
