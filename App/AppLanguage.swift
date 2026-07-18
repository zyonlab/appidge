import SwiftUI

/// 用户可选的界面语言，存 `@AppStorage(AppLanguage.storageKey)` 的原始字符串。
/// `.system` = 跟随系统语言（不覆盖 locale 环境）；其余两项把 SwiftUI 的 `\.locale`
/// 环境覆盖成指定语言，`Text(LocalizedStringKey)` 随即走对应 String Catalog 实现即时切换。
///
/// 只在主线程读写（@AppStorage 绑定在 @MainActor 的 App/View 上），满足 Swift 6 严格并发，
/// 本身是纯值枚举、`Sendable`，不引入跨 actor 共享可变引用。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统语言（默认）。
    case system
    /// 简体中文（源语言）。
    case zhHans = "zh-Hans"
    /// English。
    case english = "en"

    /// `@AppStorage` 的键名，App 与设置页共用同一份。
    static let storageKey = "appLanguage"

    var id: String { rawValue }

    /// 设置页 Picker 里的显示名（LocalizedStringKey，随所选语言即时刷新）。
    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .zhHans: "简体中文"
        case .english: "English"
        }
    }

    /// 要覆盖到 `\.locale` 环境的 Locale：非 `.system` 时用所选语言；
    /// `.system` 返回 `nil`，由调用方回退到系统当前 Locale（不覆盖）。
    var resolvedLocale: Locale? {
        switch self {
        case .system: nil
        case .zhHans: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }
}
