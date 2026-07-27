import Testing
@testable import Core

@Suite("Reducer — 环告警:自愈(来源进程自动旁路)+ 忽略过的 signature 不再重复弹")
struct LoopWarningReducerTests {

    private func raise(
        _ state: AppState, signature: String = "1.2.3.4:443",
        processID: String? = "com.example.yunti", path: String? = "/opt/xray"
    ) -> (AppState, [Effect]) {
        Reducer.reduce(state, .loopWarningRaised(
            signature: signature, processID: processID.map(ProcessID.init), executablePath: path
        ))
    }

    @Test("首次告警:写入 loopWarning + 来源双信号自动进旁路排除并回推扩展(环自愈)")
    func firstWarningShowsAndAutoExcludes() {
        let (state, effects) = raise(AppState())
        #expect(state.loopWarning == "1.2.3.4:443")
        #expect(state.loopAutoExclusions.identifiers == ["com.example.yunti"])
        #expect(state.loopAutoExclusions.executablePaths == ["/opt/xray"])
        #expect(effects == [state.originExclusionsPush])
    }

    @Test("同一来源重复上报:排除已收录,不重推(幂等)")
    func repeatedOriginDoesNotRepush() {
        var (state, _) = raise(AppState())
        let effects: [Effect]
        (state, effects) = raise(state)
        #expect(effects.isEmpty)
    }

    @Test("来源解析不出(双信号为 nil)时只弹告警,不产生排除推送")
    func unknownOriginOnlyWarns() {
        let (state, effects) = raise(AppState(), processID: nil, path: nil)
        #expect(state.loopWarning == "1.2.3.4:443")
        #expect(state.loopAutoExclusions == OriginExclusionDiscovery())
        #expect(effects.isEmpty)
    }

    @Test("dismiss 记住 signature,同一 signature 再次上报不再弹;但新来源的自愈照常发生")
    func dismissSuppressesBannerNotHealing() {
        var (state, _) = raise(AppState())
        (state, _) = Reducer.reduce(state, .dismissLoopWarning)
        #expect(state.loopWarning == nil)
        #expect(state.dismissedLoopSignatures.contains("1.2.3.4:443"))

        // 同 signature、新来源进程:横幅不弹(已忽略),但自愈(排除+推送)照常。
        let effects: [Effect]
        (state, effects) = raise(state, processID: "another", path: "/opt/other")
        #expect(state.loopWarning == nil)
        #expect(state.loopAutoExclusions.identifiers.contains("another"))
        #expect(effects == [state.originExclusionsPush])

        // 新 signature 是新问题,照常提醒。
        (state, _) = raise(state, signature: "5.6.7.8:443", processID: nil, path: nil)
        #expect(state.loopWarning == "5.6.7.8:443")
    }

    @Test("端口发现整体替换 dynamicOriginExclusion 时,环自愈加的排除不被冲掉——下发取并集")
    func discoveryReplaceKeepsLoopExclusions() {
        var (state, _) = raise(AppState())
        let discovery = OriginExclusionDiscovery(identifiers: ["com.example.yunti"], executablePaths: ["/opt/yunti"])
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .proxyProcessIdentitiesResolved(discovery))
        #expect(state.dynamicOriginExclusion == discovery)
        #expect(state.loopAutoExclusions.identifiers == ["com.example.yunti"])
        // 两档分开下发:发现档整体替换,自愈档独立保留。
        #expect(effects == [.applyProcessOriginExclusions(
            direct: discovery,
            hardBypass: OriginExclusionDiscovery(
                identifiers: ["com.example.yunti"], executablePaths: ["/opt/xray"]
            )
        )])
    }

    @Test("resync 下发的排除名单也是并集,且排在首位(防环信号先行)")
    func resyncPushesCombined() {
        let (state, _) = raise(AppState())
        let (_, effects) = Reducer.reduce(state, .resyncExtension)
        #expect(effects.first == state.originExclusionsPush)
        #expect(state.loopAutoExclusions.identifiers.contains("com.example.yunti"))
    }

    @Test("a.out 一类无法区分软件的标识不进 identifier 排除集(避免连坐未签名 CLI),路径照常")
    func ambiguousIdentifierIsPathOnly() {
        let (state, effects) = raise(AppState(), processID: "a.out", path: "/opt/xray/xray")
        #expect(state.loopAutoExclusions.identifiers.isEmpty)
        #expect(state.loopAutoExclusions.executablePaths == ["/opt/xray/xray"])
        #expect(effects == [state.originExclusionsPush])
    }

    @Test("无告警时 dismiss 是纯 no-op(不误记任何 signature)")
    func dismissWithoutWarningIsNoOp() {
        let (state, _) = Reducer.reduce(AppState(), .dismissLoopWarning)
        #expect(state.dismissedLoopSignatures.isEmpty)
    }

    // MARK: - 启动恢复(loopAutoExclusionsRestored)——环自愈学到的排除跨重启不丢

    @Test("启动恢复:持久化的环自愈排除灌回 + 回推扩展(切语言重启不再丢硬旁路)")
    func restoredExclusionsApplyAndPush() {
        let restored = OriginExclusionDiscovery(
            identifiers: ["com.example.yunti"], executablePaths: ["/opt/xray"]
        )
        let (state, effects) = Reducer.reduce(AppState(), .loopAutoExclusionsRestored(restored))
        #expect(state.loopAutoExclusions == restored)
        #expect(effects == [state.originExclusionsPush])
    }

    @Test("恢复与本次运行已学到的取并集,不整体替换")
    func restoredExclusionsUnionWithRuntime() {
        var (state, _) = raise(AppState())
        let restored = OriginExclusionDiscovery(executablePaths: ["/usr/local/bin/other-proxy"])
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .loopAutoExclusionsRestored(restored))
        #expect(state.loopAutoExclusions.identifiers == ["com.example.yunti"])
        #expect(state.loopAutoExclusions.executablePaths == ["/opt/xray", "/usr/local/bin/other-proxy"])
        #expect(effects == [state.originExclusionsPush])
    }

    @Test("恢复内容已全部在集内:无变化不重推(幂等)")
    func restoredExclusionsIdempotent() {
        var (state, _) = raise(AppState())
        let effects: [Effect]
        (state, effects) = Reducer.reduce(state, .loopAutoExclusionsRestored(state.loopAutoExclusions))
        #expect(effects.isEmpty)
    }

    @Test("恢复空集是纯 no-op(不产生推送)")
    func restoredEmptyIsNoOp() {
        let (state, effects) = Reducer.reduce(AppState(), .loopAutoExclusionsRestored(OriginExclusionDiscovery()))
        #expect(state.loopAutoExclusions == OriginExclusionDiscovery())
        #expect(effects.isEmpty)
    }

    @Test("恢复时同样过 a.out 滤网:磁盘数据里的歧义标识不进 identifier 集,路径照常")
    func restoredExclusionsFilterAmbiguousIdentifiers() {
        let restored = OriginExclusionDiscovery(
            identifiers: ["a.out", "com.example.yunti"], executablePaths: ["/opt/xray"]
        )
        let (state, effects) = Reducer.reduce(AppState(), .loopAutoExclusionsRestored(restored))
        #expect(state.loopAutoExclusions.identifiers == ["com.example.yunti"])
        #expect(state.loopAutoExclusions.executablePaths == ["/opt/xray"])
        #expect(effects == [state.originExclusionsPush])
    }
}
