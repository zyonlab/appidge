import Testing
@testable import IPCContract

/// 配置指纹:app↔扩展「配置对账」闭环的度量基准。两侧对**同一套 wire DTO** 调同一份代码——
/// 无镜像、无漂移;指纹相等 ⟺ 扩展持有的配置与 app 期望的一致。
@Suite("ConfigFingerprint — 确定性、集合序无关、语义序敏感")
struct ConfigFingerprintTests {

    private func server(_ id: String, port: UInt16 = 1080) -> ProxyServerDTO {
        ProxyServerDTO(id: id, host: "127.0.0.1", port: port, kind: .socks5)
    }

    private func rule(_ id: String, app: String = "*", action: ProxyRuleDTO = .proxied) -> MatchRuleDTO {
        MatchRuleDTO(id: id, appPattern: app, hostPattern: "*", portRange: nil, rule: action)
    }

    private func fingerprint(
        exclusions: ProcessOriginExclusionMessage = ProcessOriginExclusionMessage(identifiers: []),
        proxyConfig: ProxyConfigMessage? = ProxyConfigMessage(servers: [], activeServerID: nil),
        routingMode: ProxyRoutingModeDTO = .single,
        packetCapture: Bool = false,
        udpPolicy: UDPPolicyDTO = .block,
        ruleSet: RuleSetMessage = RuleSetMessage(assignments: [])
    ) -> String {
        ConfigFingerprint.compute(ConfigFingerprint.Input(
            exclusions: exclusions, proxyConfig: proxyConfig, routingMode: routingMode,
            packetCaptureEnabled: packetCapture, udpPolicy: udpPolicy, ruleSet: ruleSet
        ))
    }

    @Test("同输入恒同指纹(确定性),且是 64 位十六进制(SHA-256)")
    func deterministicAndWellFormed() {
        let a = fingerprint(ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")]))
        let b = fingerprint(ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")]))
        #expect(a == b)
        #expect(a.count == 64)
        let isHex = a.allSatisfy(\.isHexDigit)
        #expect(isHex)
    }

    @Test("排除名单是集合语义:数组到达顺序不同,指纹相同")
    func exclusionArrayOrderIsIrrelevant() {
        let a = fingerprint(exclusions: ProcessOriginExclusionMessage(
            identifiers: ["b", "a"], executablePaths: ["/y", "/x"],
            hardBypassIdentifiers: ["d", "c"], hardBypassExecutablePaths: ["/q", "/p"]
        ))
        let b = fingerprint(exclusions: ProcessOriginExclusionMessage(
            identifiers: ["a", "b"], executablePaths: ["/x", "/y"],
            hardBypassIdentifiers: ["c", "d"], hardBypassExecutablePaths: ["/p", "/q"]
        ))
        #expect(a == b)
    }

    @Test("规则表顺序是语义(首个命中生效):交换两条规则,指纹必变")
    func matchRuleOrderIsSemantic() {
        let a = fingerprint(ruleSet: RuleSetMessage(
            assignments: [], matchRules: [rule("r1", app: "a"), rule("r2", app: "b")]
        ))
        let b = fingerprint(ruleSet: RuleSetMessage(
            assignments: [], matchRules: [rule("r2", app: "b"), rule("r1", app: "a")]
        ))
        #expect(a != b)
    }

    @Test("任一维度变化指纹必变:规则动作 / 上游端口 / active id / 路由模式 / 抓包 / UDP 策略")
    func anyFieldChangeChangesFingerprint() {
        let base = fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: "s1"),
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        )
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: "s1"),
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1", action: .direct)])
        ))
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1", port: 1081)], activeServerID: "s1"),
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        ))
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: nil),
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        ))
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: "s1"),
            routingMode: .failover(["s1"]),
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        ))
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: "s1"),
            packetCapture: true,
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        ))
        #expect(base != fingerprint(
            proxyConfig: ProxyConfigMessage(servers: [server("s1")], activeServerID: "s1"),
            udpPolicy: .direct,
            ruleSet: RuleSetMessage(assignments: [], matchRules: [rule("r1")])
        ))
    }

    @Test("扩展侧「从未收到代理配置」(nil) 与 app 侧「空配置」指纹相同——首推前的对账不误报方向")
    func nilProxyConfigEqualsEmpty() {
        let a = fingerprint(proxyConfig: nil)
        let b = fingerprint(proxyConfig: ProxyConfigMessage(servers: [], activeServerID: nil))
        #expect(a == b)
    }

    @Test("servers 数组顺序无关(app 侧按 id 排序推送,但对账不依赖这个约定)")
    func serverOrderIsIrrelevant() {
        let a = fingerprint(proxyConfig: ProxyConfigMessage(
            servers: [server("s2"), server("s1")], activeServerID: "s1"
        ))
        let b = fingerprint(proxyConfig: ProxyConfigMessage(
            servers: [server("s1"), server("s2")], activeServerID: "s1"
        ))
        #expect(a == b)
    }
}
