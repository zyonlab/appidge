import Testing
@testable import Core

/// 「应用」表规则列的推导逻辑:从规则表(唯一路由真相)算进程的 app 维度有效动作。
/// 语义必须与 EngineKit.RuleMatcher.firstAppLevelMatch 一致(镜像,见 EffectiveAppRule 注释)。
@Suite("EffectiveAppRule — 应用表展示从规则表推导,与路由同一真相")
struct EffectiveAppRuleTests {
    private let app = ProcessID("com.example.app")

    private func rule(
        _ appPattern: String, host: String = "*", port: ClosedRange<UInt16>? = nil,
        _ action: ProxyRule, enabled: Bool = true
    ) -> ProxyMatchRule {
        ProxyMatchRule(
            id: RuleID(appPattern + host), appPattern: appPattern, hostPattern: host,
            portRange: port, action: action, isEnabled: enabled
        )
    }

    @Test("自动旁路进程 → 放行(与活动页一致):回环自愈档按可执行文件路径命中,规则表被短路")
    func loopExcludedProcessShowsObserve() {
        let action = EffectiveAppRule.action(
            forProcess: ProcessID("a.out"), executablePath: "/opt/xray",
            rules: [rule("*", .proxied)],
            loopAutoExclusions: OriginExclusionDiscovery(executablePaths: ["/opt/xray"]),
            dynamicOriginExclusion: OriginExclusionDiscovery()
        )
        #expect(action == .observe)
    }

    @Test("自动旁路进程 → 放行:本地代理发现档按签名标识命中")
    func dynamicExcludedProcessShowsObserve() {
        let action = EffectiveAppRule.action(
            forProcess: ProcessID("com.example.yunti"), executablePath: nil,
            rules: [rule("*", .proxied)],
            loopAutoExclusions: OriginExclusionDiscovery(),
            dynamicOriginExclusion: OriginExclusionDiscovery(identifiers: ["com.example.yunti"])
        )
        #expect(action == .observe)
    }

    @Test("不在任何排除集 → 照常回落规则表推导")
    func unexcludedProcessFallsThroughToRules() {
        let action = EffectiveAppRule.action(
            forProcess: app, executablePath: "/Applications/App.app/Contents/MacOS/App",
            rules: [rule("*", .proxied)],
            loopAutoExclusions: OriginExclusionDiscovery(executablePaths: ["/opt/xray"]),
            dynamicOriginExclusion: OriginExclusionDiscovery(identifiers: ["com.example.yunti"])
        )
        #expect(action == .proxied)
    }

    @Test("排除集全空 → 与纯规则表推导等价(nil 含义不变)")
    func emptyExclusionsMatchLegacyBehavior() {
        let action = EffectiveAppRule.action(
            forProcess: app, executablePath: nil,
            rules: [],
            loopAutoExclusions: OriginExclusionDiscovery(),
            dynamicOriginExclusion: OriginExclusionDiscovery()
        )
        #expect(action == nil)
    }

    @Test("host-agnostic 规则自上而下首个命中生效")
    func firstMatchWins() {
        let rules = [rule("com.example.app", .direct), rule("*", .proxied)]
        #expect(EffectiveAppRule.action(forProcess: app, rules: rules) == .direct)
        #expect(EffectiveAppRule.action(forProcess: ProcessID("other"), rules: rules) == .proxied)
    }

    @Test("都不命中 → nil(UI 显示默认直连)")
    func noMatchIsNil() {
        #expect(EffectiveAppRule.action(forProcess: app, rules: []) == nil)
        #expect(EffectiveAppRule.action(forProcess: app, rules: [rule("com.other", .proxied)]) == nil)
    }

    @Test("host/port 特定规则不参与 app 维度判定(与 UDP/展示语义一致)")
    func hostSpecificIgnored() {
        let rules = [rule("com.example.app", host: "example.com", .proxied),
                     rule("com.example.app", port: 443...443, .block)]
        #expect(EffectiveAppRule.action(forProcess: app, rules: rules) == nil)
    }

    @Test("停用的规则被跳过——规则页停用后应用表立刻回落")
    func disabledSkipped() {
        let rules = [rule("com.example.app", .block, enabled: false), rule("*", .proxied)]
        #expect(EffectiveAppRule.action(forProcess: app, rules: rules) == .proxied)
    }

    @Test("进程 glob 大小写不敏感、支持 *(与 EngineKit.Glob 镜像语义)")
    func globSemantics() {
        #expect(EffectiveAppRule.action(forProcess: ProcessID("Com.Example.App"),
                                        rules: [rule("com.example.*", .proxied)]) == .proxied)
        #expect(EffectiveAppRule.action(forProcess: app, rules: [rule("*", .block)]) == .block)
    }
}
