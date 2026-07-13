import IPCContract

/// App 侧 IPC 出口：既能把 AppToExtensionMessage 送给扩展（规则下发、诊断请求），
/// 也能监听扩展推来的 ExtensionToAppMessage（流量批量上报、诊断结果、engineFailure）。
/// 跟 EngineKit.Transport 是同一套设计——生产路径用真实实现，测试只注入 Mock。
public protocol AppSideTransport: Sendable {
    func send(_ message: AppToExtensionMessage) async
    func startListening(onMessage: @escaping @Sendable (ExtensionToAppMessage) -> Void) async
    func stopListening() async
}
