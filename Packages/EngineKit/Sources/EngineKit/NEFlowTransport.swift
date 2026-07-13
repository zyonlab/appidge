import Foundation
import Network
import IPCContract

/// 生产路径的真实 Transport（E2）：direct 直接放行；proxied 先用 Network.framework
/// 探活上游代理，失败则抛错交给 FlowRouter fail-open。deliver 通过 App Group 共享容器
/// + Darwin 通知推给 app，不依赖 XPC。与 ``MockTransport`` 共用同一份 ``Transport`` 协议——
/// 测试只注入 Mock，这个类型本身不在任何测试里被调用（避免真实网络进测试）。
public final class NEFlowTransport: Transport, @unchecked Sendable {
    private let upstreamEndpoint: NWEndpoint
    private let appGroup: String
    private let lock = NSLock()
    private var appMessageHandler: (@Sendable (AppToExtensionMessage) -> Void)?

    /// App 侧 `AppGroupAppSideTransport.send` 写入的 key；两边各自持有字面量常量
    /// （不是共享引用，因为 EngineKit 不能依赖 AppFeature），跟 `latestMessageKey`
    /// 反方向对称的道理一样。
    private static let incomingAppMessageKey = "AppGroupAppSideTransport.latestAppToExtensionMessage"

    public init(upstreamHost: String, upstreamPort: UInt16, appGroup: String) {
        self.upstreamEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? 443
        )
        self.appGroup = appGroup
    }

    public func forward(
        processID: ProcessIdentifierDTO,
        bytesUp: Int64,
        bytesDown: Int64,
        via rule: ProxyRuleDTO
    ) async throws {
        guard rule == .proxied else { return }
        try await probeUpstream()
    }

    private func probeUpstream() async throws {
        let connection = NWConnection(to: upstreamEndpoint, using: .tcp)
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                case .failed(let error):
                    box.resume(.failure(error))
                case .cancelled:
                    box.resume(.failure(NEFlowTransportError.upstreamUnreachable))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    public func deliver(_ message: ExtensionToAppMessage) async {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(message) else { return }
        defaults.set(data, forKey: Self.latestMessageKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("\(appGroup).extensionToApp" as CFString),
            nil, nil, true
        )
    }

    public static let latestMessageKey = "EngineKit.latestExtensionToAppMessage"

    /// Extension 侧监听 App 发来的消息（规则下发、诊断请求）。跟
    /// AppFeature.AppGroupAppSideTransport.startListening 是同一套 C 回调注册手法
    /// （CFNotificationCenter 的回调必须是不捕获上下文的 C 函数指针，用 Unmanaged
    /// 把 self 转成 opaque pointer 带过去）。不在自动化测试里跑，理由跟
    /// probeUpstream/deliver 一样：需要真实 App Group 沙盒。
    public func startListeningForAppMessages(onMessage: @escaping @Sendable (AppToExtensionMessage) -> Void) {
        lock.withLock { appMessageHandler = onMessage }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<NEFlowTransport>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .handleIncomingAppMessage()
            },
            "\(appGroup).appToExtension" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handleIncomingAppMessage() {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: Self.incomingAppMessageKey),
              let message = try? JSONDecoder().decode(AppToExtensionMessage.self, from: data) else { return }
        let handler = lock.withLock { appMessageHandler }
        handler?(message)
    }
}

public enum NEFlowTransportError: Error, Sendable {
    case upstreamUnreachable
}

/// CheckedContinuation 只能 resume 一次；NWConnection 的 stateUpdateHandler 可能在
/// ready 之后还回调 cancelled，用锁保护避免二次 resume 崩溃。
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
