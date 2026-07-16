import Foundation
import Network
import IPCContract

/// 生产路径的真实 Transport（E2 的 XPC 版）：`forward()` 跟 ``NEFlowTransport`` 完全一致
/// （direct 直接放行；proxied 用 Network.framework 探活上游代理，失败交给 FlowRouter
/// fail-open），唯一的区别是 IPC 传输机制——App↔扩展改走 XPC（`IPCContract.XPCTransportConfig`
/// 的 mach service），不再用 App Group UserDefaults + Darwin 通知（那条路径在 sysex 上不通，
/// 见 ``NEFlowTransport`` 和 `IPCContract/XPCTransport.swift` 的注释）。
///
/// 并发安全用显式 `NSLock`，不用 actor：这个类型要 conform `@objc protocol`
/// （`ExtensionXPCProtocol`）并被 XPC runtime 在任意队列上调用，跟 actor 隔离域不兼容；
/// 这是这个代码库贯穿全局的写法（参考 ``NEFlowTransport`` 自己、
/// `Extension/ProxyExtensionProvider.swift` 的 `configLock`）。
public final class XPCFlowTransport: NSObject, Transport, ExtensionXPCProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let upstreamEndpoint: NWEndpoint
    private let lock = NSLock()
    private var appMessageHandler: (@Sendable (AppToExtensionMessage) -> Void)?
    private var currentConnection: NSXPCConnection?
    private var listener: NSXPCListener?

    public init(upstreamHost: String, upstreamPort: UInt16) {
        self.upstreamEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? 443
        )
        super.init()
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
                    box.resume(.failure(XPCFlowTransportError.upstreamUnreachable))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    /// 通过当前已连接的 XPC connection 把消息推给 App。拿不到连接（还没人连上、
    /// 或连接已失效）就静默不发——跟 ``NEFlowTransport.deliver`` 在拿不到 UserDefaults
    /// 时直接 return 的容错哲学一致，`deliver` 签名本来就不 throw。
    public func deliver(_ message: ExtensionToAppMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let connection = lock.withLock { currentConnection }
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // App 端不可达（尚未连接、已断开）：静默丢弃，不崩溃。
        } as? AppXPCProtocol
        proxy?.send(data)
    }

    /// Extension 侧监听 App 发来的消息（规则下发、诊断请求）：建 `NSXPCListener`，
    /// 收到连接就接受，收到消息就解码回调。不在自动化测试里跑，理由跟
    /// ``NEFlowTransport`` 一样——需要真实跨进程 XPC，SPM 测试环境跑不出来。
    public func startListeningForAppMessages(onMessage: @escaping @Sendable (AppToExtensionMessage) -> Void) {
        lock.withLock { appMessageHandler = onMessage }

        let listener = NSXPCListener(machServiceName: XPCTransportConfig.machServiceName)
        listener.delegate = self
        lock.withLock { self.listener = listener }
        listener.resume()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ExtensionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: AppXPCProtocol.self)

        newConnection.interruptionHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }

        lock.withLock { currentConnection = newConnection }
        newConnection.resume()
        return true
    }

    private func clearConnection(_ connection: NSXPCConnection) {
        lock.withLock {
            if currentConnection === connection {
                currentConnection = nil
            }
        }
    }

    // MARK: - ExtensionXPCProtocol（App → 扩展方向，App 调这个）

    /// XPC 运行时在任意队列上调用，不是 Swift 并发隔离的——内部用锁保护读
    /// `appMessageHandler` 闭包，解码失败静默丢弃，不崩溃。
    public func send(_ data: Data) {
        guard let message = try? JSONDecoder().decode(AppToExtensionMessage.self, from: data) else { return }
        let handler = lock.withLock { appMessageHandler }
        handler?(message)
    }
}

public enum XPCFlowTransportError: Error, Sendable {
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
