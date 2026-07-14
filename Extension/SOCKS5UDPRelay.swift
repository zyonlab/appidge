import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract
import os.log

private let udpLogger = Logger(subsystem: "com.appidge.app.ProxyExtension", category: "UDPRelay")

/// SOCKS5 UDP ASSOCIATE 中继(A1b):把一条 `NEAppProxyUDPFlow` 的 UDP 数据报经 SOCKS5 上游代理出去。
///
/// 流程(RFC 1928 §7):
/// 1. 拨一条 **TCP 控制连接**到 SOCKS5 代理,greeting → 认证 → 发 UDP ASSOCIATE(`associateRequestBytes`),
///    解回复拿到 relay 的 `BND.ADDR:BND.PORT`。**这条 TCP 必须一直开着**——关了 association 就断。
/// 2. 拨一条 **UDP 连接**到 relay。
/// 3. 双向泵:app 的每个数据报 → `SOCKS5UDPDatagram.encode(目标, 负载)` → 发给 relay;
///    relay 回来的 → `decode` 剥头 → `writeDatagrams` 回 app。
///
/// ⚠️ 纯拨号/中继逻辑,只能真机 + 系统扩展获批 + 一台支持 UDP ASSOCIATE 的 SOCKS5 上游才能验证
/// (很多 SOCKS5 服务端并不支持 UDP,如 `ssh -D`;Shadowsocks/v2ray/Clash 支持)。线上的字节格式
/// 由 EngineKit 的 `SOCKS5UDPDatagram`(18 测试)+ `associateRequestBytes` 兜底;这里是 socket 编排。
/// `NWConnection` 文档线程安全,取 `@unchecked Sendable`——同扩展里其它 NW 包装。
final class SOCKS5UDPRelay: @unchecked Sendable {
    private let flow: NEAppProxyUDPFlow
    private let proxy: ProxyServerDTO
    private let control: NWConnectionByteStream   // TCP 控制连接,持有以保活 association
    private var relay: NWConnection?
    // 结束时回调(只触发一次),让 provider 释放对本 relay 的强引用。
    private let onFinished: @Sendable () -> Void
    private let finishLock = NSLock()
    private var finished = false

    init(flow: NEAppProxyUDPFlow, proxy: ProxyServerDTO, onFinished: @escaping @Sendable () -> Void) {
        self.flow = flow
        self.proxy = proxy
        self.control = NWConnectionByteStream(proxyServer: proxy)
        self.onFinished = onFinished
    }

    /// 建立 association 并开泵。失败则关闭 flow(fail-open 不影响其它流量)。
    func start() async {
        do {
            let relayEndpoint = try await associate()
            let relay = NWConnection(to: relayEndpoint, using: .udp)
            self.relay = relay
            try await openUDP(relay)
            pumpFlowToRelay()
            pumpRelayToFlow()
        } catch {
            udpLogger.error("UDP ASSOCIATE failed, closing flow: \(String(describing: error), privacy: .public)")
            teardown()
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
        }
    }

    func teardown() {
        finishLock.lock()
        let already = finished
        finished = true
        finishLock.unlock()
        control.close()
        relay?.cancel()
        if !already { onFinished() } // 触发一次,provider 据此释放引用
    }

    // MARK: - association handshake（在 TCP 控制连接上）

    private func associate() async throws -> NWEndpoint {
        try await control.open()
        // greeting+认证复用 SOCKS5Handshake 的纯字节;命令用 ASSOCIATE 而非 CONNECT,所以不调
        // SOCKS5Connector.establish(它是 CONNECT),自己走一遍 handshake 到「发命令」这步。
        try await control.write(SOCKS5Handshake.greetingBytes(hasCredentials: proxy.username != nil))
        let method = try SOCKS5Handshake.parseMethodSelection(try await control.read(exactly: 2))
        if method == .usernamePassword {
            guard let username = proxy.username else { throw SOCKS5Error.authenticationRequired }
            try await control.write(try SOCKS5Handshake.authRequestBytes(username: username, password: proxy.password ?? ""))
            try SOCKS5Handshake.parseAuthReply(try await control.read(exactly: 2))
        }
        try await control.write(SOCKS5Handshake.associateRequestBytes())
        let (host, port) = try SOCKS5UDPDatagram.parseAssociateReply(try await readAssociateReply())
        return NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1080
        )
    }

    /// ASSOCIATE 回复和 CONNECT 回复同结构(VER REP RSV ATYP BND.ADDR BND.PORT),但长度随 ATYP 变。
    /// 先读固定 4 字节头看 ATYP,再按 ATYP 读地址 + 2 字节端口,凑齐整条交给 parseAssociateReply。
    private func readAssociateReply() async throws -> [UInt8] {
        var reply = try await control.read(exactly: 4)          // VER REP RSV ATYP
        let atyp = reply[3]
        let addrLen: Int
        switch atyp {
        case 0x01: addrLen = 4
        case 0x04: addrLen = 16
        case 0x03: addrLen = Int(try await control.read(exactly: 1).first ?? 0); reply.append(UInt8(addrLen))
        default: throw SOCKS5UDPError.malformed
        }
        reply += try await control.read(exactly: addrLen + 2)   // ADDR + PORT
        return reply
    }

    private func openUDP(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = UDPResumeBox(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let error): box.resume(.failure(error))
                case .cancelled: box.resume(.failure(SOCKS5UDPError.malformed))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - 双向泵

    private func pumpFlowToRelay() {
        // NEAppProxyUDPFlow.readDatagrams 现代签名:一批 (Data, NWEndpoint) 元组 + error。
        flow.readDatagrams { [weak self] datagrams, error in
            guard let self, let datagrams, error == nil else { self?.teardown(); return }
            for (data, endpoint) in datagrams {
                guard let (host, port) = ProxyDialer.hostPort(from: endpoint),
                      let framed = try? SOCKS5UDPDatagram.encode(host: host, port: port, payload: Array(data)) else { continue }
                self.relay?.send(content: Data(framed), completion: .idempotent)
            }
            self.pumpFlowToRelay()
        }
    }

    private func pumpRelayToFlow() {
        relay?.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { self?.teardown(); return }
            if let decoded = try? SOCKS5UDPDatagram.decode(Array(data)),
               let port = NWEndpoint.Port(rawValue: decoded.port) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(decoded.host), port: port)
                self.flow.writeDatagrams([(Data(decoded.payload), endpoint)]) { _ in }
            }
            self.pumpRelayToFlow()
        }
    }
}

/// `CheckedContinuation` 只能 resume 一次;stateUpdateHandler 可能多次回调,锁守一次性。
private final class UDPResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
