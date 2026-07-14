import Core
import IPCContract

/// 纯映射:把 Core 的路由状态(全局开关 + 每进程规则 + 细粒度规则表)翻成
/// `IPCContract.AppToExtensionMessage.applyRuleSet`。app 侧 effectHandler 收到
/// `Core.Effect.applyRuleSet` 后调这里,再经 AppSideTransport 发给扩展。
public enum RuleSetMapping {
    public static func ruleSetMessage(
        globalProxyEnabled: Bool,
        assignments: [Core.ProcessID: Core.ProxyRule],
        matchRules: [Core.ProxyMatchRule]
    ) -> IPCContract.AppToExtensionMessage {
        let assignmentDTOs = assignments
            .sorted { $0.key.value < $1.key.value } // 顺序确定,便于测试 + 幂等
            .map { RuleAssignmentDTO(processID: ProcessIdentifierDTO($0.key.value), rule: dtoRule(from: $0.value)) }
        return .applyRuleSet(RuleSetMessage(
            // 停用的规则在这里被滤掉,永不进 wire——扩展的匹配器根本看不到它们,
            // 于是求值自然落到下一条(或默认)。这样 IPCContract/扩展都无需改动。
            assignments: assignmentDTOs,
            matchRules: matchRules.filter(\.isEnabled).map(dto(from:)),
            globalProxyEnabled: globalProxyEnabled
        ))
    }

    private static func dto(from rule: Core.ProxyMatchRule) -> MatchRuleDTO {
        MatchRuleDTO(
            id: rule.id.value,
            appPattern: rule.appPattern,
            hostPattern: rule.hostPattern,
            portRange: rule.portRange,
            rule: dtoRule(from: rule.action)
        )
    }

    /// 穷举 switch(不带 default):`Core.ProxyRule` 以后新增 case 时这里编译报错。
    private static func dtoRule(from rule: Core.ProxyRule) -> ProxyRuleDTO {
        switch rule {
        case .direct: .direct
        case .proxied: .proxied
        case .block: .block
        }
    }
}
