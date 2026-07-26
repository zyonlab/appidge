import Darwin
import Foundation

/// 纯、无状态的「Apple 签名/公证基础设施域名」内置强制直连判定：一条 flow 的目的主机若正是
/// Apple 代码签名 / 公证链路依赖的基础设施域名，就必须强制直连（force `.direct`），别送进
/// 用户代理链 —— 无论用户规则怎么写。
///
/// 动机（真实事故，复发三次）：本机跑 `xcodebuild archive` / `codesign` 时，签名的 RFC 3161
/// 时间戳请求（`timestamp.apple.com`）按「配置过代理默认走代理」被送进用户代理链，代理一抖动
/// 就报 "A timestamp was expected but was not found"，archive 直接失败。OCSP/CRL 证书验证被
/// 代理拖慢/打断同样会拖垮 codesign 与 Gatekeeper 校验，公证 API 同理。这些域名走代理毫无
/// 收益、对延迟与抖动极端敏感，故内置排除，一劳永逸。
///
/// 层级：与「自身来源排除」（``ProcessOriginExclusion``，防转发环）、「上游排除」
/// （``UpstreamExclusion``）同级的**硬闸** —— 在扩展 `resolveDecision` 里先于细粒度规则表与
/// 每进程规则生效，用户写了 `*.apple.com → 走代理` 也不影响这几个域名直连（「强制」语义，
/// 不可被用户规则覆盖）。
///
/// 匹配语义：**host 精确整串匹配**、大小写不敏感、容忍首尾空白与单个 FQDN 尾点；**不含子域**、
/// 不做通配。与同为硬闸的 ``UpstreamExclusion`` 对 DNS 主机名的「精确、大小写不敏感」语义对齐。
/// 列表刻意收窄（不加 S3/CDN 通配）：只收「走代理必然有害」的签名/公证基础设施，避免误伤用户
/// 真实想代理的 Apple 域名（如 `www.apple.com`）。
///
/// 无状态、无 I/O（不解析 DNS），可从任意隔离域调用。
public enum AppleInfrastructureExclusion {

    /// 内置强制直连域名。每一项都有明确的「为何在列」；新增前先回答同一问题。
    public static let hosts: Set<String> = [
        // codesign 的 RFC 3161 时间戳服务：签名时同步请求,代理抖动即报
        // "A timestamp was expected but was not found",archive 直接失败(本机三次复发的根因)。
        "timestamp.apple.com",
        // OCSP 证书吊销状态查询:codesign/Gatekeeper 验证证书链时同步访问,被代理拖慢/
        // 打断会拖垮签名与首次启动校验。
        "ocsp.apple.com",
        // 同上,Apple 的第二代 OCSP 端点(现行系统主要访问的就是它)。
        "ocsp2.apple.com",
        // 证书吊销列表(CRL)下载:证书链验证的另一路吊销检查,同样发生在 codesign/Gatekeeper
        // 的同步路径上。
        "crl.apple.com",
        // Apple 证书有效性验证服务(valid.apple.com):证书验证链路的一部分,语义同上。
        "valid.apple.com",
        // notarytool 公证 API(App Store Connect):上传/轮询公证请求,走抖动代理会让
        // 公证超时失败。
        "appstoreconnect.apple.com"
    ]

    /// 目的主机是否命中内置的 Apple 签名/公证基础设施域名（命中即应强制直连）。
    ///
    /// - Parameter host: 目的主机（裸主机名，不是 URL）。`nil`/空/纯空白 → 返回 `false`，
    ///   把决策交回后续的地址判定/规则表。IP 字面量不会命中（列表里只有 DNS 主机名）。
    /// - Returns: 规范化（去首尾空白、去单个 FQDN 尾点、小写化）后精确命中列表返回 `true`。
    public static func isAppleInfrastructure(host: String?) -> Bool {
        guard let host else { return false }
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty else { return false }
        return hosts.contains(normalized)
    }

    // MARK: - IP 字面量硬闸（第四次复发的修复）

    /// 纯 IP flow 的 Apple 签名基础设施判定：codesign 的 RFC 3161 时间戳 flow 到达扩展时
    /// **有时只带 IP、无 remoteHostname**（实测 `17.157.80.35`），上面的域名精确匹配必然
    /// 不命中 → 穿闸进用户代理链，Apple 拒绝（"The timestamp transaction is not permitted
    /// or supported"），archive 以 ~50% 概率失败——同一根因第四次复发。
    ///
    /// 三重收窄（每一重都是「不误伤」的一道边界）：
    /// 1. **仅纯 IP flow**：候选里只要有任何一个域名（非严格 IP 字面量），本闸即不适用——
    ///    域名交给上面的精确域名硬闸与用户规则表裁决。`www.apple.com` 解析到 17/8 时，
    ///    想代理它的用户规则依旧生效（域名候选在场 → 本闸退位）。
    /// 2. **仅 Apple 自有地址段**：IPv4 `17.0.0.0/8`（Apple 整段自有）；IPv6 为公开 RIR
    ///    记录里 Apple Inc. 的自有 /32——`2620:149::/32`（ARIN，实测 2026-07-26
    ///    `timestamp.apple.com` 的 AAAA 落在此段）、`2403:300::/32`（APNIC）、
    ///    `2a01:b740::/32`（RIPE）。非 Apple 地址永不命中。
    /// 3. **仅端口 80**：RFC 3161 时间戳与 OCSP/CRL 都走 HTTP；443 及其他端口交回规则表
    ///    （HTTPS 的 Apple 服务 flow 正常携带主机名，走域名硬闸/规则即可）。
    ///
    /// 与域名硬闸同级的「强制」语义：在扩展 `resolveDecision` 里先于规则表，用户写了该 IP
    /// 走代理的规则也不覆盖——签名基础设施走代理只有害处。
    ///
    /// IP 解析语义与 ``PrivateNetworkExclusion`` 对齐：`inet_pton` 严格解析（拒绝 `17.1`
    /// 缩写与形似域名），容忍首尾空白与 IPv6 方括号。无状态、无 I/O。
    ///
    /// - Parameters:
    ///   - hosts: flow 的全部目标候选（remoteHostname + endpoint host，去 nil 后）。
    ///     空串/纯空白候选忽略;全部候选可忽略或列表为空 → `false`。
    ///   - port: flow 目的端口;`nil`（极少数解析不出）→ `false`，交回后续判定。
    public static func isAppleInfrastructureIPOnlyFlow(hosts: [String], port: UInt16?) -> Bool {
        guard port == 80 else { return false }
        let candidates = hosts
            .map { stripBrackets($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }
        var sawAppleAddress = false
        for candidate in candidates {
            if let v4 = parseIPv4(candidate) {
                sawAppleAddress = sawAppleAddress || v4[0] == 17 // 17.0.0.0/8
            } else if let v6 = parseIPv6(candidate) {
                sawAppleAddress = sawAppleAddress || isAppleIPv6Prefix(v6)
            } else {
                return false // 域名候选在场 → 域名语义优先，本闸不适用。
            }
        }
        return sawAppleAddress
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// `inet_pton` 严格 dotted-quad(拒绝缩写与非数字 label)——与 `PrivateNetworkExclusion`
    /// 一致:形似 IP 的域名绝不能被误读成 IP。
    private static func parseIPv4(_ candidate: String) -> [UInt8]? {
        var addr = in_addr()
        guard candidate.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    private static func parseIPv6(_ candidate: String) -> [UInt8]? {
        var addr = in6_addr()
        guard candidate.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    /// Apple 自有 IPv6 /32 段(前 4 字节整字节比较,/32 恰在字节边界):见
    /// `isAppleInfrastructureIPOnlyFlow` 文档第 2 重收窄的出处。
    private static func isAppleIPv6Prefix(_ bytes: [UInt8]) -> Bool {
        let applePrefixes: [[UInt8]] = [
            [0x26, 0x20, 0x01, 0x49], // 2620:149::/32 (ARIN)
            [0x24, 0x03, 0x03, 0x00], // 2403:300::/32 (APNIC)
            [0x2a, 0x01, 0xb7, 0x40]  // 2a01:b740::/32 (RIPE)
        ]
        return applePrefixes.contains(Array(bytes.prefix(4)))
    }
}
