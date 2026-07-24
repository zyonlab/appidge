import Foundation

// MARK: - 试用配置（可注入，默认 7 天；不硬编码）

/// 试用时长配置。默认 **7 天**；App 层从 Info.plist `TrialDurationDays` 读入后经 ``AppState/trialConfig``
/// 注入（staging 可注入 1 天快速验证到期路径）。集中一处，reducer 不硬编码天数。
public struct TrialConfig: Sendable, Equatable, Codable {
    /// 试用总天数（>=1）。
    public let durationDays: Int

    public init(durationDays: Int = 7) {
        self.durationDays = durationDays
    }

    /// 默认 7 天。
    public static let `default` = TrialConfig()
}

// MARK: - 试用锚点记录（本地防篡改，多锚点冗余）

/// 本地「首次启动时刻」锚点。**复用 ``LicenseInfo`` 同一套单调水位线防回拨算法**
/// （`referenceNow` 取 max、`bumpHighWater` 只前进不回血），确保把系统时间调回去也买不回试用天数。
///
/// 多锚点冗余：App 层同时落 Keychain 与 Application Support 文件两份；读取时取两者较早的
/// `firstLaunchAt`、最高的 `clockHighWater`（见 ``Reducer/mergeTrialAnchors(_:)``），删一个不重置。
/// **默认不含任何 PII**：只有两个时间戳。
public struct TrialInfo: Sendable, Equatable, Codable {
    /// 首次启动被记名的时刻（试用倒计时起点）。
    public var firstLaunchAt: Date
    /// 见过的最大挂钟时刻（单调上界）——回拨保护：daysLeft 用 `max(now, 此值)` 计算，
    /// 防用户把系统时间调回去续试用。
    public var clockHighWater: Date?

    public init(firstLaunchAt: Date, clockHighWater: Date? = nil) {
        self.firstLaunchAt = firstLaunchAt
        self.clockHighWater = clockHighWater
    }

    /// 参照时刻：`max(now, clockHighWater, firstLaunchAt)`。时钟被回拨时以历史高水位为准，
    /// 保证试用只会向前消耗，永不因调回系统时间被重置或续期；`firstLaunchAt` 兜底使 elapsed 永不为负。
    public func referenceNow(_ now: Date) -> Date {
        var reference = now
        if let highWater = clockHighWater, highWater > reference { reference = highWater }
        if firstLaunchAt > reference { reference = firstLaunchAt }
        return reference
    }

    /// 抬高时钟高水位到 `max(旧值, now)`。
    public mutating func bumpHighWater(_ now: Date) {
        if let highWater = clockHighWater {
            if now > highWater { clockHighWater = now }
        } else {
            clockHighWater = now
        }
    }

    /// 剩余试用天数（**ceil 语义**，用参照时刻防回拨）：到期时刻 = `firstLaunchAt + durationDays*天`，
    /// 剩余 = `ceil((到期 − referenceNow) / 天)`；<=0 归 0（表示已到期）。
    /// 天粒度天然吸收亚日级回拨——回拨几小时不会凭空多出一天。
    public func daysLeft(durationDays: Int, now: Date) -> Int {
        let day: TimeInterval = 86_400
        let expiry = firstLaunchAt.addingTimeInterval(Double(durationDays) * day)
        let remaining = expiry.timeIntervalSince(referenceNow(now))
        if remaining <= 0 { return 0 }
        return Int((remaining / day).rounded(.up))
    }
}
