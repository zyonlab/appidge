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
    /// 路由相关状态变了（每进程规则 / 细粒度规则表），把完整规则集推给扩展。
    /// `assignments` 只含非默认（非 `.direct`）的每进程规则；扩展对未知进程回落 `.direct`。
    case applyRuleSet(assignments: [ProcessID: ProxyRule], matchRules: [ProxyMatchRule])
    /// 抓包开关变了,推给扩展。
    case applyPacketCapture(Bool)
    /// UDP 策略变了,推给扩展。
    case applyUDPPolicy(UDPPolicy)
    /// 来源进程排除名单变了,推给扩展。两档语义(见 `IPCContract.ProcessOriginExclusionMessage`):
    /// `direct` = 端口发现的本地代理 → 接管+强制直连(可见、有字节数);
    /// `hardBypass` = 环检测自愈加入 → 数据通路彻底不接管(最保守,当场断环)。
    case applyProcessOriginExclusions(direct: OriginExclusionDiscovery, hardBypass: OriginExclusionDiscovery)
    /// 用户手动清空了连接日志,app 侧 effectHandler 据此把磁盘上的 `connections.log.jsonl`
    /// 也清空——不然下次启动 `restoreRecentConnectionLog` 又把刚清掉的记录读回来。
    case clearConnectionLogFile
}
