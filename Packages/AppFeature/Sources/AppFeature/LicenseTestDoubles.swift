import Foundation
import Core

/// 测试专用：固定时钟。handler 每次操作读一次 `now`，固定值足以覆盖其用例；
/// 随时间推进的宽限/回拨判定由 Core reducer 测试用 action 载荷驱动（更精确、更纯）。
public struct FixedLicenseClock: LicenseClock {
    public let now: Date
    public init(now: Date) { self.now = now }
}

/// 测试专用：内存 Keychain。可注入读/写/清失败，覆盖「Keychain 故障」用例。
public actor InMemoryLicenseKeychainStore: LicenseKeychainStore {
    public enum Failure: Error, Equatable { case save, load, clear }

    private var stored: LicenseInfo?
    private var failSave: Bool
    private var failLoad: Bool
    private var failClear: Bool

    public init(stored: LicenseInfo? = nil, failSave: Bool = false, failLoad: Bool = false, failClear: Bool = false) {
        self.stored = stored
        self.failSave = failSave
        self.failLoad = failLoad
        self.failClear = failClear
    }

    public func saveLicense(_ info: LicenseInfo) async throws {
        if failSave { throw Failure.save }
        stored = info
    }

    public func loadLicense() async throws -> LicenseInfo? {
        if failLoad { throw Failure.load }
        return stored
    }

    public func clearLicense() async throws {
        if failClear { throw Failure.clear }
        stored = nil
    }

    /// 测试断言用：当前存了什么。
    public func current() -> LicenseInfo? { stored }
}

/// 测试专用：可编程 license facade 客户端。逐次返回预置结果。
public actor MockLicenseAPIClient: LicenseAPIClient {
    public var activateResult: Result<LicenseResponse, LicenseAPIError>
    public var validateResult: Result<LicenseResponse, LicenseAPIError>
    public var deactivateResult: Result<DeactivateResponse, LicenseAPIError>

    private(set) var activateRequests: [ActivateRequest] = []
    private(set) var validateRequests: [ValidateRequest] = []
    private(set) var deactivateRequests: [DeactivateRequest] = []

    public init(
        activateResult: Result<LicenseResponse, LicenseAPIError> = .failure(.transport),
        validateResult: Result<LicenseResponse, LicenseAPIError> = .failure(.transport),
        deactivateResult: Result<DeactivateResponse, LicenseAPIError> = .failure(.transport)
    ) {
        self.activateResult = activateResult
        self.validateResult = validateResult
        self.deactivateResult = deactivateResult
    }

    public func activate(_ request: ActivateRequest) async -> Result<LicenseResponse, LicenseAPIError> {
        activateRequests.append(request)
        return activateResult
    }

    public func validate(_ request: ValidateRequest) async -> Result<LicenseResponse, LicenseAPIError> {
        validateRequests.append(request)
        return validateResult
    }

    public func deactivate(_ request: DeactivateRequest) async -> Result<DeactivateResponse, LicenseAPIError> {
        deactivateRequests.append(request)
        return deactivateResult
    }

    /// 测试断言用。
    public func recordedActivateRequests() -> [ActivateRequest] { activateRequests }
    public func recordedValidateRequests() -> [ValidateRequest] { validateRequests }
    public func recordedDeactivateRequests() -> [DeactivateRequest] { deactivateRequests }
}
