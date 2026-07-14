public enum Action: Sendable, Equatable {
    case setGlobalProxyEnabled(Bool)
    case processDiscovered(id: ProcessID, displayName: String, executablePath: String)
    case assignRule(processID: ProcessID, rule: ProxyRule)
    case flowStatsDeltaReceived([ProcessID: FlowStatsDelta])
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
}
