import Foundation

public enum Action: Sendable, Equatable {
    case processDiscovered(id: ProcessID, displayName: String, executablePath: String)
    case assignRule(processID: ProcessID, rule: ProxyRule, proxyServerID: ProxyServerID? = nil)
    /// 一批流量增量 + 这一批覆盖的真实时间窗(秒)。reducer 据此更新累计字节,并算出每进程瞬时速率
    /// (增量 ÷ 时间窗);`intervalSeconds <= 0` 时只累计、不更新速率。
    case flowStatsDeltaReceived([ProcessID: FlowStatsDelta], intervalSeconds: Double)
    case engineFailure(reason: String)
    case directoryScanned([DirectoryEntry])
    case requestDiagnostic(processID: ProcessID, kinds: [DiagnosticKind])
    case diagnosticResultReceived(processID: ProcessID, kind: DiagnosticKind, passed: Bool, detail: String)
    case onboardingCompleted
    /// 重新进入首次引导(测试/评估用):把 `hasCompletedOnboarding` 置回 false,主窗口据此显示引导流程。
    case reopenOnboarding
    case appLaunched
    case addProxyServer(ProxyServer)
    case updateProxyServer(ProxyServer)
    case removeProxyServer(ProxyServerID)
    case setActiveProxyServer(ProxyServerID?)
    case setProxyRoutingMode(ProxyRoutingMode)
    case addMatchRule(ProxyMatchRule)
    /// 就地编辑一条已有规则(按 id 定位):替换 进程/主机/端口/动作,**保留原位置与启用态**。
    /// 用于「双击某行改规则」——区别于 `addMatchRule`(那是新增或按三元组去重后置顶)。id 不存在
    /// 时 no-op。
    case updateMatchRule(
        id: RuleID, appPattern: String, hostPattern: String,
        portRange: ClosedRange<UInt16>?, action: ProxyRule, proxyServerID: ProxyServerID? = nil
    )
    case removeMatchRule(RuleID)
    case reorderMatchRules([RuleID])
    /// 启用/停用一条规则(保留在表里,不删除)。禁用的规则下发前被过滤,永不参与匹配。
    case setMatchRuleEnabled(id: RuleID, enabled: Bool)
    case connectionEventReceived(ConnectionLogEntry)
    /// 一批连接事件一次落地(IPCReceiver 按 ~250ms 合并推来,压掉连接表的高频重渲染)。
    /// 语义等价于逐条 `connectionEventReceived`,只是单次 state 变更。
    case connectionEventsReceived([ConnectionLogEntry])
    /// 用户在「活动」页手动清空连接日志(不影响 `processes` 的累计流量/规则——只清这张表)。
    case clearConnectionLog
    /// 扩展主动检测到疑似转发环(signature = 命中目标;processID/executablePath = 触发那条 flow
    /// 的来源双信号,解析不出为 nil)。reducer 据此把来源进程**自动加入旁路排除**并回推扩展
    /// (对齐 Proxifier 的 loop 自愈:检测到环即自动建「该进程 → Direct」),并弹告警条。
    case loopWarningRaised(signature: String, processID: ProcessID?, executablePath: String?)
    /// 用户关闭环告警。
    case dismissLoopWarning
    /// 把 state 清回初始值(切换配置档案时用:先 reset 再 dispatch 新档案的 restorationActions,
    /// 干净替换而非叠加)。运行时/会话状态(进程、连接日志等)一并清掉是预期的。
    case resetState
    /// 开/关逐连接抓包(.dmp)。下发给扩展。
    case setPacketCaptureEnabled(Bool)
    /// 设置 proxied 进程的 UDP 处理策略(拦截/直连/SOCKS5 代理)。下发给扩展。
    case setUDPPolicy(UDPPolicy)
    /// 系统扩展激活状态变化(由 `SystemExtensionActivator` 的 delegate 回调驱动)。纯状态回灌,无副作用。
    case extensionActivationChanged(ExtensionActivation)
    /// App 侧查到了本地代理进程(如 xray/yunti)的签名标识集合(libproc 查监听端口 PID + SecCode
    /// 取签名),用于转发环硬化的「来源进程自动排除」。何时查询由 AppFeature 编排,这里只回灌结果。
    case proxyProcessIdentitiesResolved(OriginExclusionDiscovery)
    /// 进入 / 场景激活时探测到的代理环境快照(系统代理 + 环境变量 + 额外 TUN)。纯状态回灌,
    /// 无副作用——UI 据此解释"appidge 能管哪一层、哪些流量会绕过"。见 ``ProxyEnvironment``。
    case proxyEnvironmentDetected(ProxyEnvironment)
    /// 正在服务会话的扩展进程 XPC 连上时报告的版本。纯状态回灌;app 层据 `extensionNeedsRebind`
    /// 判断会话是否绑在旧 provider 上,是则重启会话重绑(升级自愈)。
    case extensionVersionReported(String)
    /// app 启动时读到的包内嵌扩展版本(期望的最新)。纯状态回灌。
    case bundledExtensionVersionSet(String)
    /// app↔扩展 XPC 通道的可达性翻转(由 AppFeature 的重连退避在「连续掉线过阈值/收到真实消息」
    /// 的翻转沿回调驱动)。纯状态回灌;false = 扩展监听器很可能注册失败(升级换血窗口的竞态,
    /// bootstrap look-up 报 "No such process"),配置推不下去、活动页收不到事件——UI 据
    /// ``AppState/isXPCChannelBroken`` 显式警告,自愈据此有界重启接管一次(见 ``StaleBindingHealDecision``)。
    case xpcChannelReachabilityChanged(Bool)
    /// 把当前完整配置**全量重推**给扩展(规则表 + 每进程规则 + 代理配置 + 路由模式 + 抓包 +
    /// UDP 策略 + 排除名单)。用途:app↔扩展的 XPC(重)连上时、或启动恢复完成后触发一次,
    /// 保证扩展手里的配置永远是最新的——不然扩展升级/重启/XPC 掉线重连后,它会一直空转
    /// (每条 flow 回落默认直连、什么都不接管)。纯粹的"重发",不改任何 state。
    case resyncExtension

    // MARK: - 授权（License）状态机

    /// 用户粘贴 key 后请求激活。instanceName/appVersion 由 App 层配置注入到 effect handler，
    /// 这里只带 key（View 只提供 key）。→ 相位 `.activating`，产出 `.activateLicense` effect。
    case licenseActivateRequested(licenseKey: String)
    /// 激活成功（携带回显的 key + 服务端响应 + 本地 now）。→ 依 status 落 licensed/expired/revoked。
    case licenseActivateSucceeded(licenseKey: String, response: LicenseResponse, now: Date)
    /// 激活失败（已归类）。→ 依类型落 recoverableError/expired/revoked。
    case licenseActivateFailed(LicenseActivationFailure)
    /// 请求例行校验（携带本地 now）。→ 相位 `.validating`，产出 `.validateLicense` effect。
    case licenseValidateRequested(now: Date)
    /// 校验成功。→ 更新记录并依 status 落 licensed/expired/revoked。
    case licenseValidateSucceeded(response: LicenseResponse, now: Date)
    /// 校验失败（已归类，携带本地 now）。→ revoked/expired 锁定；transient 进 grace 或耗尽落 expired。
    case licenseValidateFailed(LicenseValidationFailure, now: Date)
    /// 请求本机停用。→ 相位 `.deactivating`，产出 `.deactivateLicense` effect。
    case licenseDeactivateRequested
    /// 停用成功。→ 清空记录，落 `.unlicensed`，清 Keychain。
    case licenseDeactivateSucceeded
    /// 停用失败（transient=是否暂时性）。→ 保留授权、回落 `.licensed`，允许重试（不误锁）。
    case licenseDeactivateFailed(transient: Bool)
    /// 启动请求从 Keychain 恢复授权记录。→ 产出 `.loadPersistedLicense` effect（结果经 `.licenseRestored` 回灌）。
    case licenseLoadRequested
    /// 启动从 Keychain 读回记录（可能为 nil，携带本地 now）。→ 依记录 + 宽限窗口计算初始相位。
    case licenseRestored(LicenseInfo?, now: Date)
    /// 周期性时钟推进（携带本地 now）。纯本地判定：抬高水位、宽限耗尽/订阅到期 → 落 expired；不发网络。
    case licenseClockTick(now: Date)
    /// 请求购买（打开稳定购买入口）。checkoutURL 由 App 层构建期配置提供。→ 产出 `.openCheckout`。
    case licensePurchaseRequested(checkoutURL: String)
    /// Keychain 持久化失败。普通保存失败不锁当前会话；停用清除失败时 Keychain handler 已先写
    /// revoked tombstone，保证旧 active 记录不会在下次启动复活。
    case licensePersistenceFailed(LicensePersistenceOperation)

    // MARK: - 试用（Trial）状态机

    /// 启动请求读取本地试用锚点。→ 产出 `.loadTrialAnchors` effect（App 侧读两锚点后经 `.trialResolved` 回灌）。
    case trialLoadRequested
    /// 读回全部试用锚点（可能为空=首启；携带本地 now）。→ 合并取较早 firstLaunchAt/最高水位，
    /// 首启记名并落 `.trial(daysLeft:)`，后续按锚点算 `.trial`/`.trialExpired`；仅在未激活时生效。
    case trialResolved(anchors: [TrialInfo], now: Date)
}
