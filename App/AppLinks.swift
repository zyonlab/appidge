import SwiftUI

/// 稳定的窗口 id 常量：About / Manage License 由 App 菜单与启动弹窗共同引用，避免散落字符串。
enum AppWindowID {
    /// 现有主窗口（见 `WindowGroup(id: "main")`）。
    static let main = "main"
    static let about = "about"
    static let manageLicense = "manage-license"
}

/// App 侧公开配置 + 官网法务链接拼接。`SiteBaseURL` / `TrialDurationDays` 读自主包 Info.plist
/// （由另一 agent 注入），`LicenseCheckoutURL` 复用 AppFeature 的 `LicenseBuildConfig`。
/// 纯读取、无副作用；缺键回落到安全默认，**绝不硬编码生产地址**误用。与网络接管完全无关。
enum AppLinks {
    /// 官网基址（无尾斜杠）。缺失/为空回落到 staging，永不误用未知生产域。
    static var siteBaseURL: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SiteBaseURL") as? String,
              !value.isEmpty else {
            return "https://staging.appidge.com"
        }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// 试用总天数（Info.plist 以字符串存储，parse 为 Int）。缺失/非法回落 7 天。
    /// 启动装配处读出后交给 Core 的试用配置入口（见 AppidgeApp 的注入点）。
    static var trialDurationDays: Int {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TrialDurationDays") as? String,
              let value = Int(raw), value > 0 else {
            return 7
        }
        return value
    }

    /// 四条法务页（About 与帮助菜单镜像同一组），路径由 `SiteBaseURL` 拼接。
    enum LegalPage: String, CaseIterable, Identifiable {
        case refund = "/refund"
        case privacy = "/privacy"
        case terms = "/terms"
        case dataUsage = "/data-usage"

        var id: String { rawValue }

        /// 菜单/链接文案（中文为 catalog 源键，英文为译文）。
        var menuTitle: LocalizedStringKey {
            switch self {
            case .refund: "退款政策"
            case .privacy: "隐私政策"
            case .terms: "服务条款"
            case .dataUsage: "数据使用"
            }
        }
    }

    /// 拼出某法务页的完整 URL；base 非法时返回 nil（调用方安全跳过）。
    static func legalURL(_ page: LegalPage) -> URL? {
        URL(string: siteBaseURL + page.rawValue)
    }
}
