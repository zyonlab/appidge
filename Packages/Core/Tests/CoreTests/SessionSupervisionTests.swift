import Testing
@testable import Core

/// 接管**会话**的启动后监督。
///
/// 修的是真实缺陷：切换界面语言后活动列表为空。语言切换 = `LanguageBootstrap.relaunch()`
/// 开新实例后老实例退出，而老实例的 `applicationWillTerminate` 会停掉**所有**已知会话
/// （`stopCachedSessionForTermination`，为根治「退出留下僵尸接管 = 全系统断网」而特意如此）。
/// NE 配置是**按 app 全局一份**、不是每进程一份，于是老实例停掉的正是接班者刚 `startVPNTunnel()`
/// 起来的那个会话 —— 扩展收不到任何 flow，活动列表空。
///
/// 光靠「交接时别停」是不够的：那等于假设交接永远成功。这里把判定做成可反复评估的纯函数——
/// 只要「能力开放 + 扩展在跑 + 会话却没连上」，就该把会话起回来，不管上一步为什么没成。
@Suite("接管会话启动后监督")
struct SessionSupervisionTests {
    private func ready(sessionConnected: Bool) -> AppState {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .trial(daysLeft: 5)
        state.extensionActivation = .active
        return state
    }

    @Test("回归·语言切换后会话被前任停掉：扩展在跑但会话没连上 → 必须把会话起回来")
    func revivesSessionKilledByPredecessor() {
        let state = ready(sessionConnected: false)
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .startSession)
    }

    @Test("会话已连上 → 不动作（绝不无谓重启接管）")
    func connectedSessionLeftAlone() {
        let state = ready(sessionConnected: true)
        #expect(state.sessionSupervisionDecision(isSessionConnected: true) == .none)
    }

    @Test("扩展没在跑 → 不动作：先解决扩展批准，起会话没有意义")
    func noSessionWhenExtensionNotRunning() {
        var state = ready(sessionConnected: false)
        state.extensionActivation = .needsApproval
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .none)
    }

    @Test("扩展被用户在系统设置里停用 → 不动作")
    func noSessionWhenExtensionDisabled() {
        var state = ready(sessionConnected: false)
        state.extensionActivation = .disabled
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .none)
    }

    @Test("未完成引导 → 不动作")
    func noSessionBeforeOnboarding() {
        var state = ready(sessionConnected: false)
        state.hasCompletedOnboarding = false
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .none)
    }

    @Test("能力未开放（试用到期未购买）→ 不动作：会话本就该停")
    func noSessionWhenCapabilityClosed() {
        var state = ready(sessionConnected: false)
        state.licensePhase = .trialExpired
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .none)
    }

    @Test("已购买同样适用——监督与授权相位无关，只看能力是否开放")
    func appliesToLicensedUsers() {
        var state = ready(sessionConnected: false)
        state.licensePhase = .licensed
        #expect(state.sessionSupervisionDecision(isSessionConnected: false) == .startSession)
    }
}

/// 语言切换重启的**交接**判定。
///
/// 安全红线：只有确认接班实例真的起来了，才可以「交接退出」（退出时不停会话）。
/// 原 `relaunch()` 把 `openApplication` 的两个回调参数全忽略、无条件 terminate ——
/// 今天只是「新实例没起来就白退一次」（会话已停，网络是好的）；一旦改成交接语义，
/// 同一条路径就变成：app 退了、接班者没起来、**会话还在跑且没有任何 UI 能停它**
/// = catch-all 接管挂死系统，只能重启电脑。故失败时必须留在原地，绝不交接。
@Suite("语言切换重启交接")
struct RelaunchHandoffTests {
    @Test("接班实例确认启动 → 交接退出（退出时不停会话，留给接班者）")
    func handsOffWhenSuccessorLaunched() {
        #expect(RelaunchHandoff.decide(successorLaunched: true) == .handOffAndTerminate)
    }

    @Test("接班实例没起来 → 留在原地，绝不交接（否则留下无 UI 的僵尸接管 = 全系统断网）")
    func staysWhenSuccessorFailed() {
        #expect(RelaunchHandoff.decide(successorLaunched: false) == .abortStayRunning)
    }

    @Test("非交接退出（普通退出 / Sparkle 升级重启）必须停掉所有会话")
    func normalTerminationStopsSessions() {
        #expect(RelaunchHandoff.terminationPolicy(isHandingOff: false) == .stopAllSessions)
    }

    @Test("交接退出不停会话——扩展没换，接班者已持有同一份全局 NE 配置")
    func handoffTerminationKeepsSession() {
        #expect(RelaunchHandoff.terminationPolicy(isHandingOff: true) == .keepSessionForSuccessor)
    }
}
