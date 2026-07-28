import Testing
import Core
import IPCContract
@testable import AppFeature

/// 配置对账闭环的 AppFeature 侧:期望指纹从**真实 resync effects** 派生(零策略镜像),
/// IPCReceiver 把扩展上报接成带 expected 的双值 action。
@Suite("ExpectedConfigFingerprint — 从真实 resync effects 派生期望指纹")
struct ExpectedConfigFingerprintTests {

    private var readyState: Core.AppState {
        var state = Core.AppState(isConfigurationReplayComplete: true)
        state.rules = [Core.ProxyMatchRule(
            id: Core.RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]
        let server = Core.ProxyServer(
            id: Core.ProxyServerID("s1"), host: "127.0.0.1", port: 1080,
            kind: .socks5, username: nil, password: nil
        )
        state.proxyServers[server.id] = server
        state.activeProxyServerID = server.id
        return state
    }

    @Test("恢复门没开:resync 是 no-op,期望指纹为 nil(不对账)")
    func gateClosedYieldsNil() {
        #expect(ExpectedConfigFingerprint.compute(state: Core.AppState(), hostAppBundlePath: nil) == nil)
    }

    @Test("配置任一维度变化,期望指纹随之变化(规则/上游/hostAppBundlePath)")
    func fingerprintTracksState() throws {
        let base = try #require(ExpectedConfigFingerprint.compute(state: readyState, hostAppBundlePath: "/Applications/appidge.app"))

        var changedRules = readyState
        changedRules.rules[0] = Core.ProxyMatchRule(
            id: Core.RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .direct
        )
        #expect(ExpectedConfigFingerprint.compute(state: changedRules, hostAppBundlePath: "/Applications/appidge.app") != base)

        var changedServer = readyState
        changedServer.activeProxyServerID = nil
        #expect(ExpectedConfigFingerprint.compute(state: changedServer, hostAppBundlePath: "/Applications/appidge.app") != base)

        #expect(ExpectedConfigFingerprint.compute(state: readyState, hostAppBundlePath: "/elsewhere.app") != base)
    }

    @Test("引擎不健康的期望指纹 == 规则清空的健康态指纹——fail-open 空规则集策略自动被涵盖,无镜像漂移")
    func unhealthyMirrorsFailOpenAutomatically() throws {
        var unhealthy = readyState
        unhealthy.isEngineHealthy = false

        var emptyRules = readyState
        emptyRules.rules = []

        let unhealthyFP = try #require(ExpectedConfigFingerprint.compute(state: unhealthy, hostAppBundlePath: nil))
        let emptyRulesFP = try #require(ExpectedConfigFingerprint.compute(state: emptyRules, hostAppBundlePath: nil))
        #expect(unhealthyFP == emptyRulesFP)
    }

    @Test("停用的规则不进 wire:停用唯一规则的指纹 == 没有这条规则的指纹(RuleSetMapping 过滤自动被涵盖)")
    func disabledRulesAreFilteredLikeTheWire() throws {
        var disabled = readyState
        disabled.rules[0] = Core.ProxyMatchRule(
            id: Core.RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil,
            action: .proxied, isEnabled: false
        )
        var absent = readyState
        absent.rules = []

        let disabledFP = try #require(ExpectedConfigFingerprint.compute(state: disabled, hostAppBundlePath: nil))
        let absentFP = try #require(ExpectedConfigFingerprint.compute(state: absent, hostAppBundlePath: nil))
        #expect(disabledFP == absentFP)
    }
}

@Suite("IPCReceiver — 指纹上报接成带 expected 的对账 action")
struct FingerprintReceiverWiringTests {

    @Test("扩展上报失配指纹:reducer 收到双值 action,连击 +1(证明 expected 已被注入且比对生效)")
    func mismatchedReportBumpsStreak() async {
        var initial = AppState(isConfigurationReplayComplete: true)
        initial.rules = [ProxyMatchRule(
            id: RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]
        let store = await MainActor.run { Store(initialState: initial) }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()

        await transport.simulateIncoming(.configFingerprintReported("definitely-not-the-expected-fp"))

        var streak = 0
        for _ in 0..<100 {
            streak = await MainActor.run { store.state.configFingerprintMismatchStreak }
            if streak == 1 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(streak == 1)
    }

    @Test("扩展上报恰好等于期望指纹:连击归零、不触发失配")
    func matchingReportKeepsStreakZero() async {
        var initial = AppState(isConfigurationReplayComplete: true)
        initial.configFingerprintMismatchStreak = 2
        let store = await MainActor.run { Store(initialState: initial) }
        let expected = await MainActor.run {
            ExpectedConfigFingerprint.compute(state: store.state, hostAppBundlePath: nil)
        }
        let transport = MockAppSideTransport()
        let receiver = await MainActor.run { IPCReceiver(store: store, transport: transport) }
        await receiver.start()

        await transport.simulateIncoming(.configFingerprintReported(expected ?? ""))

        var streak = -1
        for _ in 0..<100 {
            streak = await MainActor.run { store.state.configFingerprintMismatchStreak }
            if streak == 0 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(streak == 0)
    }
}
