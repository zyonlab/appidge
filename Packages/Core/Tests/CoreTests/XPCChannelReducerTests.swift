import Testing
@testable import Core

/// XPC 通道可达性信号的 reducer 测试。
///
/// 背景（2026-07-26 真机 log 实锤，80→81 升级后 100% 复现）：系统扩展升级换血窗口里，
/// 新扩展进程可能在新旧 launchd job 交替的竞态中被拉起，`NSXPCListener(machServiceName:)`
/// 注册失败——app 侧 bootstrap look-up 报 "No such process"。后果双重：配置推不下去
/// （排除名单为空 → xray 被全量接管直连 pump），连接事件送不回 app（活动页永远空白），
/// 而 Engine 状态显示 OK，用户完全无感知。
///
/// app 侧此前对连接失败**静默重试**（ReconnectBackoff），永远不告诉用户。现在把
/// 「通道连续掉线 = 不可达」作为一等状态信号回灌 store，UI 据此显式警告并提供一键修复。
@Suite("XPC 通道可达性信号")
struct XPCChannelReducerTests {

    @Test("初始状态视为可达——没有证据前不误报")
    func initiallyReachable() {
        #expect(AppState().isXPCChannelReachable)
    }

    @Test("通道不可达信号写入 state")
    func unreachableSignalIsStored() {
        let (state, effects) = Reducer.reduce(AppState(), .xpcChannelReachabilityChanged(false))
        #expect(!state.isXPCChannelReachable)
        #expect(effects.isEmpty)
    }

    @Test("通道恢复信号写回可达")
    func reachableSignalRestores() {
        var state = AppState()
        state.isXPCChannelReachable = false
        let (next, effects) = Reducer.reduce(state, .xpcChannelReachabilityChanged(true))
        #expect(next.isXPCChannelReachable)
        #expect(effects.isEmpty)
    }

    @Test("重复同值信号是幂等 no-op（差分守卫，不产生多余通知）")
    func duplicateSignalIsNoOp() {
        let state = AppState()
        let (next, effects) = Reducer.reduce(state, .xpcChannelReachabilityChanged(true))
        #expect(next == state)
        #expect(effects.isEmpty)
    }

    // MARK: - isXPCChannelBroken（UI 警告的判据）

    /// 构造「授权开放 + 引导完成 + 扩展在跑」的基线——通道断开只有在这种
    /// 「本应一切正常」的状态下才是需要打断用户的故障。
    private func runningState() -> AppState {
        var state = AppState()
        state.hasCompletedOnboarding = true
        state.licensePhase = .trial(daysLeft: 5)
        state.extensionActivation = .active
        return state
    }

    @Test("扩展在跑 + 通道不可达 = 通道故障，UI 该警告")
    func brokenWhenRunningButUnreachable() {
        var state = runningState()
        state.isXPCChannelReachable = false
        #expect(state.isXPCChannelBroken)
    }

    @Test("通道可达时不警告")
    func notBrokenWhenReachable() {
        #expect(!runningState().isXPCChannelBroken)
    }

    @Test("扩展没在跑（被停用/未批准）时不按通道故障警告——那是另一类提示的职责")
    func notBrokenWhenExtensionNotRunning() {
        var state = runningState()
        state.isXPCChannelReachable = false
        state.extensionActivation = .disabled
        #expect(!state.isXPCChannelBroken)
        state.extensionActivation = .needsApproval
        #expect(!state.isXPCChannelBroken)
    }

    @Test("功能未开放/未完成引导时不警告——本就不该有会话在跑")
    func notBrokenWhenCapabilityClosed() {
        var state = runningState()
        state.isXPCChannelReachable = false
        state.licensePhase = .trialExpired
        #expect(!state.isXPCChannelBroken)

        var noOnboarding = runningState()
        noOnboarding.isXPCChannelReachable = false
        noOnboarding.hasCompletedOnboarding = false
        #expect(!noOnboarding.isXPCChannelBroken)
    }

    @Test("旧版本 pending-reboot 仍在转发也算在跑——通道断了同样要警告")
    func brokenAlsoAppliesToPendingReboot() {
        var state = runningState()
        state.extensionActivation = .activePendingReboot
        state.isXPCChannelReachable = false
        #expect(state.isXPCChannelBroken)
    }
}
