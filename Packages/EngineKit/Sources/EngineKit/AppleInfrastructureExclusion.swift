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
}
