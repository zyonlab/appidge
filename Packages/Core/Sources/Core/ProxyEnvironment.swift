/// 进入时探测到的**代理环境快照**——回答"这台机器上除了 appidge,还有哪些代理层在起作用",
/// 据此告诉用户 appidge 能管哪一层数据的转发、哪些流量会绕过 appidge。
///
/// 铁律(平台限制,本会话实测):appidge 只接管「以直连方式发往远程地址」的出站流量;对回环
/// (`127.0.0.1`)完全瞎。所以任何**主动连本地代理端口**的 app(认系统代理 / 读环境变量的),
/// 其流量走回环 → appidge 看不到也不接管,只能看到本地代理(xray)最终出站那一跳。这个快照
/// 把这些"会造成盲区"的层探测出来,让 UI 如实解释。
///
/// 运行时状态,不持久化(每次进入 / 场景激活时重新探测,因为用户可能中途改系统代理)。
public struct ProxyEnvironment: Sendable, Equatable, Codable {
    /// 系统级代理配置(macOS「网络 → 代理」/ PAC)——认系统代理的 app(Chrome 等)会走它。
    public enum SystemProxy: Sendable, Equatable, Codable {
        /// 没有系统代理:认系统代理的 app 会直连 → appidge 能接管。
        case none
        /// 手动代理(HTTP/HTTPS/SOCKS)。`summary` 是给 UI 的一行摘要,如 `HTTPS 127.0.0.1:7890`。
        case manual(summary: String)
        /// 自动代理配置脚本(PAC)。`url` 是脚本地址。
        case pac(url: String)
    }

    public var systemProxy: SystemProxy
    /// appidge 自身进程环境里设置了的代理相关变量名(HTTP_PROXY 等)。⚠️ 只反映 appidge 的
    /// 环境(GUI 启动时通常为空;从终端启动才带 shell 的导出)——是"终端里可能有代理环境变量"
    /// 的**指示**,不是对其它进程环境的权威读取(那需要 appidge 没有的权限)。
    public var environmentVariables: [String]
    /// 额外的 utun 网络接口名(除 appidge 自己的)——可能是其它 VPN/TUN 型代理(某些 yunti/Clash
    /// TUN 模式)在 IP 层抢流量。best-effort 提示,不做归属断言。
    public var extraTunnelInterfaces: [String]
    /// `extraTunnelInterfaces` 中**带 IPv4 地址**的子集——系统自带的 utun0-3 只有 IPv6
    /// link-local,带 IPv4 的 utun 基本是第三方 VPN/TUN 在实际路由流量(Clash 系 fake-ip TUN
    /// 典型是 198.18.0.1)。与 appidge 接管并存会形成双接管层,fake-ip DNS 进黑洞 = 整机断网
    /// (2026-07 Clash Party 真实反馈),UI 据此出冲突警示。仍是 best-effort:正经 VPN 也带
    /// IPv4,所以只「提醒」不阻断。
    public var routedTunnelInterfaces: [String]

    public init(
        systemProxy: SystemProxy = .none,
        environmentVariables: [String] = [],
        extraTunnelInterfaces: [String] = [],
        routedTunnelInterfaces: [String] = []
    ) {
        self.systemProxy = systemProxy
        self.environmentVariables = environmentVariables
        self.extraTunnelInterfaces = extraTunnelInterfaces
        self.routedTunnelInterfaces = routedTunnelInterfaces
    }

    /// 是否存在"会绕过 appidge 的层":有系统代理、或设了环境变量、或有额外 TUN 接口。
    /// 任一为真 = 部分应用可能不经 appidge(走回环 / 被别的 TUN 抢先),UI 据此提示用户。
    public var hasBypassLayer: Bool {
        systemProxy != .none || !environmentVariables.isEmpty || !extraTunnelInterfaces.isEmpty
    }
}
