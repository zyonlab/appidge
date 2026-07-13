public enum Effect: Sendable, Equatable {
    case log(String)
    case runDiagnostic(processID: ProcessID, kinds: [DiagnosticKind])
    case scanDirectory
    /// 代理配置变了，把当前完整的服务器列表 + active 选择推给扩展（app 侧 effectHandler
    /// 翻成 IPCContract 消息经 AppSideTransport 发出）。`servers` 按 id 排序、确定，
    /// 便于测试断言，也让重复推送幂等。
    case applyProxyConfig(servers: [ProxyServer], activeID: ProxyServerID?)
}
