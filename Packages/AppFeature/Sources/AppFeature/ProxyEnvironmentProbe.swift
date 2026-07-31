import Core
import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// 探测当前**代理环境**(系统代理 + 环境变量 + 额外 TUN 接口),产出 `Core.ProxyEnvironment`
/// 供 UI 解释"appidge 能管哪一层"。跟 `LocalProxyOriginDiscovery` / `ProxyReachability` 同一
/// 套设计:一个协议、一个真实实现、一个可注入 mock,纯解析逻辑单独抽出可测。
public protocol ProxyEnvironmentProbing: Sendable {
    func probe() async -> Core.ProxyEnvironment
}

/// 系统代理设置字典 → `ProxyEnvironment.SystemProxy` 的**纯解析**(与 I/O 分开,可用普通字典
/// 单测)。字典就是 `CFNetworkCopySystemProxySettings()` / `SCDynamicStoreCopyProxies` 返回的
/// 那份(键名是 `kSCPropNetProxies*` 的字符串常量),PAC 优先于手动代理(macOS 求值顺序)。
public enum SystemProxyParser {
    // 直接用字符串键,避免 UI/测试都得 import SystemConfiguration;键名是稳定的公开常量。
    static let pacEnableKey = "ProxyAutoConfigEnable"
    static let pacURLKey = "ProxyAutoConfigURLString"
    static let httpsEnableKey = "HTTPSEnable"
    static let httpsProxyKey = "HTTPSProxy"
    static let httpsPortKey = "HTTPSPort"
    static let httpEnableKey = "HTTPEnable"
    static let httpProxyKey = "HTTPProxy"
    static let httpPortKey = "HTTPPort"
    static let socksEnableKey = "SOCKSEnable"
    static let socksProxyKey = "SOCKSProxy"
    static let socksPortKey = "SOCKSPort"

    public static func parse(_ settings: [String: Any]) -> Core.ProxyEnvironment.SystemProxy {
        if intFlag(settings[pacEnableKey]), let url = settings[pacURLKey] as? String, !url.isEmpty {
            return .pac(url: url)
        }
        // 手动代理:HTTPS / HTTP / SOCKS 任一启用即报,拼一行摘要(可能多协议,全列出)。
        var parts: [String] = []
        appendEndpoint(&parts, label: "HTTPS", enable: settings[httpsEnableKey],
                       host: settings[httpsProxyKey], port: settings[httpsPortKey])
        appendEndpoint(&parts, label: "HTTP", enable: settings[httpEnableKey],
                       host: settings[httpProxyKey], port: settings[httpPortKey])
        appendEndpoint(&parts, label: "SOCKS", enable: settings[socksEnableKey],
                       host: settings[socksProxyKey], port: settings[socksPortKey])
        return parts.isEmpty ? .none : .manual(summary: parts.joined(separator: " · "))
    }

    private static func appendEndpoint(
        _ parts: inout [String], label: String, enable: Any?, host: Any?, port: Any?
    ) {
        guard intFlag(enable), let host = host as? String, !host.isEmpty else { return }
        let portText = (port as? Int).map { ":\($0)" } ?? (port as? String).map { ":\($0)" } ?? ""
        parts.append("\(label) \(host)\(portText)")
    }

    /// SystemConfiguration 的布尔标志是 `CFNumber`(0/1);兼容 Int/Bool/NSNumber。
    private static func intFlag(_ value: Any?) -> Bool {
        if let n = value as? Int { return n != 0 }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return false
    }
}

/// 代理相关环境变量的规范名单(与诊断器 `envConflict` 同一组)。
public enum ProxyEnvironmentKeys {
    public static let all = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
}

/// utun 分类的纯逻辑(getifaddrs 的枚举本身不可测,判定单独拆出可测):
/// 同名 utun 任一地址是 IPv4 即算「活跃路由」——系统自带的 utun0-3 只有 IPv6 link-local,
/// 带 IPv4 的基本是第三方 VPN/TUN 在实际抢流量(Clash 系 fake-ip TUN 典型是 198.18.0.1)。
public enum TunnelInterfaceClassifier {
    public static func routedTunnels(_ entries: [(name: String, hasIPv4: Bool)]) -> [String] {
        var routed: Set<String> = []
        for entry in entries where entry.name.hasPrefix("utun") && entry.hasIPv4 {
            routed.insert(entry.name)
        }
        return routed.sorted()
    }
}

/// 真实探测:系统代理走 `CFNetworkCopySystemProxySettings`,环境变量读自身进程,
/// TUN 接口枚举 `getifaddrs` 里的 `utun*`。不在自动化测试里跑(需真实系统 API);解析逻辑
/// 已在 `SystemProxyParser` / `ProxyEnvironmentKeys` / `TunnelInterfaceClassifier` 里单独可测。
public struct SystemProxyEnvironmentProbe: ProxyEnvironmentProbing {
    public init() {}

    public func probe() async -> Core.ProxyEnvironment {
        let interfaces = currentInterfaceSnapshot()
        return Core.ProxyEnvironment(
            systemProxy: currentSystemProxy(),
            environmentVariables: currentEnvironmentProxyKeys(),
            extraTunnelInterfaces: Set(interfaces.filter { $0.name.hasPrefix("utun") }.map(\.name)).sorted(),
            routedTunnelInterfaces: TunnelInterfaceClassifier.routedTunnels(interfaces)
        )
    }

    private func currentSystemProxy() -> Core.ProxyEnvironment.SystemProxy {
        #if canImport(SystemConfiguration)
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
            as? [String: Any] else { return .none }
        return SystemProxyParser.parse(settings)
        #else
        return .none
        #endif
    }

    private func currentEnvironmentProxyKeys() -> [String] {
        let env = ProcessInfo.processInfo.environment
        return ProxyEnvironmentKeys.all.filter { env[$0]?.isEmpty == false }
    }

    /// getifaddrs 全量快照:每条地址一项(接口名 + 是否 IPv4)。utun 过滤与活跃判定
    /// 交给可测的 `TunnelInterfaceClassifier`。
    private func currentInterfaceSnapshot() -> [(name: String, hasIPv4: Bool)] {
        var entries: [(name: String, hasIPv4: Bool)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0 else { return [] }
        defer { freeifaddrs(ptr) }
        var cursor = ptr
        while let current = cursor {
            if let namePtr = current.pointee.ifa_name {
                let family = current.pointee.ifa_addr?.pointee.sa_family
                entries.append((String(cString: namePtr), family == sa_family_t(AF_INET)))
            }
            cursor = current.pointee.ifa_next
        }
        return entries
    }
}

/// 测试用:回一个预置快照。
public struct MockProxyEnvironmentProbe: ProxyEnvironmentProbing {
    private let snapshot: Core.ProxyEnvironment
    public init(_ snapshot: Core.ProxyEnvironment) { self.snapshot = snapshot }
    public func probe() async -> Core.ProxyEnvironment { snapshot }
}
