import IPCContract

/// 对 `IPCContract.MatchRuleDTO` 求值的规则匹配器——这是扩展真正按规则路由用的那份
/// (EngineKit 只依赖 IPCContract,不依赖 Core,见架构不变量 B2)。逻辑与 `Core.ProxyMatchRule`
/// 的语义一致,但住在这一层、按 DTO 工作,并在这里重点测试。
public enum RuleMatcher {
    /// 单条规则:进程 × 主机 × 端口 三个维度全部命中才算命中。
    public static func matches(_ rule: MatchRuleDTO, app: String, host: String, port: UInt16) -> Bool {
        Glob.matches(pattern: rule.appPattern, text: app)
            && Glob.matches(pattern: rule.hostPattern, text: host)
            && (rule.portRange?.contains(port) ?? true)
    }

    /// 规则表从上到下,返回首个命中规则的动作;都不命中返回 nil(调用方回落每进程/默认)。
    public static func firstMatch(_ rules: [MatchRuleDTO], app: String, host: String, port: UInt16) -> ProxyRuleDTO? {
        for rule in rules where matches(rule, app: app, host: host, port: port) {
            return rule.rule
        }
        return nil
    }
}

/// 极简 glob:只支持 `*`(匹配任意长度任意字符,含点),大小写不敏感。经典贪心回溯,零依赖。
enum Glob {
    static func matches(pattern: String, text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())

        var textIndex = 0
        var patternIndex = 0
        var starPatternIndex = -1
        var starTextMark = 0

        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == text[textIndex] {
                textIndex += 1
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starPatternIndex = patternIndex
                starTextMark = textIndex
                patternIndex += 1
            } else if starPatternIndex != -1 {
                patternIndex = starPatternIndex + 1
                starTextMark += 1
                textIndex = starTextMark
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
