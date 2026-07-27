import Foundation

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
    /// app↔扩展 XPC 通道当前是否可达。默认 true——没有失败证据前不误报。由 AppFeature 的
    /// 重连退避在翻转沿回灌(连续掉线过阈值 → false;收到扩展任何真实消息 → true)。
    /// false 的典型根因:升级换血窗口的竞态让新扩展进程的 `NSXPCListener` 注册失败,
    /// app 侧 bootstrap look-up 报 "No such process"(2026-07-26 真机实锤,80→81 升级 100% 复现)。
    /// 运行时状态,不持久化。
    public var isXPCChannelReachable: Bool

    /// 授权状态机相位（见 ``LicensePhase`` / CLAUDE.md §5.5）。默认未激活。
    /// **和网络接管完全解耦**：授权服务故障绝不影响转发/路由，付费能力只在 `isLicenseActive` 时开放。
    public var licensePhase: LicensePhase
    /// 本地授权记录（存 Keychain）。相位为 licensed/validating/gracePeriod/deactivating 时非 nil。
    public var license: LicenseInfo?
    /// 试用时长配置（默认 7 天）。App 层从 Info.plist `TrialDurationDays` 注入。
    public var trialConfig: TrialConfig
    /// 本地试用锚点（合并两处冗余锚点后的当前视图）。相位为 `.trial`/`.trialExpired` 时非 nil。
    public var trial: TrialInfo?
    /// 授权/试用相位是否已完成启动恢复（Keychain 授权记录 + 试用锚点都读回并落定）。
    /// 默认 false——初始的 `.unlicensed` 只是「还没读」，不是「真没授权」；UI 据此在落定前
    /// **不渲染授权门**（否则试用期用户每次启动都会闪一下"输入许可证"锁屏）。恢复链的最后
    /// 一环是 `.trialResolved`（本地读锚点、必然回灌），由它置真。运行时状态,不持久化。
    public var isLicensePhaseResolved: Bool = false

    /// 会话绑定的扩展是不是旧的:两者都已知且不相等 = 会话绑在旧 provider 上,需重启会话重绑。
    /// 任一未知(还没握手 / 读不到包内版本)时返回 false——不确定就不误报。
    public var extensionNeedsRebind: Bool {
        guard let running = runningExtensionVersion, let bundled = bundledExtensionVersion else { return false }
        return running != bundled
    }

    /// XPC 通道故障(UI 显式警告的判据):扩展明明在跑(含 pending-reboot 的旧版本——它也该
    /// 能通 XPC),通道却不可达。此时配置推不进扩展(排除名单为空 → 本地代理流量被全量接管的
    /// 性能地雷)、连接事件送不回 app(活动页永远空白但引擎显示 OK)。扩展没在跑(停用/待批准)
    /// 或功能未开放时不算此故障——那些状态有各自的提示,不重复打扰。
    public var isXPCChannelBroken: Bool {
        isLicenseActive && hasCompletedOnboarding
            && extensionActivation.isRunning && !isXPCChannelReachable
    }

    /// 下发给扩展的两档排除(直连档 = 端口发现;完全旁路档 = 环自愈)。
    public var originExclusionsPush: Effect {
        .applyProcessOriginExclusions(direct: dynamicOriginExclusion, hardBypass: loopAutoExclusions)
    }

    /// 授权能力是否开放。**只有** licensed/validating/gracePeriod/deactivating 放行——
    /// 校验/停用在途保留既有访问（乐观），上游不可用进 gracePeriod 仍放行；
    /// 只有明确的 revoked/expired（及未激活/激活中/可恢复错误）才关闭付费能力。
    public var isLicenseActive: Bool {
        switch licensePhase {
        case .licensed, .gracePeriod, .deactivating:
            return true
        case .trial:
            // 试用期功能开放。
            return true
        case .validating:
            // expired 记录也允许发起恢复校验，但校验在途不能借 `.validating` 暂时解锁。
            return license?.status == .active
        case .unlicensed, .activating, .revoked, .expired, .recoverableError, .trialExpired:
            return false
        }
    }

    /// 连接日志保留的最大条数;超出丢最旧。
    public static let connectionLogCap = 500

    /// 离线宽限窗口，集中配置，默认 **7 天**（见 CLAUDE.md §5.5）。上游暂时不可用期间，
    /// 距上次成功校验在此窗口内一律放行；超出才落 `expired`。
    public static let licenseGracePeriod: TimeInterval = 7 * 24 * 60 * 60
    /// 例行校验间隔，默认每日一次。是否到期由 App 层调度器据此判断。
    public static let licenseValidateInterval: TimeInterval = 24 * 60 * 60

    /// 是否到了该做一次例行/恢复校验。已授权与 grace 按每日间隔校验；expired 仍保留记录，
    /// 也必须继续尝试，以便续订或网络恢复后回到 licensed。revoked 永不自动解锁。
    public func isValidateDue(now: Date) -> Bool {
        guard let info = license else { return false }
        switch licensePhase {
        case .licensed, .gracePeriod, .expired:
            break
        case .unlicensed, .activating, .validating, .deactivating, .revoked, .recoverableError,
             .trial, .trialExpired:
            return false
        }
        return info.referenceNow(now).timeIntervalSince(info.lastValidatedAt) >= Self.licenseValidateInterval
    }

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
        bundledExtensionVersion: String? = nil,
        isXPCChannelReachable: Bool = true,
        licensePhase: LicensePhase = .unlicensed,
        license: LicenseInfo? = nil,
        trialConfig: TrialConfig = .default,
        trial: TrialInfo? = nil
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
        self.isXPCChannelReachable = isXPCChannelReachable
        self.licensePhase = licensePhase
        self.license = license
        self.trialConfig = trialConfig
        self.trial = trial
    }
}
