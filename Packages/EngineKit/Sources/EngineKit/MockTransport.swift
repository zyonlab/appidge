import IPCContract

public struct ForwardCall: Sendable, Equatable {
    public let processID: ProcessIdentifierDTO
    public let bytesUp: Int64
    public let bytesDown: Int64
    public let rule: ProxyRuleDTO
}

public enum MockTransportError: Error, Sendable {
    case forwardFailed
}

/// 测试专用 Transport：不碰真实网络/NE，只记录调用并可配置性失败，供确定性断言。
public actor MockTransport: Transport {
    public private(set) var forwardCalls: [ForwardCall] = []
    public private(set) var deliveredMessages: [ExtensionToAppMessage] = []
    private var failurePredicate: (@Sendable (ProcessIdentifierDTO, ProxyRuleDTO) -> Bool)?

    public init() {}

    public func failForwards(matching predicate: @escaping @Sendable (ProcessIdentifierDTO, ProxyRuleDTO) -> Bool) {
        failurePredicate = predicate
    }

    public func forward(
        processID: ProcessIdentifierDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        via rule: ProxyRuleDTO
    ) async throws {
        forwardCalls.append(ForwardCall(processID: processID, bytesUp: bytesUp, bytesDown: bytesDown, rule: rule))
        if let failurePredicate, failurePredicate(processID, rule) {
            throw MockTransportError.forwardFailed
        }
    }

    public func deliver(_ message: ExtensionToAppMessage) async {
        deliveredMessages.append(message)
    }
}
