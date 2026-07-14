import Foundation
import Network
import AppFeature

/// `ProxyReachabilityProbe` 的真实现:拨一条 NWConnection 到 `host:port`,`.ready` 即可达,
/// `.failed`/`.cancelled`/超时即不可达。住在 App target,这样 AppFeature 保持零 Network 依赖
/// (探测的编排/状态映射在 `ProxyChecker`,已单测;这里只补「怎么真的连一下」)。
///
/// `NWConnection` 文档线程安全,取 `@unchecked Sendable`——同扩展里 `NWConnectionByteStream`
/// 的理由。超时经一个 Task 到点 `cancel()` 连接,让 stateUpdateHandler 落到 `.cancelled`。
struct NWConnectionProxyProbe: ProxyReachabilityProbe {
    var timeout: Duration = .seconds(3)

    func isReachable(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: .tcp
        )
        let box = ProbeResumeBox()
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            connection.cancel() // 超时 → cancel → .cancelled → resume(false)
        }
        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            box.arm(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true)
                case .failed, .cancelled: box.resume(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        timeoutTask.cancel()
        connection.cancel()
        return reachable
    }
}

/// `CheckedContinuation` 只能 resume 一次;stateUpdateHandler 会多次回调,用锁守一次性。
private final class ProbeResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
