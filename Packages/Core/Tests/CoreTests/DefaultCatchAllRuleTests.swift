import Testing
@testable import Core

/// 「配置过代理时默认走代理」这条核心语义的落地（CLAUDE.md §1）。
///
/// 缺口：扩展的路由回落是 **规则表 → 每进程规则 → 默认 `.direct`**
/// （`ProxyExtensionProviderRouting.resolveAction`，策略 A）。于是引导里加完代理、还没建任何
/// 规则时，**所有流量仍然走直连** —— 用户看到「代理配好了却没生效」，与文档写明的核心语义不符。
///
/// 修法不是去改扩展的默认（那个 `.direct` 回落是 fail-open 安全网：规则下发失败时宁可直连，
/// 也绝不黑洞网络），而是在加入**第一台**代理时自动建一条**可见、可编辑、可删**的
/// `* * → 代理` 兜底规则。这与仓库既有的透明性原则一致（「自动旁路不是黑盒，如实列出」），
/// 用户随时能看懂、改掉或删掉，而不是藏在代码里的隐式行为。
///
/// 顺序天然正确：新规则插在**表首**（首个命中生效），所以引导期这条兜底落在最底，
/// 之后用户加的每条具体规则都排在它上面、优先命中。
@Suite("加入首台代理时的默认兜底规则")
struct DefaultCatchAllRuleTests {
    private func addFirstProxy(to state: AppState) -> (AppState, [Effect]) {
        let server = ProxyServer(id: ProxyServerID("p1"), host: "127.0.0.1", port: 1080)
        return Reducer.reduce(state, .addProxyServer(server))
    }

    @Test("加入第一台代理 → 自动建 `* * → 代理` 兜底规则（配了代理默认走代理）")
    func firstProxyCreatesCatchAll() {
        let (next, _) = addFirstProxy(to: AppState())
        #expect(next.rules.count == 1)
        let rule = next.rules[0]
        #expect(rule.appPattern == "*")
        #expect(rule.hostPattern == "*")
        #expect(rule.portRange == nil)
        #expect(rule.action == .proxied)
        // 不绑死到某一台：跟随全局活动代理 / 路由模式，换代理不必改规则。
        #expect(rule.proxyServerID == nil)
        #expect(rule.isEnabled)
    }

    @Test("兜底规则要下发给扩展——只改 state 不推送等于没生效")
    func catchAllIsPushed() {
        let (_, effects) = addFirstProxy(to: AppState())
        #expect(effects.contains { if case .applyRuleSet = $0 { return true } else { return false } })
        #expect(effects.contains { if case .applyProxyConfig = $0 { return true } else { return false } })
    }

    @Test("已有规则时不自动加——用户已经在管规则了，别替他做主")
    func doesNotOverrideExistingRules() {
        var state = AppState()
        state.rules = [ProxyMatchRule(
            id: RuleID("mine"), appPattern: "*", hostPattern: "example.com",
            portRange: nil, action: .direct
        )]
        let (next, _) = addFirstProxy(to: state)
        #expect(next.rules.count == 1)
        #expect(next.rules[0].id == RuleID("mine"))
    }

    @Test("回归·用户删掉兜底后再加第二台代理，不得把它塞回来")
    func doesNotResurrectAfterDeletion() {
        // 第一台 → 自动建兜底
        var (state, _) = addFirstProxy(to: AppState())
        #expect(state.rules.count == 1)
        // 用户明确删掉（他要默认直连）
        (state, _) = Reducer.reduce(state, .removeMatchRule(state.rules[0].id))
        #expect(state.rules.isEmpty)
        // 再加第二台代理 —— 绝不能又冒出来
        let server2 = ProxyServer(id: ProxyServerID("p2"), host: "10.0.0.1", port: 1080)
        let (next, _) = Reducer.reduce(state, .addProxyServer(server2))
        #expect(next.rules.isEmpty)
    }

    @Test("第二台代理本身也不触发（只有第一台、且规则表为空时才建）")
    func onlyOnFirstProxy() {
        var (state, _) = addFirstProxy(to: AppState())
        state.rules = []   // 模拟用户清空了规则表
        let server2 = ProxyServer(id: ProxyServerID("p2"), host: "10.0.0.1", port: 1080)
        let (next, _) = Reducer.reduce(state, .addProxyServer(server2))
        #expect(next.rules.isEmpty)
    }

    @Test("兜底规则用确定性 id（同 derivedRuleID 的做法），reducer 保持纯函数不生成 UUID")
    func deterministicID() {
        let (a, _) = addFirstProxy(to: AppState())
        let (b, _) = addFirstProxy(to: AppState())
        #expect(a.rules[0].id == b.rules[0].id)
    }
}
