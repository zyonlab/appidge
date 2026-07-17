import Testing
@testable import Core

@Suite("Reducer — 环告警:自愈(来源进程自动旁路)+ 忽略过的 signature 不再重复弹")
struct LoopWarningReducerTests {

    private func raise(
        _ state: AppState, signature: String = "1.2.3.4:443",
        processID: String? = "a.out", path: String? = "/opt/xray"
    ) -> (AppState, [Effect]) {
        Reducer.reduce(state, .loopWarningRaised(
            signature: signature, processID: processID.map(ProcessID.init), executablePath: path
        ))
    }

    @Test("首次告警:写入 loopWarning + 来源双信号自动进旁路排除并回推扩展(环自愈)")
    func firstWarningShowsAndAutoExcludes() {
        let (state, effects) = raise(AppState())
        #expect(state.loopWarning == "1.2.3.4:443")
        #expect(state.loopAutoExclusions.identifiers == ["a.out"])
        #expect(state.loopAutoExclusions.executablePaths == ["/opt/xray"])
        #expect(effects == [.applyProcessOriginExclusions(state.combinedOriginExclusions)])
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
        #expect(effects == [.applyProcessOriginExclusions(state.combinedOriginExclusions)])

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
        #expect(state.loopAutoExclusions.identifiers == ["a.out"])
        #expect(effects == [.applyProcessOriginExclusions(OriginExclusionDiscovery(
            identifiers: ["com.example.yunti", "a.out"],
            executablePaths: ["/opt/yunti", "/opt/xray"]
        ))])
    }

    @Test("resync 下发的排除名单也是并集")
    func resyncPushesCombined() {
        let (state, _) = raise(AppState())
        let (_, effects) = Reducer.reduce(state, .resyncExtension)
        #expect(effects.last == .applyProcessOriginExclusions(state.combinedOriginExclusions))
        #expect(state.combinedOriginExclusions.identifiers.contains("a.out"))
    }

    @Test("无告警时 dismiss 是纯 no-op(不误记任何 signature)")
    func dismissWithoutWarningIsNoOp() {
        let (state, _) = Reducer.reduce(AppState(), .dismissLoopWarning)
        #expect(state.dismissedLoopSignatures.isEmpty)
    }
}
