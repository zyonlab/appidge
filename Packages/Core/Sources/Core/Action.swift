public enum Action: Sendable, Equatable {
    case setGlobalProxyEnabled(Bool)
    case processDiscovered(id: ProcessID, displayName: String, executablePath: String)
    case assignRule(processID: ProcessID, rule: ProxyRule)
    /// 一批流量增量 + 这一批覆盖的真实时间窗(秒)。reducer 据此更新累计字节,并算出每进程瞬时速率
    /// (增量 ÷ 时间窗);`intervalSeconds <= 0` 时只累计、不更新速率。
    case flowStatsDeltaReceived([ProcessID: FlowStatsDelta], intervalSeconds: Double)
    case engineFailure(reason: String)
    case directoryScanned([DirectoryEntry])
    case requestDiagnostic(processID: ProcessID, kinds: [DiagnosticKind])
    case diagnosticResultReceived(processID: ProcessID, kind: DiagnosticKind, passed: Bool, detail: String)
    case onboardingCompleted
    case appLaunched
    case addProxyServer(ProxyServer)
    case updateProxyServer(ProxyServer)
    case removeProxyServer(ProxyServerID)
    case setActiveProxyServer(ProxyServerID?)
    case setProxyRoutingMode(ProxyRoutingMode)
    case addMatchRule(ProxyMatchRule)
    case removeMatchRule(RuleID)
    case reorderMatchRules([RuleID])
    /// 启用/停用一条规则(保留在表里,不删除)。禁用的规则下发前被过滤,永不参与匹配。
    case setMatchRuleEnabled(id: RuleID, enabled: Bool)
    case connectionEventReceived(ConnectionLogEntry)
    /// 扩展主动检测到疑似转发环(signature = 命中目标)。
    case loopWarningRaised(String)
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
    case proxyProcessIdentitiesResolved(Set<String>)
}
