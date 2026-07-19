import SwiftUI
import AppKit

/// 用户可选的界面语言。`@AppStorage(AppLanguage.storageKey)` 存原始字符串——它同时就是喂给
/// `AppleLanguages` 的语言代码(`zh-Hans` / `en`)。
///
/// **不再走 `.environment(\.locale)` 覆盖**:那条路在运行时并不可靠地改 `LocalizedStringKey`
/// 读哪个 `.lproj`(SwiftUI 老限制,真机实测选简中不生效)。改为写 `UserDefaults` 的
/// `AppleLanguages` + 重启 app 生效(见 ``LanguageBootstrap``),这样 `Text(LocalizedStringKey)`
/// 与 `String(localized:)` 全走 `Bundle.main` 同一门语言,一致可靠。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// 简体中文(源语言)。
    case zhHans = "zh-Hans"
    /// English。
    case english = "en"

    /// `@AppStorage` 的键名,App 与设置页共用同一份。
    static let storageKey = "appLanguage"

    /// 无存储值时的默认语言——产品决策:默认英文(去掉了「跟随系统」)。
    static let defaultLanguage: AppLanguage = .english

    var id: String { rawValue }

    /// 直接作为 `AppleLanguages` 数组元素的语言代码(等于 rawValue)。
    var code: String { rawValue }

    /// 设置页 Picker 里的显示名(重启后随所选语言刷新)。
    var labelKey: LocalizedStringKey {
        switch self {
        case .zhHans: "简体中文"
        case .english: "English"
        }
    }
}

/// 界面语言的落地:写 `AppleLanguages` + 必要时重启,让 `Bundle.main` 加载对应 `.lproj`。
/// 只在主线程用(启动早期 + 设置页切换),纯枚举静态方法,无共享可变状态。
enum LanguageBootstrap {
    private static let appleLanguagesKey = "AppleLanguages"
    /// 重启守卫:重启出来的新实例带这个 env,极端情况下(设了 AppleLanguages 仍不匹配)不再反复重启。
    private static let relaunchGuardEnv = "APPIDGE_LANG_RELAUNCHED"

    /// 当前存储的语言(无值回默认英文)。
    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: AppLanguage.storageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.defaultLanguage
    }

    /// 启动最早期调用:把 `AppleLanguages` 对齐到所选语言;若本次进程实际加载的语言与目标不符,
    /// 重启一次让它生效(用户机器语言=目标时是 no-op,只有跨语言首启才会触发一次重启)。
    static func applyAtLaunch() {
        let desired = current.code
        UserDefaults.standard.set([desired], forKey: appleLanguagesKey)
        let effective = Bundle.main.preferredLocalizations.first ?? "en"
        guard effective != desired,
              ProcessInfo.processInfo.environment[relaunchGuardEnv] == nil else { return }
        relaunch()
    }

    /// 用户在设置里切语言:`@AppStorage` 已持久化选择,这里写 `AppleLanguages` 并重启生效。
    static func switchTo(_ language: AppLanguage) {
        UserDefaults.standard.set([language.code], forKey: appleLanguagesKey)
        relaunch()
    }

    /// 新开一个实例(带重启守卫 env),再正常退出当前实例——退出走 `applicationWillTerminate`,
    /// 会先停掉透明代理会话(不留僵尸接管,几秒内新实例重新接管)。
    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = [relaunchGuardEnv: "1"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
