import Foundation
import Network
import EngineKit
import IPCContract

/// 「怎么拨一条路由」——从 ``ProxyExtensionProvider`` 里拆出来的无状态拨号逻辑:给定一条
/// 已解析的 ``ResolvedRoute`` 和目标,返回**已就绪、可直接 pump 的 `NWConnection`**。
///
/// 独立成型的理由:provider 那个类专注 NE flow 生命周期(接管/计量/事件),而"单台/链/
/// 故障转移/负载均衡各自怎么建隧道"是另一件事,纯 async 函数、零 provider 状态,放这里既让
/// provider 瘦下来,也让这段逻辑读起来是一条清晰的"路由 → 连接"管线。
enum ProxyDialer {

    /// 按路由种类建立到目标的连接。`.direct` 用 `directEndpoint` 直连;其余按各自策略拨上游。
    static func open(
        route: ResolvedRoute,
        to target: ProxyTarget,
        directEndpoint: Network.NWEndpoint,
        roundRobin: RoundRobinSelector
    ) async throws -> NWConnection {
        switch route {
        case .direct:
            return try await openDirect(to: directEndpoint)
        case .single(let server):
            return try await openSingleTunnel(to: target, via: server)
        case .failover(let servers):
            // 按序尝试,首个握手成功的胜出;全失败抛最后一个错(调用方 fail-open 关流)。
            return try await FailoverConnector.connect(proxies: servers) { server in
                try await openSingleTunnel(to: target, via: server)
            }
        case .loadBalance(let servers):
            let index = await roundRobin.next(count: servers.count) ?? 0
            return try await openSingleTunnel(to: target, via: servers[index])
        case .chain(let servers):
            let stream = try await ChainConnector.connect(
                proxies: servers, destinationHost: target.host, destinationPort: target.port
            ) { proxy, targetHost, targetPort, base in
                try await chainHop(proxy: proxy, targetHost: targetHost, targetPort: targetPort, base: base)
            }
            // 链首跳一定是 NWConnectionByteStream,底层那条 NWConnection 就是整条链的隧道。
            guard let tunnel = (stream as? NWConnectionByteStream)?.tunnelConnection else {
                throw ProxyDialerError.chainTunnelUnavailable
            }
            return tunnel
        }
    }

    /// 拨一台上游 + 按其协议做隧道握手,返回已就绪、可直接 pump 的 NWConnection。
    private static func openSingleTunnel(to target: ProxyTarget, via server: ProxyServerDTO) async throws -> NWConnection {
        let stream = NWConnectionByteStream(proxyServer: server)
        try await stream.open()
        try await handshake(server, toHost: target.host, port: target.port, over: stream)
        return stream.tunnelConnection
    }

    /// 代理链的一跳:第一跳(`base == nil`)新拨到该代理;之后复用上一跳建立、通往该代理的隧道
    /// (`base`)。两种情况都在该 stream 上对着"下一跳目标"做本代理的握手,返回同一条 stream
    /// (整条链复用首跳那条 NWConnection,逐层深入)。
    private static func chainHop(
        proxy: ProxyServerDTO, targetHost: String, targetPort: UInt16, base: (any ByteStream)?
    ) async throws -> any ByteStream {
        let stream: any ByteStream
        if let base {
            stream = base
        } else {
            let dialed = NWConnectionByteStream(proxyServer: proxy)
            try await dialed.open()
            stream = dialed
        }
        try await handshake(proxy, toHost: targetHost, port: targetPort, over: stream)
        return stream
    }

    /// 按 kind 分派 SOCKS5 / HTTP CONNECT 握手;握手完成后 stream 直通 `host:port`。
    private static func handshake(
        _ server: ProxyServerDTO, toHost host: String, port: UInt16, over stream: any ByteStream
    ) async throws {
        switch server.kind {
        case .socks5:
            try await SOCKS5Connector(proxyServer: server).establish(toHost: host, port: port, over: stream)
        case .httpConnect:
            try await HTTPConnectClient(proxyServer: server).establish(toHost: host, port: port, over: stream)
        }
    }

    /// 直连目的地并挂起到 `.ready`(或失败)。返回时连接已可读写。
    static func openDirect(to endpoint: Network.NWEndpoint) async throws -> NWConnection {
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeOnceBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let error): box.resume(.failure(error))
                case .cancelled: box.resume(.failure(ProxyDialerError.cancelled))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        return connection
    }

    /// 连接日志里展示的代理协议:取解析后路由第一跳的 kind(直连记 nil)。多台模式取首台 kind
    /// 作代表(负载均衡的实际选台逐连接轮转,这里是近似的展示提示)。
    static func representativeKind(
        rule: ProxyRuleDTO, config: ProxyConfigMessage?, mode: ProxyRoutingModeDTO
    ) -> ProxyKindDTO? {
        guard rule == .proxied else { return nil }
        let route = ProxyRouteResolver.resolve(
            mode: mode, servers: config?.servers ?? [], activeServerID: config?.activeServerID
        )
        switch route {
        case .direct: return nil
        case .single(let server): return server.kind
        case .chain(let servers), .failover(let servers), .loadBalance(let servers): return servers.first?.kind
        }
    }

    static func hostPort(from endpoint: Network.NWEndpoint) -> (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .name(let name, _): hostString = name
        case .ipv4(let address): hostString = "\(address)"
        case .ipv6(let address): hostString = "\(address)"
        @unknown default: return nil
        }
        return (hostString, port.rawValue)
    }
}

enum ProxyDialerError: Error, Sendable {
    case cancelled
    /// 代理链的首跳流不是预期的 NWConnectionByteStream,取不到底层隧道连接(理论不可达)。
    case chainTunnelUnavailable
}

/// `CheckedContinuation` 只能 resume 一次;`NWConnection` 的 stateUpdateHandler 可能在 ready 之后
/// 还回调 cancelled,用锁保护避免二次 resume 崩溃。同 NEFlowTransport 的 ContinuationBox。
private final class ResumeOnceBox: @unchecked Sendable {
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
