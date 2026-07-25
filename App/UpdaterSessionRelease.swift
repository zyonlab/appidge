import Foundation
import Sparkle

/// Sparkle 升级生命周期钩子：**在安装/重启之前主动停掉接管会话**，释放旧扩展 provider 的占用。
///
/// 为什么需要：`OSSystemExtensionRequest` 在旧扩展仍被占用时无法立即替换，只会返回
/// `.willCompleteAfterReboot`——新版本要**重启电脑**才生效。于是升级后新 app 起来时，
/// 系统跑的仍是旧 provider（真机实测 69→70：设置页长期显示「运行 69、已安装 70」，
/// 自动重绑无效，因为重启隧道用的是版本无关的 providerBundleIdentifier，改不了扩展版本）。
///
/// 用户点「安装并重启」时先停会话，让替换在**这一刻**就能完成，从根上少落进 reboot 分支。
/// 停会话是安全的：此刻 app 正要退出，所有应用立即恢复原生直连，新版本起来后重新接管。
///
/// 注意与 `AppTermination.isHandingOffToSuccessor` 的区别：升级路径**必须**停会话
/// （扩展二进制要被替换），语言切换路径才交接。两者语义相反，不要混。
final class UpdaterSessionRelease: NSObject, SPUUpdaterDelegate {
    /// Sparkle 已下载好、即将安装（用户点了「安装并重启」）。
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        releaseSession(reason: "willInstallUpdate")
    }

    /// Sparkle 即将重启 app。再停一次（幂等）——覆盖「安装在退出时进行」的路径。
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        releaseSession(reason: "willRelaunchApplication")
    }

    private func releaseSession(reason: String) {
        FileHandle.standardError.write(
            Data("UpdaterSessionRelease: stopping proxy session before update (\(reason))\n".utf8))
        Task { @MainActor in
            TransparentProxyController.stop()
        }
    }
}
