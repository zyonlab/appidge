import Testing
@testable import Core

/// 「升级后会话绑死旧 provider = 全系统黑洞」自愈**策略**的测试。
///
/// 这段策略原先直接写在 `App/AppidgeApp.swift` 的 View 层里（`maybeHealStaleBinding()`），
/// `swift test` 够不着——于是下面这个真实缺陷长期没被发现：
///
/// 自愈只在 `store.onAction` 观察者收到 `.extensionVersionReported` 时触发，而该观察者是在
/// `await ipcReceiver.start()` 之后又隔了 4 个 await 才接线的。扩展 XPC 一连上就发
/// `.extensionReady(version)`，正好落在这个窗口里 → **升级后那一次启动（running≠bundled
/// 唯一成立的一次）自愈根本没被调用**，会话继续绑旧 provider，活动列表为空。
/// 且该 action 有去重，扩展再报同一版本也不会重新触发。
///
/// 策略抽到 Core 后是纯函数：App 层只负责在若干时机「重新评估」，评估本身可测、幂等。
@Suite("升级后陈旧绑定自愈策略")
struct StaleBindingHealTests {
    /// 构造一个「已完成引导 + 试用中（功能开放）」的基线状态。
    private func activeState(running: String?, bundled: String?) -> AppState {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .trial(daysLeft: 5)
        state.runningExtensionVersion = running
        state.bundledExtensionVersion = bundled
        return state
    }

    @Test("版本未知时不动作——不确定就不误重启接管")
    func unknownVersionsDoNothing() {
        let state = activeState(running: nil, bundled: "66")
        #expect(state.staleBindingHealDecision(memo: .initial) == .none)
    }

    /// 首选是**重新提交 activation**——那是唯一能让系统换到新 provider 的手段；重启隧道用的是
    /// 版本无关的 providerBundleIdentifier，改不了版本（真机 75→77 实测坐实，见
    /// PendingRebootActivationTests）。强制重启退居第二手。
    @Test("运行 != 包内 → 先重新提交 activation（唯一能换版本的手段）")
    func mismatchReactivatesFirst() {
        let state = activeState(running: "63", bundled: "66")
        #expect(state.staleBindingHealDecision(memo: .initial) == .reactivateExtension)
    }

    @Test("两手各一次为限——防旧 bug 无限环，用尽后留手动「重启接管」兜底")
    func eachRemedyOnlyOnce() {
        let state = activeState(running: "63", bundled: "66")
        var memo = StaleBindingHealMemo.initial
        memo.recordDecision(state.staleBindingHealDecision(memo: memo))   // reactivate
        #expect(state.staleBindingHealDecision(memo: memo) == .scheduleForcedRestart)
        memo.recordDecision(state.staleBindingHealDecision(memo: memo))   // forced restart
        #expect(state.staleBindingHealDecision(memo: memo) == .none)
    }

    @Test("曾见不匹配、现在版本已一致 → 重绑一次，让会话真正挂到新 provider")
    func rebindsOnceAfterMismatchResolves() {
        var memo = StaleBindingHealMemo.initial
        let stale = activeState(running: "63", bundled: "66")
        memo.recordDecision(stale.staleBindingHealDecision(memo: memo))

        let healed = activeState(running: "66", bundled: "66")
        #expect(healed.staleBindingHealDecision(memo: memo) == .rebindNow)
    }

    @Test("重绑也只做一次")
    func rebindOnlyOnce() {
        var memo = StaleBindingHealMemo.initial
        memo.recordDecision(activeState(running: "63", bundled: "66").staleBindingHealDecision(memo: memo))
        let healed = activeState(running: "66", bundled: "66")
        memo.recordDecision(healed.staleBindingHealDecision(memo: memo))
        #expect(healed.staleBindingHealDecision(memo: memo) == .none)
    }

    @Test("从未见过不匹配、版本一致 → 不动作（正常启动不该无谓重启接管）")
    func steadyStateDoesNothing() {
        let state = activeState(running: "66", bundled: "66")
        #expect(state.staleBindingHealDecision(memo: .initial) == .none)
    }

    // MARK: - 缺陷本身：早到的版本回报 / 晚落定的相位

    @Test("回归·版本回报早于接线：稍后用同一 state 重新评估，仍能判出需要自愈")
    func lateReevaluationStillHeals() {
        // 模拟：扩展在 onAction 接线前就报了版本，state 已写入 running=63，
        // 但当时没有任何观察者触发自愈。App 层稍后补评估一次 —— 必须仍然判出要自愈。
        let state = activeState(running: "63", bundled: "66")
        #expect(state.staleBindingHealDecision(memo: .initial) == .reactivateExtension)
    }

    @Test("回归·相位晚落定：相位还没落定时不动作，落定为试用后重新评估即自愈")
    func healsAfterLicensePhaseSettles() {
        // 启动瞬间 licensePhase 默认 .unlicensed（授权/试用是异步从 Keychain 恢复的）。
        var pending = activeState(running: "63", bundled: "66")
        pending.licensePhase = .unlicensed
        #expect(pending.staleBindingHealDecision(memo: .initial) == .none)

        // 相位落定为试用后重新评估 —— 必须能自愈，而不是永久错过。
        let settled = activeState(running: "63", bundled: "66")
        #expect(settled.staleBindingHealDecision(memo: .initial) == .reactivateExtension)
    }

    @Test("未完成引导时不动作——还没有会话可绑")
    func noHealBeforeOnboarding() {
        var state = activeState(running: "63", bundled: "66")
        state.hasCompletedOnboarding = false
        #expect(state.staleBindingHealDecision(memo: .initial) == .none)
    }

    @Test("功能未开放（试用到期且未购买）时不动作——会话本就该停")
    func noHealWhenCapabilityClosed() {
        var state = activeState(running: "63", bundled: "66")
        state.licensePhase = .trialExpired
        #expect(state.staleBindingHealDecision(memo: .initial) == .none)
    }

    @Test("不动作的评估不污染 memo——相位落定后仍能自愈")
    func noneDecisionDoesNotConsumeMemo() {
        var memo = StaleBindingHealMemo.initial
        var pending = activeState(running: "63", bundled: "66")
        pending.licensePhase = .unlicensed
        memo.recordDecision(pending.staleBindingHealDecision(memo: memo))

        let settled = activeState(running: "63", bundled: "66")
        #expect(settled.staleBindingHealDecision(memo: memo) == .reactivateExtension)
    }
}
