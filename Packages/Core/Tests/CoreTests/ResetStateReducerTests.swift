import Testing
@testable import Core

@Suite("Reducer — resetState clears back to a fresh AppState (for profile switching)")
struct ResetStateReducerTests {

    @Test("resetState returns a default AppState and no effects, discarding prior state")
    func resetClearsEverything() {
        var state = AppState()
        state.isPacketCaptureEnabled = true
        state.proxyServers[ProxyServerID("a")] = ProxyServer(id: ProxyServerID("a"), host: "h", port: 1)
        state.rules = [ProxyMatchRule(id: RuleID("r"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied)]
        state.connectionLog = [ConnectionLogEntry(
            id: "c", processID: ProcessID("p"), host: "h", port: 1,
            rule: .proxied, proxyKind: nil, phase: .opened, bytesUp: 0, bytesDown: 0
        )]
        state.loopWarning = "x"

        let (reset, effects) = Reducer.reduce(state, .resetState)

        #expect(reset == AppState())
        #expect(effects.isEmpty)
    }

    @Test("resetState then replaying a config's restorationActions reconstructs exactly that config")
    func resetThenRestoreReplacesCleanly() {
        var dirty = AppState()
        dirty.proxyServers[ProxyServerID("old")] = ProxyServer(id: ProxyServerID("old"), host: "old", port: 9)

        var state = Reducer.reduce(dirty, .resetState).0
        // 模拟切档案:reset 后灌入新档案的两条 action。
        state = Reducer.reduce(state, .addProxyServer(ProxyServer(id: ProxyServerID("new"), host: "new", port: 1))).0

        #expect(state.proxyServers[ProxyServerID("old")] == nil)
        #expect(state.proxyServers[ProxyServerID("new")]?.host == "new")
    }
}
