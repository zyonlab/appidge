public enum Effect: Sendable, Equatable {
    case log(String)
    case runDiagnostic(processID: ProcessID, kinds: [DiagnosticKind])
    case scanDirectory
    /// 代理配置变了，把当前完整的服务器列表 + active 选择推给扩展（app 侧 effectHandler
    /// 翻成 IPCContract 消息经 AppSideTransport 发出）。`servers` 按 id 排序、确定，
    /// 便于测试断言，也让重复推送幂等。
    case applyProxyConfig(servers: [ProxyServer], activeID: ProxyServerID?)
    /// 代理路由模式变了,推给扩展(单独一条消息,不和 applyProxyConfig 混)。
    case applyRoutingMode(ProxyRoutingMode)
    /// 路由相关状态变了（全局开关 / 每进程规则 / 细粒度规则表），把完整规则集推给扩展。
    /// `assignments` 只含非默认（非 `.direct`）的每进程规则；扩展对未知进程回落 `.direct`。
    case applyRuleSet(globalProxyEnabled: Bool, assignments: [ProcessID: ProxyRule], matchRules: [ProxyMatchRule])
    /// 抓包开关变了,推给扩展。
    case applyPacketCapture(Bool)
    /// UDP 策略变了,推给扩展。
    case applyUDPPolicy(UDPPolicy)
    /// 动态发现的本地代理进程签名标识集合变了,推给扩展跟自身 app/扩展的标识合并,扩展侧命中
    /// 即强制直连(转发环硬化的「来源进程自动排除」，见 `EngineKit.ProcessOriginExclusion`)。
    case applyProcessOriginExclusions(OriginExclusionDiscovery)
}
