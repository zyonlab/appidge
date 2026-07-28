import Foundation
import CryptoKit

/// 配置指纹:app↔扩展「配置对账」闭环的度量。对六类配置消息的**规范化 wire 形态**做
/// SHA-256——app 侧对「用当前 state 生成的 would-be 消息」计算期望指纹,扩展侧对「已落地的
/// stored 配置」计算实际指纹,两侧调**同一份代码、同一套 DTO**(IPCContract 是双方共同依赖),
/// 无镜像、无漂移。指纹不等 ⟹ 配置分叉 ⟹ app 全量 resync 自愈。
///
/// 为什么需要它:配置推送是 fire-and-forget,存在多个静默丢失窗口(冷却期丢弃、死连接未察觉、
/// 双实例最后写者获胜——2026-07-28 真机实锤的「扩展有排除名单却没有规则表」分叉)。对账不猜
/// 时序,把不变量升级为「两侧不一致的状态最多存活一个上报周期」。
///
/// 规范化规则:
/// - 排除名单四个数组、`servers`、`assignments` 是**集合语义**(到达顺序无关)→ 排序后编码;
/// - `matchRules` 顺序**就是语义**(首个命中生效)→ 原序编码;
/// - 扩展侧「从未收到代理配置」(nil) 等价于空配置(首推前对账不误报方向);
/// - 编码用 JSONEncoder + `.sortedKeys`(键序确定);无浮点字段,跨进程字节确定。
public enum ConfigFingerprint {

    /// 六元组入参。默认值 = 「从未收到任何配置」的空形态——扩展侧启动初态与 app 侧空配置
    /// 指纹相等,首推前的对账不误报方向。
    public struct Input: Sendable {
        public var exclusions: ProcessOriginExclusionMessage
        public var proxyConfig: ProxyConfigMessage?
        public var routingMode: ProxyRoutingModeDTO
        public var packetCaptureEnabled: Bool
        public var udpPolicy: UDPPolicyDTO
        public var ruleSet: RuleSetMessage

        public init(
            exclusions: ProcessOriginExclusionMessage = ProcessOriginExclusionMessage(identifiers: []),
            proxyConfig: ProxyConfigMessage? = nil,
            routingMode: ProxyRoutingModeDTO = .single,
            packetCaptureEnabled: Bool = false,
            udpPolicy: UDPPolicyDTO = .block,
            ruleSet: RuleSetMessage = RuleSetMessage(assignments: [])
        ) {
            self.exclusions = exclusions
            self.proxyConfig = proxyConfig
            self.routingMode = routingMode
            self.packetCaptureEnabled = packetCaptureEnabled
            self.udpPolicy = udpPolicy
            self.ruleSet = ruleSet
        }
    }

    public static func compute(_ input: Input) -> String {
        let exclusions = input.exclusions
        let ruleSet = input.ruleSet
        let config = input.proxyConfig ?? ProxyConfigMessage(servers: [], activeServerID: nil)
        let canonical = Canonical(
            exclusions: ProcessOriginExclusionMessage(
                identifiers: exclusions.identifiers.sorted(),
                executablePaths: exclusions.executablePaths.sorted(),
                hardBypassIdentifiers: exclusions.hardBypassIdentifiers.sorted(),
                hardBypassExecutablePaths: exclusions.hardBypassExecutablePaths.sorted(),
                hostAppBundlePath: exclusions.hostAppBundlePath
            ),
            proxyConfig: ProxyConfigMessage(
                servers: config.servers.sorted { $0.id < $1.id },
                activeServerID: config.activeServerID
            ),
            routingMode: input.routingMode,
            packetCaptureEnabled: input.packetCaptureEnabled,
            udpPolicy: input.udpPolicy,
            ruleSet: RuleSetMessage(
                assignments: ruleSet.assignments.sorted { $0.processID.value < $1.processID.value },
                matchRules: ruleSet.matchRules
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 六个字段全 Codable、无自定义 encode,编码不可能失败;真失败(未来字段引入不可编码值)
        // 返回哨兵串——两侧同失败仍相等,单侧失败必不等 → 触发 resync,fail-safe 方向正确。
        guard let data = try? encoder.encode(canonical) else { return "encode-failure" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 规范化后的六元组容器——只为确定性编码存在,不进 wire。
    private struct Canonical: Encodable {
        let exclusions: ProcessOriginExclusionMessage
        let proxyConfig: ProxyConfigMessage
        let routingMode: ProxyRoutingModeDTO
        let packetCaptureEnabled: Bool
        let udpPolicy: UDPPolicyDTO
        let ruleSet: RuleSetMessage
    }
}
