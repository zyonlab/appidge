import Testing
@testable import Core

/// `.resyncExtension` 是 app↔扩展配置同步的自愈动作:XPC(重)连上、或启动恢复完成后触发一次,
/// 把当前完整配置全量重推给扩展。它不改 state,只产出一串"把现状推下去"的 effect——扩展升级/
/// 重启/掉线重连后不再空转(否则每条 flow 回落默认直连、什么都不接管,活动栏一片空白)。
@Suite("Reducer — resyncExtension 全量重推当前配置,不改 state")
struct ResyncExtensionReducerTests {

    @Test("resyncExtension 不改动 state")
    func resyncDoesNotMutateState() {
        var state = AppState()
        state.rules = [ProxyMatchRule(
            id: RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]
        let (next, _) = Reducer.reduce(state, .resyncExtension)
        #expect(next == state)
    }

    @Test("resyncExtension 产出全部六类推送 effect,顺序确定")
    func resyncEmitsAllPushEffectsInOrder() {
        let processID = ProcessID("com.x")
        var state = AppState()
        state.processes[processID] = MonitoredProcess(
            id: processID, displayName: "X", executablePath: "/x", rule: .proxied
        )
        state.rules = [ProxyMatchRule(
            id: RuleID("r1"), appPattern: "*", hostPattern: "*", portRange: nil, action: .proxied
        )]
        let server = ProxyServer(
            id: ProxyServerID("s1"), host: "h", port: 1080, kind: .socks5, username: nil, password: nil
        )
        state.proxyServers[server.id] = server
        state.activeProxyServerID = server.id
        state.proxyRoutingMode = .single
        state.isPacketCaptureEnabled = true
        state.udpPolicy = .direct
        state.dynamicOriginExclusion = OriginExclusionDiscovery(
            identifiers: ["com.example.yunti"], executablePaths: ["/Users/admin/.yunti/xray-core/xray"]
        )

        let (_, effects) = Reducer.reduce(state, .resyncExtension)

        // 顺序契约:排除名单先落地、规则集最后放行——扩展升级后的第一波 flow 不能在排除
        // 缺席时先撞上通配「走代理」规则(那是秒级真环窗口,真机实锤)。
        #expect(effects == [
            .applyProcessOriginExclusions(direct: state.dynamicOriginExclusion, hardBypass: OriginExclusionDiscovery()),
            .applyProxyConfig(servers: [server], activeID: server.id),
            .applyRoutingMode(.single),
            .applyPacketCapture(true),
            .applyUDPPolicy(.direct),
            .applyRuleSet(
                assignments: [:],
                matchRules: state.rules
            )
        ])
    }

    @Test("即使配置为空(全默认),resync 仍然把六条 effect 都发出去——扩展据此清成一致的空配置")
    func resyncOnEmptyStateStillPushesEverything() {
        let (_, effects) = Reducer.reduce(AppState(), .resyncExtension)
        #expect(effects.count == 6)
        // 第一条一定是排除名单(空发现)——防环信号先行。
        #expect(effects.first == .applyProcessOriginExclusions(
            direct: OriginExclusionDiscovery(), hardBypass: OriginExclusionDiscovery()))
        // 最后一条一定是规则集推送(空规则、空 assignment)——判定最后放行。
        #expect(effects.last == .applyRuleSet(assignments: [:], matchRules: []))
    }
}
