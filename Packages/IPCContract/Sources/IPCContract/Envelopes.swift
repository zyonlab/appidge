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
    /// 扩展 `startProxy` 时向 app 报告自己的版本(`CFBundleVersion`)——app 拿它跟包内嵌扩展版本
    /// 比对,检测"会话绑在旧 provider 上"的僵尸态(反复热升级后系统把流量交给待卸载的旧实例)。
    case extensionReady(version: String)
    /// 扩展报告**已落地配置**的指纹(``ConfigFingerprint``,三个时机:apply 落地后防抖上报 /
    /// 版本回报同批 / 低频心跳)。app 与「用当前 state 生成的期望指纹」比对,不一致 ⟹ 配置分叉
    /// ⟹ 全量 resync 自愈——推送是 fire-and-forget,这条对账闭环把「静默分叉」压缩到最多
    /// 一个上报周期。旧版 app 解不出这个 case 会整体丢弃该消息,安全降级。
    case configFingerprintReported(String)
}
