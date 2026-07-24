import Foundation

// MARK: - 稳定化状态（与 contracts/licensing.openapi.yaml 的 LicenseStatus 对齐）

/// 服务端稳定化后的授权状态（不透传 Polar 原始枚举）。对齐 facade 契约的 `LicenseStatus`。
public enum LicenseStatus: String, Sendable, Equatable, Codable {
    case active
    case expired
    case revoked
}

// MARK: - 客户端状态机相位

/// macOS 客户端授权状态机的相位（见 CLAUDE.md §5.5）。
/// 授权能力仅在 ``AppState/isLicenseActive`` 为真时开放；只有 **明确的** `revoked`/`expired`
/// 才锁定付费能力——Worker/Polar 暂时不可用一律进 `gracePeriod`，绝不因上游抖动黑掉能力。
public enum LicensePhase: Sendable, Equatable {
    /// 未激活（从未激活 / 已停用 / 读不到本地记录）。
    case unlicensed
    /// 首次激活请求在途。
    case activating
    /// 已授权且在有效期内。
    case licensed
    /// 例行校验在途（保留既有访问，乐观放行）。
    case validating
    /// 上游暂时不可用 → 离线宽限中，仍可用；超出宽限窗口落 `expired`。
    case gracePeriod
    /// 本机停用请求在途（保留访问直到确认）。
    case deactivating
    /// 明确被吊销（退款 / 拒付 / 上游吊销）——锁定。
    case revoked
    /// 明确过期（订阅到期 / 宽限耗尽）——锁定。
    case expired
    /// 可恢复错误（激活失败等，从未获得访问）。载荷为稳定错误码，UI 据此本地化提示。
    case recoverableError(String)
    /// 纯本地 7 天试用进行中（未激活且未到期）。`daysLeft` = 剩余天数（>0），功能开放
    /// （``AppState/isLicenseActive`` 为真）。见 ``TrialInfo`` / CLAUDE.md §5.5。
    case trial(daysLeft: Int)
    /// 试用已到期——锁付费能力（`isLicenseActive` 为假），但与既有 fail-open 一致**绝不黑洞网络**。
    case trialExpired
}

// MARK: - 客户端持久化记录（存 Keychain，非明文 plist/UserDefaults）

/// 客户端本地持久化的授权记录。**只存 Keychain**（licenseKey/instanceId/lastValidatedAt 等），
/// 附带 `clockHighWater` 做时钟回拨保护。与线上 DTO ``LicenseResponse`` 分开：这里是客户端私有形态。
public struct LicenseInfo: Sendable, Equatable, Codable {
    /// 用户从 Polar 邮件/客户门户复制的 license key。仅存 Keychain。
    public var licenseKey: String
    /// Polar activation id，后续 validate/deactivate 必用。
    public var instanceId: String
    /// 最近一次服务端返回的稳定化状态。
    public var status: LicenseStatus
    /// 订阅到期时间；买断为 nil。
    public var expiresAt: Date?
    /// 当前已用激活数。
    public var activations: Int
    /// 激活上限；nil = 无限。
    public var activationLimit: Int?
    /// 最近一次服务端校验时间（客户端据此计算离线宽限）。
    public var lastValidatedAt: Date
    /// 见过的最大挂钟时刻（单调上界）——时钟回拨保护：宽限计算用 `max(now, 此值)`，
    /// 防用户把系统时间调回去无限续宽限。
    public var clockHighWater: Date?

    public init(
        licenseKey: String,
        instanceId: String,
        status: LicenseStatus,
        expiresAt: Date? = nil,
        activations: Int,
        activationLimit: Int?,
        lastValidatedAt: Date,
        clockHighWater: Date? = nil
    ) {
        self.licenseKey = licenseKey
        self.instanceId = instanceId
        self.status = status
        self.expiresAt = expiresAt
        self.activations = activations
        self.activationLimit = activationLimit
        self.lastValidatedAt = lastValidatedAt
        self.clockHighWater = clockHighWater
    }

    /// 参照时刻：`max(now, clockHighWater, lastValidatedAt)`。时钟被回拨时以历史高水位为准，
    /// 保证宽限只会向前消耗，永不因调回系统时间被重置或续期。
    public func referenceNow(_ now: Date) -> Date {
        var reference = now
        if let highWater = clockHighWater, highWater > reference { reference = highWater }
        if lastValidatedAt > reference { reference = lastValidatedAt }
        return reference
    }

    /// 距上次成功校验已过去多久（用参照时刻算，永远 >= 0）。
    public func graceElapsed(_ now: Date) -> TimeInterval {
        referenceNow(now).timeIntervalSince(lastValidatedAt)
    }

    /// 是否已过订阅到期时刻（买断 `expiresAt == nil` 永不因日期过期）。用参照时刻，防回拨绕过。
    public func isExpiredByDate(_ now: Date) -> Bool {
        guard let expiresAt else { return false }
        return referenceNow(now) >= expiresAt
    }

    /// 抬高时钟高水位到 `max(旧值, now)`。
    public mutating func bumpHighWater(_ now: Date) {
        if let highWater = clockHighWater {
            if now > highWater { clockHighWater = now }
        } else {
            clockHighWater = now
        }
    }
}

// MARK: - 契约 DTO（与 contracts/licensing.openapi.yaml 对齐；Swift/TS 双边以契约为真相）

/// `POST /v1/licenses/activate` 请求体。
public struct ActivateRequest: Sendable, Equatable, Codable {
    public var licenseKey: String
    /// 隐私友好且稳定的安装标识——非邮箱/主机名/硬件序列号。
    public var instanceName: String
    public var appVersion: String

    public init(licenseKey: String, instanceName: String, appVersion: String) {
        self.licenseKey = licenseKey
        self.instanceName = instanceName
        self.appVersion = appVersion
    }
}

/// `POST /v1/licenses/validate` 请求体。
public struct ValidateRequest: Sendable, Equatable, Codable {
    public var licenseKey: String
    public var instanceId: String
    public var appVersion: String

    public init(licenseKey: String, instanceId: String, appVersion: String) {
        self.licenseKey = licenseKey
        self.instanceId = instanceId
        self.appVersion = appVersion
    }
}

/// `POST /v1/licenses/deactivate` 请求体。
public struct DeactivateRequest: Sendable, Equatable, Codable {
    public var licenseKey: String
    public var instanceId: String

    public init(licenseKey: String, instanceId: String) {
        self.licenseKey = licenseKey
        self.instanceId = instanceId
    }
}

/// activate / validate 的成功响应体（契约 schema `LicenseState`）。
public struct LicenseResponse: Sendable, Equatable, Codable {
    public var status: LicenseStatus
    public var instanceId: String
    public var expiresAt: Date?
    public var activations: Int
    public var activationLimit: Int?
    public var validatedAt: Date

    public init(
        status: LicenseStatus,
        instanceId: String,
        expiresAt: Date? = nil,
        activations: Int,
        activationLimit: Int?,
        validatedAt: Date
    ) {
        self.status = status
        self.instanceId = instanceId
        self.expiresAt = expiresAt
        self.activations = activations
        self.activationLimit = activationLimit
        self.validatedAt = validatedAt
    }
}

/// `POST /v1/licenses/deactivate` 成功响应体。
public struct DeactivateResponse: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case deactivated
    }

    public var status: Status

    public init(status: Status = .deactivated) {
        self.status = status
    }
}

/// facade 稳定错误码（契约 `Error.error` 枚举，不透传 Polar 内部响应）。
public enum LicenseFacadeErrorCode: String, Sendable, Equatable, Codable {
    case invalidRequest = "invalid_request"
    case invalidLicense = "invalid_license"
    case activationLimit = "activation_limit"
    case expired
    case revoked
    case rateLimited = "rate_limited"
    case upstreamUnavailable = "upstream_unavailable"
    case internalError = "internal_error"
}

/// facade 稳定错误体（契约 `Error`）。
public struct LicenseFacadeError: Sendable, Equatable, Codable {
    public var error: LicenseFacadeErrorCode
    /// 人类可读、脱敏说明（绝不含完整 license/API key）。
    public var message: String?

    public init(error: LicenseFacadeErrorCode, message: String? = nil) {
        self.error = error
        self.message = message
    }
}

// MARK: - API 客户端错误（Core 侧统一分类，注入实现产出）

/// ``LicenseAPIClient`` 产出的错误分类。网络/服务器/解码类由具体实现归一，
/// 结构化 facade 错误体经 ``LicenseFacadeError`` 透出错误码（**不含**上游明文）。
public enum LicenseAPIError: Error, Sendable, Equatable {
    /// facade 返回了结构化错误体（有稳定错误码）。
    case facade(LicenseFacadeError)
    /// 传输层失败（连接失败 / 超时 / 断网）——视为暂时性。
    case transport
    /// 服务器 5xx（无可解析错误码）——视为暂时性。
    case server
    /// 响应无法解码——视为暂时性（不因客户端/服务端偶发脏数据锁死用户）。
    case decoding
}

// MARK: - 失败归类（reducer 消费；网络→归类的映射在 AppFeature 侧，便于测试）

/// 激活失败归类。
public enum LicenseActivationFailure: String, Sendable, Equatable {
    case activationLimit
    case invalidLicense
    case expired
    case revoked
    /// 暂时性（网络/5xx/限速/上游不可用/解码）——激活期没有既有授权，退回可恢复错误让用户重试。
    case transient
}

/// 校验失败归类。
public enum LicenseValidationFailure: String, Sendable, Equatable {
    /// 明确吊销 → 锁定。
    case revoked
    /// 明确过期 → 锁定。
    case expired
    /// 暂时性 → 进入离线宽限，绝不锁定。
    case transient
}

/// Keychain 持久化操作类型。清除失败与普通保存失败的安全含义不同：停用后的清除必须确保
/// 旧 active 记录不会在下次启动复活，因此 action 需要保留操作类别供 reducer/日志明确处理。
public enum LicensePersistenceOperation: String, Sendable, Equatable {
    case save
    case clear
}
