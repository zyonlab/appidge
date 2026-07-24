import Foundation

/// 时间来源抽象——**可注入**，测试用固定/可推进的假时钟驱动宽限与时钟回拨用例。
/// 命名带 `License` 前缀，避免与标准库 `Swift.Clock` 混淆。
public protocol LicenseClock: Sendable {
    /// 当前挂钟时间。
    var now: Date { get }
}

/// 授权记录的 Keychain 出口——**可注入**。真实实现走 Security framework（在 App 层），
/// 测试用内存实现（在 AppFeature）。方法抛错以显式暴露 Keychain 失败，reducer/handler 据此降级：
/// 读失败 → 视为未激活（安全）；写失败 → 保持本会话已授权但标记未持久化，不锁用户。
public protocol LicenseKeychainStore: Sendable {
    /// 写入/覆盖授权记录（licenseKey/instanceId/lastValidatedAt/高水位等）。
    func saveLicense(_ info: LicenseInfo) async throws
    /// 读取授权记录；无记录返回 nil。
    func loadLicense() async throws -> LicenseInfo?
    /// 清除授权记录（停用时）。
    func clearLicense() async throws
}

/// 试用锚点的一个出口——**可注入**。App 层提供两个真实实现：Keychain 一份、Application Support
/// 文件一份（多锚点冗余，删一个不重置）；测试用内存实现。方法抛错以显式暴露读写失败：
/// 读失败视为该锚点缺失（安全——由另一锚点兜底），写失败不致命（本会话已判定，下次启动再自愈补写）。
public protocol TrialAnchorStore: Sendable {
    /// 读取本锚点记录；无记录返回 nil。
    func readAnchor() async throws -> TrialInfo?
    /// 写入/覆盖本锚点记录（首启记名、后续抬高水位、自愈补写）。
    func writeAnchor(_ info: TrialInfo) async throws
    /// 清除本锚点记录（激活成功后收尾，可选）。
    func clearAnchor() async throws
}

/// license facade 客户端——**可注入**。只调用自有 Worker facade（api.appidge.com），
/// **绝不**直连带 `Bearer token` 的 Polar API。返回 `Result`，错误统一为 ``LicenseAPIError``
/// （网络/服务器/解码/结构化 facade 错误码），网络→失败归类的翻译在 AppFeature 侧完成。
public protocol LicenseAPIClient: Sendable {
    func activate(_ request: ActivateRequest) async -> Result<LicenseResponse, LicenseAPIError>
    func validate(_ request: ValidateRequest) async -> Result<LicenseResponse, LicenseAPIError>
    func deactivate(_ request: DeactivateRequest) async -> Result<DeactivateResponse, LicenseAPIError>
}
