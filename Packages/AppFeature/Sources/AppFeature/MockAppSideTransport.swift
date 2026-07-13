import IPCContract

/// 测试专用：不碰真实 App Group/Darwin 通知，只记录 send 调用，并允许测试用
/// ``simulateIncoming(_:)`` 手动喂一条「扩展推来的消息」，验证监听端的处理逻辑。
public actor MockAppSideTransport: AppSideTransport {
    public private(set) var sentMessages: [AppToExtensionMessage] = []
    private var handler: (@Sendable (ExtensionToAppMessage) -> Void)?

    public init() {}

    public func send(_ message: AppToExtensionMessage) async {
        sentMessages.append(message)
    }

    public func startListening(onMessage: @escaping @Sendable (ExtensionToAppMessage) -> Void) async {
        handler = onMessage
    }

    public func stopListening() async {
        handler = nil
    }

    public func simulateIncoming(_ message: ExtensionToAppMessage) async {
        handler?(message)
    }
}
