import SwiftUI
import AppKit
import Core

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

    /// 无存储值时的默认语言——**跟随系统首选语言**:系统偏好中文 → 简中(源语言,最完整、零混排),
    /// 否则英文。读全局域 `kCFPreferencesAnyApplication`(绕开本 app 自己写进 AppleLanguages 的覆盖,
    /// 否则会自我循环读到旧的 en)。用户仍可在设置里手动覆盖成任一语言。
    static var defaultLanguage: AppLanguage {
        let systemFirst = (CFPreferencesCopyAppValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String])?.first
            ?? Locale.preferredLanguages.first ?? "en"
        return systemFirst.hasPrefix("zh") ? .zhHans : .english
    }

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

    /// 新开一个实例(带重启守卫 env),确认它真的起来了之后再退出当前实例，并**把接管会话交接**
    /// 给接班者(退出时不停会话)。
    ///
    /// 为什么要交接：NE 配置是**按 app 全局一份**、不是每进程一份。老实例退出走
    /// `applicationWillTerminate` → `stopCachedSessionForTermination()` 会停掉已知的**全部**会话
    /// （那是为根治「退出留下僵尸接管 = 全系统断网」特意做的），而接班者此时往往已经
    /// `startVPNTunnel()` 起好了会话 —— 于是前任把接班者的会话停掉，扩展再收不到任何 flow，
    /// 表现为「切完语言活动列表就空了」。扩展在这条路径上并没有变，本就该交接而不是停。
    ///
    /// 为什么必须确认接班成功：原实现忽略 `openApplication` 的两个回调参数、无条件 terminate。
    /// 在「退出即停会话」的旧语义下最多是白退一次；改成交接语义后，同一条路径会变成
    /// 「app 退了 + 接班者没起来 + 会话还在跑且没有 UI 能停它」= 全系统断网只能重启电脑。
    /// 故失败时留在原地继续运行（语言下次启动仍会生效，`AppleLanguages` 已经写好了）。
    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = [relaunchGuardEnv: "1"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            let launched = app != nil && error == nil
            Task { @MainActor in
                switch RelaunchHandoff.decide(successorLaunched: launched) {
                case .handOffAndTerminate:
                    AppTermination.isHandingOffToSuccessor = true
                    NSApp.terminate(nil)
                case .abortStayRunning:
                    // 不退出、不交接：宁可语言这次没切成，也绝不留下无人管的接管。
                    NSLog("appidge: language relaunch aborted — successor did not launch (\(error?.localizedDescription ?? "unknown")); staying alive")
                }
            }
        }
    }
}
