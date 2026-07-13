import Foundation
import IPCContract
import Network

/// Production ``ByteStream`` backed by a real `NWConnection` to the upstream proxy. This is the
/// live-network half of the SOCKS5 client, kept in its own file so the pure logic + connector
/// stay socket-free. Like ``NEFlowTransport``, it is never instantiated by EngineKitTests (see
/// the B4 architecture invariant): unit tests drive ``SOCKS5Connector`` through a scripted mock.
///
/// `NWConnection` is documented thread-safe, so we take the `@unchecked Sendable` conformance
/// deliberately — same justification as ``NEFlowTransport``.
public final class NWConnectionByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection

    public init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 1080
        )
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    /// Dial the proxy the connector will speak to. Pulls host/port off the config DTO whose
    /// credentials also seed ``SOCKS5Connector/init(proxyServer:)``.
    public convenience init(proxyServer: ProxyServerDTO) {
        self.init(host: proxyServer.host, port: proxyServer.port)
    }

    /// Start the connection and suspend until it reaches `.ready` (or fails). Call once before
    /// handing this stream to the connector.
    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ByteStreamContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                case .failed(let error):
                    box.resume(.failure(error))
                case .cancelled:
                    box.resume(.failure(NWConnectionByteStreamError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Tear the connection down. Safe to call more than once.
    public func close() {
        connection.cancel()
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    /// Read *exactly* `count` bytes. `minimumIncompleteLength == maximumLength == count` makes
    /// `NWConnection` wait until the full count arrives; a short/`isComplete` delivery means the
    /// peer closed early, which we surface as `connectionClosed`.
    public func read(exactly count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, data.count == count else {
                    continuation.resume(throwing: NWConnectionByteStreamError.connectionClosed)
                    return
                }
                continuation.resume(returning: Array(data))
            }
        }
    }
}

public enum NWConnectionByteStreamError: Error, Sendable {
    case cancelled
    case connectionClosed
}

/// A `CheckedContinuation` can only be resumed once; `NWConnection`'s `stateUpdateHandler` can
/// fire `.cancelled` after `.ready`/`.failed`, so guard resumption with a lock — the same
/// pattern as ``NEFlowTransport``'s `ContinuationBox`.
private final class ByteStreamContinuationBox: @unchecked Sendable {
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
