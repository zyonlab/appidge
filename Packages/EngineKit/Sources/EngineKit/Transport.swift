import IPCContract

/// EngineKit 对外的唯一网络/IPC 出口协议：转发单个 flow 的字节到目的地，
/// 以及把批量计量 DTO / 诊断结果 / engineFailure 推给 app。
/// 生产路径由真实 transport 实现，测试全部注入 ``MockTransport``。
public protocol Transport: Sendable {
    func forward(
        processID: ProcessIdentifierDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        via rule: ProxyRuleDTO
    ) async throws

    func deliver(_ message: ExtensionToAppMessage) async
}
