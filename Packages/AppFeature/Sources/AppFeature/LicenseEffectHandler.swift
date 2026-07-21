import Foundation
import Core

/// App 层注入的授权客户端配置。`instanceName` 是隐私友好且稳定的安装标识（非邮箱/主机名/硬件序列号），
/// `appVersion` 供 facade 记录。reducer 不掺和这些，交由本 handler 在构造请求时填入。
public struct LicenseClientConfig: Sendable {
    public var instanceName: String
    public var appVersion: String

    public init(instanceName: String, appVersion: String) {
        self.instanceName = instanceName
        self.appVersion = appVersion
    }
}

/// 把 Core 的 license `Effect` 经**注入的协议**（``LicenseAPIClient`` / ``LicenseKeychainStore``
/// / ``LicenseClock``）执行，并把结果翻成后续 `Action` 回灌 store。所有副作用（网络、Keychain、
/// 打开链接）都在协议边界之外，便于在 AppFeature 用 mock 完整跑测；非 license effect 返回 nil，
/// 交给既有的转发/路由 effect 处理链。
///
/// **网络↔归类的翻译在这里**（不在 reducer）：facade 稳定错误码 → ``LicenseActivationFailure``/
/// ``LicenseValidationFailure``，其中暂时性（网络/5xx/限速/上游不可用/解码）一律走宽限、绝不锁定。
public struct LicenseEffectHandler: Sendable {
    private let apiClient: any LicenseAPIClient
    private let keychain: any LicenseKeychainStore
    private let clock: any LicenseClock
    private let config: LicenseClientConfig
    private let openCheckout: @Sendable (String) -> Void

    public init(
        apiClient: any LicenseAPIClient,
        keychain: any LicenseKeychainStore,
        clock: any LicenseClock,
        config: LicenseClientConfig,
        openCheckout: @escaping @Sendable (String) -> Void
    ) {
        self.apiClient = apiClient
        self.keychain = keychain
        self.clock = clock
        self.config = config
        self.openCheckout = openCheckout
    }

    /// 处理 license 相关 effect；非 license effect 返回 nil。
    public func handle(_ effect: Core.Effect) async -> Core.Action? {
        switch effect {
        case .activateLicense(let key):
            return await activate(licenseKey: key)
        case .validateLicense(let key, let instanceId):
            return await validate(licenseKey: key, instanceId: instanceId)
        case .deactivateLicense(let key, let instanceId):
            return await deactivate(licenseKey: key, instanceId: instanceId)
        case .persistLicense(let info):
            return await persist(info)
        case .loadPersistedLicense:
            return await load()
        case .openCheckout(let url):
            openCheckout(url)
            return nil
        default:
            return nil
        }
    }

    // MARK: 网络

    private func activate(licenseKey: String) async -> Core.Action {
        let request = ActivateRequest(licenseKey: licenseKey, instanceName: config.instanceName, appVersion: config.appVersion)
        switch await apiClient.activate(request) {
        case .success(let response):
            return .licenseActivateSucceeded(licenseKey: licenseKey, response: response, now: clock.now)
        case .failure(let error):
            return .licenseActivateFailed(Self.activationFailure(from: error))
        }
    }

    private func validate(licenseKey: String, instanceId: String) async -> Core.Action {
        let request = ValidateRequest(licenseKey: licenseKey, instanceId: instanceId, appVersion: config.appVersion)
        switch await apiClient.validate(request) {
        case .success(let response):
            return .licenseValidateSucceeded(response: response, now: clock.now)
        case .failure(let error):
            return .licenseValidateFailed(Self.validationFailure(from: error), now: clock.now)
        }
    }

    private func deactivate(licenseKey: String, instanceId: String) async -> Core.Action {
        switch await apiClient.deactivate(DeactivateRequest(licenseKey: licenseKey, instanceId: instanceId)) {
        case .success:
            return .licenseDeactivateSucceeded
        case .failure(let error):
            return .licenseDeactivateFailed(transient: Self.isTransient(error))
        }
    }

    // MARK: Keychain

    private func persist(_ info: LicenseInfo?) async -> Core.Action? {
        do {
            if let info { try await keychain.saveLicense(info) } else { try await keychain.clearLicense() }
            return nil
        } catch {
            // 写盘失败不致命：保持本会话已授权，不锁用户（reducer 对该 action 只记日志）。
            return .licensePersistenceFailed
        }
    }

    private func load() async -> Core.Action {
        // 读失败 → 视为无记录（安全降级为未激活），绝不因 Keychain 抖动误判。
        let info = (try? await keychain.loadLicense()) ?? nil
        return .licenseRestored(info, now: clock.now)
    }

    // MARK: 错误 → 归类映射

    static func activationFailure(from error: LicenseAPIError) -> LicenseActivationFailure {
        guard case .facade(let facade) = error else { return .transient }
        switch facade.error {
        case .activationLimit: return .activationLimit
        case .invalidLicense, .invalidRequest: return .invalidLicense
        case .expired: return .expired
        case .revoked: return .revoked
        case .rateLimited, .upstreamUnavailable, .internalError: return .transient
        }
    }

    static func validationFailure(from error: LicenseAPIError) -> LicenseValidationFailure {
        guard case .facade(let facade) = error else { return .transient }
        switch facade.error {
        case .revoked, .invalidLicense: return .revoked
        case .expired: return .expired
        case .activationLimit, .invalidRequest, .rateLimited, .upstreamUnavailable, .internalError: return .transient
        }
    }

    static func isTransient(_ error: LicenseAPIError) -> Bool {
        guard case .facade(let facade) = error else { return true } // transport/server/decoding
        switch facade.error {
        case .rateLimited, .upstreamUnavailable, .internalError: return true
        default: return false
        }
    }
}
