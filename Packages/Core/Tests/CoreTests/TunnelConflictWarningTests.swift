import Testing
@testable import Core

/// TUN 冲突警示:第三方 TUN(带 IPv4 的 utun)与 appidge 接管并存时,双接管层叠加可致
/// fake-ip DNS 黑洞级断网(2026-07 Clash Party 真实反馈)。警示是纯派生状态:
/// 接管运行中 + 探测到活跃 utun + 用户没忽略过 → 给出接口名单。
struct TunnelConflictWarningTests {

    private func running(_ environment: ProxyEnvironment, dismissed: Set<String> = []) -> AppState {
        AppState(
            extensionActivation: .active,
            proxyEnvironment: environment,
            dismissedTunnelInterfaces: dismissed
        )
    }

    @Test("默认无警示")
    func defaultsToEmpty() {
        #expect(AppState().tunnelConflictInterfaces.isEmpty)
        #expect(ProxyEnvironment().routedTunnelInterfaces.isEmpty)
    }

    @Test("接管运行中 + 活跃 utun → 警示该接口")
    func warnsWhenRunningWithRoutedTunnel() {
        let state = running(ProxyEnvironment(routedTunnelInterfaces: ["utun6"]))
        #expect(state.tunnelConflictInterfaces == ["utun6"])
    }

    @Test("接管没在跑就不警示——没有冲突对象")
    func silentWhenExtensionNotRunning() {
        var state = running(ProxyEnvironment(routedTunnelInterfaces: ["utun6"]))
        state.extensionActivation = .inactive
        #expect(state.tunnelConflictInterfaces.isEmpty)
    }

    @Test("忽略动作记下当前接口;同名不再警,新出现的接口照警")
    func dismissRecordsCurrentInterfacesOnly() {
        let state = running(ProxyEnvironment(routedTunnelInterfaces: ["utun6"]))
        let (dismissed, effects) = Reducer.reduce(state, .dismissTunnelConflictWarning)
        #expect(effects.isEmpty)
        #expect(dismissed.tunnelConflictInterfaces.isEmpty)

        // 用户换/重启了 TUN 软件,新接口名出现 → 重新警示,且只警新的。
        var later = dismissed
        later.proxyEnvironment.routedTunnelInterfaces = ["utun6", "utun7"]
        #expect(later.tunnelConflictInterfaces == ["utun7"])
    }
}
