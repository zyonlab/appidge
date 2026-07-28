import Core
import IPCContract

/// app 侧的「期望配置指纹」:配置对账闭环里与扩展上报指纹比对的基准。
///
/// **从真实 resync effects 派生,不镜像推送策略**:先让 `Core.Reducer` 对当前 state 跑一次
/// `.resyncExtension`,再把产出的六条推送 effect 经**与 effectHandler 完全相同的映射**
/// (`ProxyConfigMapping`/`RuleSetMapping`)翻成 wire 消息、喂给 ``IPCContract/ConfigFingerprint``。
/// 于是「期望指纹」严格等于「此刻真做一次全量 resync 会推出去什么」——推送策略里的一切细节
/// (fail-open 空规则集、停用规则不进 wire、排除并集……)自动被涵盖,策略改动无需同步这里。
///
/// 恢复门没开时 resync 是纯 no-op(effects 为空)→ 返回 nil,调用方跳过对账
/// (那时的 state 不是期望态,对账无意义)。
public enum ExpectedConfigFingerprint {

    public static func compute(state: Core.AppState, hostAppBundlePath: String?) -> String? {
        let (_, effects) = Core.Reducer.reduce(state, .resyncExtension)
        guard !effects.isEmpty else { return nil }

        var input = ConfigFingerprint.Input()
        for effect in effects {
            fold(effect, into: &input, hostAppBundlePath: hostAppBundlePath)
        }
        return ConfigFingerprint.compute(input)
    }

    /// 单条推送 effect → 指纹输入的对应字段(经与 effectHandler 相同的映射)。非推送 effect 忽略。
    private static func fold(
        _ effect: Core.Effect, into input: inout ConfigFingerprint.Input, hostAppBundlePath: String?
    ) {
        switch effect {
        case .applyProcessOriginExclusions(let direct, let hardBypass):
            input.exclusions = exclusionsDTO(direct: direct, hardBypass: hardBypass, hostAppBundlePath: hostAppBundlePath)
        case .applyProxyConfig(let servers, let activeID):
            input.proxyConfig = proxyConfigDTO(servers: servers, activeID: activeID)
        case .applyRoutingMode(let mode):
            input.routingMode = routingModeDTO(mode)
        case .applyPacketCapture(let enabled):
            input.packetCaptureEnabled = enabled
        case .applyUDPPolicy(let policy):
            input.udpPolicy = udpPolicyDTO(policy)
        case .applyRuleSet(let assignments, let matchRules):
            input.ruleSet = ruleSetDTO(assignments: assignments, matchRules: matchRules)
        default:
            break
        }
    }

    // MARK: - 消息载荷解包(mapping 返回的是 envelope case,取出内层 DTO;形态不匹配不可能发生,
    // 兜底回落空形态——两侧同为空仍相等,单侧异常必失配 → resync,方向安全)。

    private static func exclusionsDTO(
        direct: Core.OriginExclusionDiscovery, hardBypass: Core.OriginExclusionDiscovery, hostAppBundlePath: String?
    ) -> ProcessOriginExclusionMessage {
        let message = ProxyConfigMapping.processOriginExclusionsMessage(
            direct: direct, hardBypass: hardBypass, hostAppBundlePath: hostAppBundlePath
        )
        if case .applyProcessOriginExclusions(let dto) = message { return dto }
        return ProcessOriginExclusionMessage(identifiers: [])
    }

    private static func proxyConfigDTO(
        servers: [Core.ProxyServer], activeID: Core.ProxyServerID?
    ) -> ProxyConfigMessage? {
        let message = ProxyConfigMapping.proxyConfigMessage(servers: servers, activeID: activeID)
        if case .applyProxyConfig(let dto) = message { return dto }
        return nil
    }

    private static func routingModeDTO(_ mode: Core.ProxyRoutingMode) -> ProxyRoutingModeDTO {
        if case .applyRoutingMode(let dto) = ProxyConfigMapping.routingModeMessage(mode) { return dto }
        return .single
    }

    private static func udpPolicyDTO(_ policy: Core.UDPPolicy) -> UDPPolicyDTO {
        if case .setUDPPolicy(let dto) = ProxyConfigMapping.udpPolicyMessage(policy) { return dto }
        return .block
    }

    private static func ruleSetDTO(
        assignments: [Core.ProcessID: Core.ProxyRule], matchRules: [Core.ProxyMatchRule]
    ) -> RuleSetMessage {
        let message = RuleSetMapping.ruleSetMessage(assignments: assignments, matchRules: matchRules)
        if case .applyRuleSet(let dto) = message { return dto }
        return RuleSetMessage(assignments: [])
    }
}
