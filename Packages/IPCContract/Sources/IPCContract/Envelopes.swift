public enum AppToExtensionMessage: Sendable, Equatable, Codable {
    case applyRuleSet(RuleSetMessage)
    case requestDiagnostic(DiagnosticRequestDTO)
    case applyProxyConfig(ProxyConfigMessage)
    case applyRoutingMode(ProxyRoutingModeDTO)
    /// 开/关逐连接抓包(.dmp)。
    case setPacketCapture(Bool)
    /// 设置 proxied 进程的 UDP 处理策略。
    case setUDPPolicy(UDPPolicyDTO)
    /// 动态发现的本地代理进程签名标识集合(转发环硬化的「来源进程自动排除」)。
    case applyProcessOriginExclusions(ProcessOriginExclusionMessage)
}

public enum ExtensionToAppMessage: Sendable, Equatable, Codable {
    case flowStatsBatch(FlowStatsBatchMessage)
    case diagnosticResult(DiagnosticResultDTO)
    case engineFailure(reason: String)
    case connectionEvent(ConnectionEventDTO)
    /// 主动检测到疑似转发环(同一目标在极短窗口内被反复捕获)。`signature` 是命中的目标标识,
    /// 供 app 提示用户;`processID`/`executablePath` 是触发检测的那条 flow 的来源双信号
    /// (解析不出时为 nil)——app 据此**自动把来源进程加入旁路排除**并回推扩展,对齐 Proxifier
    /// 检测到环后自动创建「该进程 → Direct」置顶规则的自愈行为。补充被动的回环/上游/来源排除,
    /// 是兜底安全网。
    case loopDetected(signature: String, processID: ProcessIdentifierDTO?, executablePath: String?)
}
