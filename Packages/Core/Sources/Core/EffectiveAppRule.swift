/// **UI 展示用**:某进程在当前规则表下的 app 维度有效动作——只考虑「主机 `*` 且端口任意」的
/// host-agnostic 规则(含 `assignRule` 派生的「进程 × * × *」规则),自上而下取首个**启用且**
/// 进程 glob 命中的动作;都不命中返回 nil(调用方显示"默认直连")。
///
/// 为什么存在:`MonitoredProcess.rule` 只是"最后一次每进程赋值"的快照,规则表才是路由的唯一
/// 真相(扩展只看表)。「应用」表的规则列若显示快照,用户在「规则」页删掉/停用规则后两页就
/// 不同步(真机实锤)。展示从这里**按表推导**,删规则立刻回落到下一条命中(或默认直连)。
///
/// 语义与 `EngineKit.RuleMatcher.firstAppLevelMatch` **必须一致**(那边对 DTO、给扩展路由;
/// 这边对 Core 模型、给 UI 展示;B2 不变量禁止两包互相依赖,所以是镜像不是复用)。两边都有
/// 测试钉住关键用例,改任何一边的语义必须同步改另一边。
public enum EffectiveAppRule {
    public static func action(forProcess id: ProcessID, rules: [ProxyMatchRule]) -> ProxyRule? {
        for rule in rules where rule.isEnabled && rule.hostPattern == "*" && rule.portRange == nil
            && Glob.matches(pattern: rule.appPattern, text: id.value) {
            return rule.action
        }
        return nil
    }
}

/// 极简 glob:只支持 `*`(匹配任意长度任意字符,含点),大小写不敏感。经典贪心回溯,零依赖。
/// `EngineKit.Glob` 的**镜像**(见 `EffectiveAppRule` 的类型注释:为什么不是复用)。
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
