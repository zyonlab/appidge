import Foundation
import IPCContract

/// 生产路径的真实实现：跟 EngineKit.NEFlowTransport 对称，同一个 App Group 共享
/// UserDefaults + Darwin 通知。这个方向（App 发、Extension 收）用 key
/// `AppGroupAppSideTransport.outgoingMessageKey` + 通知名 `<appGroup>.appToExtension`；
/// 反方向（Extension 发、App 收）复用 EngineKit.NEFlowTransport 已经定的
/// key `EngineKit.latestExtensionToAppMessage` + 通知名 `<appGroup>.extensionToApp`。
/// 不在自动化测试里跑（同 NEFlowTransport 的道理：这里用的是真实 Darwin 通知 C 回调，
/// 需要真实 App Group 沙盒环境）。
public final class AppGroupAppSideTransport: AppSideTransport, @unchecked Sendable {
    public static let outgoingMessageKey = "AppGroupAppSideTransport.latestAppToExtensionMessage"

    private let appGroup: String
    private let lock = NSLock()
    private var messageHandler: (@Sendable (ExtensionToAppMessage) -> Void)?

    public init(appGroup: String) {
        self.appGroup = appGroup
    }

    public func send(_ message: AppToExtensionMessage) async {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(message) else { return }
        defaults.set(data, forKey: Self.outgoingMessageKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("\(appGroup).appToExtension" as CFString),
            nil, nil, true
        )
    }

    public func startListening(onMessage: @escaping @Sendable (ExtensionToAppMessage) -> Void) async {
        lock.withLock { messageHandler = onMessage }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<AppGroupAppSideTransport>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .handleIncomingNotification()
            },
            "\(appGroup).extensionToApp" as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func stopListening() async {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName("\(appGroup).extensionToApp" as CFString),
            nil
        )
        lock.withLock { messageHandler = nil }
    }

    private func handleIncomingNotification() {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: "EngineKit.latestExtensionToAppMessage"),
              let message = try? JSONDecoder().decode(ExtensionToAppMessage.self, from: data) else { return }
        let handler = lock.withLock { messageHandler }
        handler?(message)
    }
}
