import Testing
import IPCContract
@testable import EngineKit

/// 纯、无状态的「Apple 签名/公证基础设施域名」内置强制直连判定 —— 每条用例都是对
/// `AppleInfrastructureExclusion.isAppleInfrastructure(host:)` 的一次 `#expect`。
///
/// 动机：本机跑 `xcodebuild archive` / `notarytool` 时，codesign 的 RFC 3161 时间戳请求
/// （`timestamp.apple.com`）等签名/公证基础设施流量若按「配置过代理默认走代理」被送进
/// 用户代理链，代理一抖动就报 "A timestamp was expected but was not found"，构建直接失败
/// （已复发三次）。这些域名对代理毫无收益、对稳定性极端敏感，故与回环/上游/自身来源排除
/// **同级**：在扩展 `resolveDecision` 的硬闸阶段命中即 `.bypass`（强制直连），
/// **先于**细粒度规则表与每进程规则 —— 用户即便写了 `*.apple.com → 走代理` 也不影响
/// 这几个域名直连。
///
/// 匹配语义（在测试中固化）：**host 精确整串匹配**、大小写不敏感、容忍首尾空白与单个
/// FQDN 尾点；**不含子域**（`sub.timestamp.apple.com` 不命中）。这与同为硬闸的
/// `UpstreamExclusion` 对 DNS 主机名的「精确、大小写不敏感」语义对齐，也刻意收窄——
/// 不加 S3/CDN 通配，避免误伤用户真实想代理的 Apple 域名（如 `www.apple.com`）。
@Suite("AppleInfrastructureExclusion —— Apple 签名/公证基础设施域名硬闸")
struct AppleInfrastructureExclusionTests {

    // MARK: - 内置列表逐项命中

    @Test(
        "内置六域名逐项命中 → 强制直连",
        arguments: [
            "timestamp.apple.com",        // codesign 时间戳
            "ocsp.apple.com",             // 证书吊销状态（OCSP）
            "ocsp2.apple.com",            // 证书吊销状态（OCSP，第二代端点）
            "crl.apple.com",              // 证书吊销列表
            "valid.apple.com",            // 证书验证
            "appstoreconnect.apple.com"   // notarytool 公证 API
        ]
    )
    func builtinHostsMatch(host: String) {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: host))
    }

    @Test("内置列表常量与判定一致：列表里每一项自身都命中")
    func hostsConstantIsSelfConsistent() {
        #expect(AppleInfrastructureExclusion.hosts.count == 6)
        for host in AppleInfrastructureExclusion.hosts {
            #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: host))
        }
    }

    // MARK: - 大小写 / 规范化

    @Test("大小写不敏感：TIMESTAMP.Apple.COM 命中")
    func caseInsensitive() {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: "TIMESTAMP.Apple.COM"))
    }

    @Test("FQDN 尾点容忍：timestamp.apple.com. 命中")
    func trailingDotTolerated() {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: "timestamp.apple.com."))
    }

    @Test("首尾空白容忍： ' timestamp.apple.com ' 命中")
    func whitespaceTolerated() {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: " timestamp.apple.com "))
    }

    // MARK: - 精确匹配：不含子域、不做后缀/子串匹配

    @Test(
        "非列表域名不受影响（含子域、上级域、后缀撞名）",
        arguments: [
            "www.apple.com",                    // 用户可能真实想代理的 Apple 域名
            "apple.com",                        // 上级域
            "api.anthropic.com",                // 无关第三方
            "sub.timestamp.apple.com",          // 列表项的子域：精确匹配语义下不命中
            "eviltimestamp.apple.com",          // 后缀撞名（非 . 边界）
            "timestamp.apple.com.evil.com",     // 列表项作为前缀的伪装域
            "timestamp.apple.org"               // TLD 不同
        ]
    )
    func nonListedHostsUnaffected(host: String) {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructure(host: host))
    }

    // MARK: - 边界输入

    @Test("nil / 空串 / 纯空白 → 不命中（交回后续判定）")
    func nilAndEmpty() {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructure(host: nil))
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructure(host: ""))
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructure(host: "   "))
    }

    // MARK: - 与用户规则的优先级语义（文档化固化）

    /// 扩展侧 `resolveDecision` 的判定顺序是：自身来源 → 环旁路 → **本硬闸** → 地址硬闸 →
    /// 规则表/每进程规则。本用例固化前提：用户规则 `*.apple.com → proxied` 在 Glob 语义下
    /// **确实会**命中 `timestamp.apple.com`（即若无本硬闸，该域名会被送进代理链）；而本判定
    /// 与规则表相互独立、在管线中先行，故最终语义是「内置域名强制直连，用户规则无法覆盖」——
    /// 与 loop 排除（自身来源）同级的「强制」语义。
    @Test("用户 *.apple.com 走代理规则会命中列表域名，但本硬闸独立且先行 → 强制直连不被覆盖")
    func builtinExclusionOutranksUserRules() {
        let rule = MatchRuleDTO(
            id: "user-rule", appPattern: "*", hostPattern: "*.apple.com", portRange: nil, rule: .proxied
        )
        // 前提成立：用户规则确实匹配该域名（没有本硬闸时它会走代理）。
        let userVerdict = RuleMatcher.firstMatch([rule], app: "com.apple.dt.Xcode", host: "timestamp.apple.com", port: 443)
        #expect(userVerdict == .proxied)
        // 本硬闸独立命中：扩展管线里它在规则表之前返回 .bypass，用户规则永远轮不到。
        #expect(AppleInfrastructureExclusion.isAppleInfrastructure(host: "timestamp.apple.com"))
    }

    // MARK: - IP 字面量硬闸（第四次复发的修复）：仅纯 IP flow + Apple 自有地址段 + 端口 80

    /// 真实事故 flow：codesign 的 RFC 3161 时间戳请求到达扩展时只带 IP（`17.157.80.35`，
    /// Apple 自有 17.0.0.0/8 段）、无 remoteHostname，域名硬闸不命中 → 穿闸进用户代理链，
    /// Apple 拒绝，archive 以 ~50% 概率失败。
    @Test(
        "纯 IP flow + Apple IPv4 段(17/8) + 端口 80 → 强制直连",
        arguments: [
            "17.157.80.35",     // 2026-07 真实事故观测到的时间戳服务 IP
            "17.0.0.1",         // 段下界内
            "17.255.255.255"    // 段上界内
        ]
    )
    func appleIPv4LiteralOnPort80Matches(ip: String) {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [ip], port: 80))
    }

    /// `timestamp.apple.com` 现网同时发布 AAAA（实测 2026-07-26 解到 `2620:149:980:500::101`）,
    /// 只闸 IPv4 会留下 IPv6 复发口子。三个 /32 都是公开 RIR 记录里 Apple Inc. 的自有分配。
    @Test(
        "纯 IP flow + Apple IPv6 自有段 + 端口 80 → 强制直连（含带方括号形式）",
        arguments: [
            "2620:149:980:500::101",   // 实测 timestamp.apple.com 当前 AAAA（ARIN 2620:149::/32）
            "[2620:149:980:500::101]", // 同上，方括号形式（与 PrivateNetworkExclusion 语义对齐）
            "2403:300::1",             // APNIC 2403:300::/32（Apple 亚太）
            "2a01:b740::1"             // RIPE 2a01:b740::/32（Apple 欧洲）
        ]
    )
    func appleIPv6LiteralOnPort80Matches(ip: String) {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [ip], port: 80))
    }

    @Test(
        "非 Apple IP 不受影响（段边界外 / 公网第三方 / IPv6 邻段）——不误伤用户想代理的流量",
        arguments: [
            "16.255.255.255",        // 17/8 下边界外
            "18.0.0.1",              // 17/8 上边界外
            "8.8.8.8",               // 无关公网 IPv4
            "104.16.132.229",        // 无关 CDN IPv4
            "2620:148::1",           // 2620:149::/32 邻段（低侧）
            "2620:14a::1",           // 2620:149::/32 邻段（高侧）
            "2001:4860:4860::8888"   // 无关公网 IPv6
        ]
    )
    func nonAppleIPLiteralsUnaffected(ip: String) {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [ip], port: 80))
    }

    @Test("端口收窄：Apple IP 但端口非 80（443/8080/nil）→ 不命中，交回规则表")
    func portScopeIsNarrow() {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: ["17.157.80.35"], port: 443))
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: ["17.157.80.35"], port: 8080))
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: ["17.157.80.35"], port: nil))
    }

    /// 收窄的核心：**只要 flow 带任何域名候选，本闸就不适用**——域名交给精确域名硬闸与
    /// 用户规则表裁决。`www.apple.com` 解析到 17/8 且走 80 端口时，想代理它的用户规则
    /// 依旧生效（域名候选在场 → 本闸退位），这就是「不误伤」的实现方式。
    @Test("候选里带域名（即便另一候选是 Apple IP）→ 本闸不适用，域名语义优先")
    func hostnamePresenceDisablesIPGate() {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(
            hosts: ["www.apple.com", "17.157.80.35"], port: 80
        ))
        // 列表域名在场同理：本函数不命中，由既有的域名硬闸（管线中更早的判定）负责 bypass。
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(
            hosts: ["timestamp.apple.com", "17.157.80.35"], port: 80
        ))
    }

    @Test(
        "IP 形似但非严格 IP 字面量 → 按域名对待，本闸不适用",
        arguments: [
            "17.157.80.35.evil.com",  // IP 前缀伪装域名
            "17.1",                   // inet_pton 严格拒绝的缩写形式
            "17.157.80.35 extra"      // 混入杂质
        ]
    )
    func ipLookalikesTreatedAsHostnames(host: String) {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [host], port: 80))
    }

    @Test("边界输入：空候选列表 / 空串与纯空白候选 → 不命中")
    func ipGateNilAndEmpty() {
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [], port: 80))
        #expect(!AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: ["", "   "], port: 80))
    }

    @Test("首尾空白容忍：' 17.157.80.35 ' + 端口 80 命中（与域名判定的规范化语义对齐）")
    func ipWhitespaceTolerated() {
        #expect(AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: [" 17.157.80.35 "], port: 80))
    }

    /// 与域名硬闸相同的「强制」语义：用户即便写了 `17.157.80.35 → 走代理` 的 IP 规则，
    /// 本闸在管线中先于规则表，纯 IP 时间戳 flow 依旧强制直连——签名基础设施走代理
    /// 只有害处，这正是硬闸存在的意义（四次复发的教训）。
    @Test("用户对该 IP 的走代理规则会命中，但本硬闸独立且先行 → 强制直连不被覆盖")
    func ipGateOutranksUserRules() {
        let rule = MatchRuleDTO(
            id: "user-ip-rule", appPattern: "*", hostPattern: "17.157.80.35", portRange: nil, rule: .proxied
        )
        let userVerdict = RuleMatcher.firstMatch(
            [rule], app: "com.apple.dt.Xcode", host: "17.157.80.35", port: 80
        )
        #expect(userVerdict == .proxied)
        #expect(AppleInfrastructureExclusion.isAppleInfrastructureIPOnlyFlow(hosts: ["17.157.80.35"], port: 80))
    }
}
