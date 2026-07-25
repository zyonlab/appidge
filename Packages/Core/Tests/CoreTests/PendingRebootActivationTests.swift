import Testing
@testable import Core

/// 「升级后新扩展要重启电脑才生效」这一态的建模。
///
/// 真实缺陷：升级 69→70 后设置页显示「会话绑在旧扩展实例上（运行 69、已安装 70）」并持续卡住，
/// 自动重绑无效，直到把 app 完整重启（用户是靠切换语言触发的）才恢复。
///
/// 根因：`OSSystemExtensionRequest` 在**旧扩展仍被占用**时无法立即替换，返回
/// `.willCompleteAfterReboot`（新版本要重启电脑后才生效）。而 `SystemExtensionActivator`
/// 把它和 `.completed` 一视同仁报成 `.active` —— 这是**谎报**：新版本并没有在跑。
/// App 随即照常起会话，会话绑到仍在跑的旧 provider，于是 running≠bundled 卡死。
///
/// 而 `TransparentProxyController.restart()` 只 stop/start VPN 隧道、用的是版本无关的
/// `providerBundleIdentifier` —— 它**在结构上就不可能**改变系统注册的是哪个版本，
/// 所以版本握手自愈无论触发多少次都救不回来。真正做替换的只有 `OSSystemExtensionRequest`。
@Suite("扩展待重启生效态")
struct PendingRebootActivationTests {
    @Test("待重启生效 ≠ 已完成：必须是独立状态，不能谎报成 active")
    func pendingRebootIsDistinct() {
        #expect(ExtensionActivation.activePendingReboot != .active)
    }

    @Test("待重启期间旧 provider 仍在接管流量 → isRunning 为真（不能因此停接管把用户断网）")
    func stillRunningWhilePendingReboot() {
        #expect(ExtensionActivation.activePendingReboot.isRunning)
    }

    @Test("待重启生效时，版本不匹配的自愈不能只重启隧道——隧道重启改不了扩展版本")
    func tunnelRestartCannotFixPendingReboot() {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .licensed
        state.extensionActivation = .activePendingReboot
        state.runningExtensionVersion = "69"
        state.bundledExtensionVersion = "70"
        #expect(state.extensionNeedsRebind)
        // 待重启态下，重启隧道是徒劳的：必须走「重新提交 activation」这条路，
        // 且系统仍要求重启时要如实告知，而不是无限重试。
        #expect(state.staleBindingHealDecision(memo: .initial) == .reactivateExtension)
    }

    @Test("非待重启态的版本不匹配，仍走原来的有界强制重启")
    func normalMismatchStillForcesRestart() {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .licensed
        state.extensionActivation = .active
        state.runningExtensionVersion = "69"
        state.bundledExtensionVersion = "70"
        #expect(state.staleBindingHealDecision(memo: .initial) == .scheduleForcedRestart)
    }

    @Test("待重启态下会话监督不误判：接管在跑就不重复起会话")
    func supervisionRespectsPendingReboot() {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .licensed
        state.extensionActivation = .activePendingReboot
        #expect(state.sessionSupervisionDecision(isSessionConnected: true) == .none)
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .startSession)
    }
}
