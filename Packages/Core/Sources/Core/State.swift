public struct AppState: Sendable, Equatable {
    public var isEngineHealthy: Bool
    public var processes: [ProcessID: MonitoredProcess]
    public var catalog: [ProcessID: DirectoryEntry]
    public var diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]]
    public var hasCompletedOnboarding: Bool
    public var proxyServers: [ProxyServerID: ProxyServer]
    public var activeProxyServerID: ProxyServerID?
    /// 代理流量如何使用上游(单台 / 链 / 故障转移 / 负载均衡)。默认 `.single`,用 activeProxyServerID。
    public var proxyRoutingMode: ProxyRoutingMode
    /// 细粒度规则表(进程 × 主机 × 端口),从上到下求值、首个命中生效。见 ``RuleMatcher``。
    public var rules: [ProxyMatchRule]
    /// 每连接日志(按连接 id 去重更新),环形缓冲上限 ``connectionLogCap``。
    public var connectionLog: [ConnectionLogEntry]
    /// 主动环检测的当前告警(命中的目标标识);nil = 无告警。UI 据此弹提示,用户可 dismiss。
    public var loopWarning: String?
    /// 用户已「忽略」过的环告警 signature——同一 signature 不再重复弹(运行时状态,不持久化;
    /// 重启后同一问题若还在,再提醒一次是合理的)。
    public var dismissedLoopSignatures: Set<String>
    /// 是否逐连接抓包落 `.dmp`(默认关——抓包占磁盘且涉隐私,显式开)。开关下发给扩展。
    public var isPacketCaptureEnabled: Bool
    /// proxied 进程的 UDP/QUIC 怎么处理(默认 `.block` 止漏)。下发给扩展。
    public var udpPolicy: UDPPolicy
    /// 系统扩展的安装/批准/运行状态。运行时状态,不持久化(和 `isEngineHealthy` 一样),
    /// 启动时由 `SystemExtensionActivator` 查询回填。状态栏据此如实显示是否已接管。见 ``ExtensionActivation``。
    public var extensionActivation: ExtensionActivation
    /// 动态发现的本地代理进程(如 xray/yunti)——签名标识 + 可执行文件路径,由 AppFeature 用
    /// libproc+SecCode 查到、经 `.proxyProcessIdentitiesResolved` 回灌。与静态的 app/扩展自身
    /// 标识/路径合并后下发给扩展,任一信号命中即强制直连。运行时发现的结果,不持久化(重启后重新查)。
    public var dynamicOriginExclusion: OriginExclusionDiscovery
    /// **环检测自愈**加入的排除:扩展报告疑似转发环时,把触发 flow 的来源进程双信号自动收进来
    /// (对齐 Proxifier「检测到环 → 自动建该进程 Direct 置顶规则」的行为)。与 `dynamicOriginExclusion`
    /// 分开存——后者每次 applyProxyConfig 都会被发现结果**整体替换**,自愈加的不能被冲掉;
    /// 语义也不同档:发现档 = 接管+强制直连(可见),自愈档 = 完全旁路(最保守,当场断环)。
    /// 运行时状态,不持久化。
    public var loopAutoExclusions: OriginExclusionDiscovery
    /// 进入 / 场景激活时探测到的代理环境(系统代理 + 环境变量 + 额外 TUN)——UI 据此解释
    /// "appidge 能管哪一层、哪些流量会绕过"。运行时状态,不持久化。见 ``ProxyEnvironment``。
    public var proxyEnvironment: ProxyEnvironment
    /// **正在服务当前会话的扩展进程**报告的版本(XPC 连上时回报);nil = 还没连上/没回报。
    /// 与 `bundledExtensionVersion` 比对,检测"会话绑在旧 provider 上"的僵尸态(反复热升级后
    /// 系统可能把流量交给待卸载的旧实例 → 黑洞)。运行时状态,不持久化。
    public var runningExtensionVersion: String?
    /// **app 包内嵌的扩展**版本(启动时从 embedded `.systemextension` 读)——期望的最新版本。
    /// 运行时状态,不持久化。
    public var bundledExtensionVersion: String?

    /// 会话绑定的扩展是不是旧的:两者都已知且不相等 = 会话绑在旧 provider 上,需重启会话重绑。
    /// 任一未知(还没握手 / 读不到包内版本)时返回 false——不确定就不误报。
    public var extensionNeedsRebind: Bool {
        guard let running = runningExtensionVersion, let bundled = bundledExtensionVersion else { return false }
        return running != bundled
    }

    /// 下发给扩展的两档排除(直连档 = 端口发现;完全旁路档 = 环自愈)。
    public var originExclusionsPush: Effect {
        .applyProcessOriginExclusions(direct: dynamicOriginExclusion, hardBypass: loopAutoExclusions)
    }

    /// 连接日志保留的最大条数;超出丢最旧。
    public static let connectionLogCap = 500

    public init(
        isEngineHealthy: Bool = true,
        processes: [ProcessID: MonitoredProcess] = [:],
        catalog: [ProcessID: DirectoryEntry] = [:],
        diagnostics: [ProcessID: [DiagnosticKind: DiagnosticOutcome]] = [:],
        hasCompletedOnboarding: Bool = false,
        proxyServers: [ProxyServerID: ProxyServer] = [:],
        activeProxyServerID: ProxyServerID? = nil,
        proxyRoutingMode: ProxyRoutingMode = .single,
        rules: [ProxyMatchRule] = [],
        connectionLog: [ConnectionLogEntry] = [],
        loopWarning: String? = nil,
        dismissedLoopSignatures: Set<String> = [],
        isPacketCaptureEnabled: Bool = false,
        udpPolicy: UDPPolicy = .block,
        extensionActivation: ExtensionActivation = .inactive,
        dynamicOriginExclusion: OriginExclusionDiscovery = OriginExclusionDiscovery(),
        loopAutoExclusions: OriginExclusionDiscovery = OriginExclusionDiscovery(),
        proxyEnvironment: ProxyEnvironment = ProxyEnvironment(),
        runningExtensionVersion: String? = nil,
        bundledExtensionVersion: String? = nil
    ) {
        self.isEngineHealthy = isEngineHealthy
        self.processes = processes
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.proxyServers = proxyServers
        self.activeProxyServerID = activeProxyServerID
        self.proxyRoutingMode = proxyRoutingMode
        self.rules = rules
        self.connectionLog = connectionLog
        self.loopWarning = loopWarning
        self.dismissedLoopSignatures = dismissedLoopSignatures
        self.isPacketCaptureEnabled = isPacketCaptureEnabled
        self.udpPolicy = udpPolicy
        self.extensionActivation = extensionActivation
        self.dynamicOriginExclusion = dynamicOriginExclusion
        self.loopAutoExclusions = loopAutoExclusions
        self.proxyEnvironment = proxyEnvironment
        self.runningExtensionVersion = runningExtensionVersion
        self.bundledExtensionVersion = bundledExtensionVersion
    }
}
