import Foundation
import Network
import Core

/// 「出口 IP 检测」:通过某一台代理服务器连 ip-echo 服务(`api.ipify.org:80`,明文 HTTP 免 TLS),
/// 发一次 GET 把回来的**出口 IP** 读出来。用于验证「这台代理最终从哪个地址出网」——代理链的出口
/// 是最后一跳,所以单独测最后那台(B)拿到的 IP 就是整条链的出口 IP。
///
/// 自包含:只用 `NWConnection` + 内联的最小 SOCKS5 / HTTP 代理握手,不依赖 EngineKit(App target
/// 不 link 它)。SOCKS5 走 CONNECT 隧道后发 origin-form GET;HTTP 代理直接发 absolute-form GET。
enum ExitIPChecker {
    private static let echoHost = "api.ipify.org"
    private static let echoPort: UInt16 = 80

    enum Result: Sendable, Equatable {
        case ip(String)
        case failed(String)
    }

    static func exitIP(via server: ProxyServer, timeout: Duration = .seconds(8)) async -> Result {
        guard let nwPort = NWEndpoint.Port(rawValue: server.port) else { return .failed("端口非法") }
        let conn = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(server.host), port: nwPort), using: .tcp
        )
        let timeoutTask = Task { try? await Task.sleep(for: timeout); conn.cancel() }
        defer { timeoutTask.cancel(); conn.cancel() }
        do {
            try await start(conn)
            switch server.kind {
            case .socks5:
                try await socks5Connect(conn, username: server.username, password: server.password)
                try await send(conn, Data(originGET().utf8))
            case .httpConnect:
                try await send(conn, Data(absoluteGET(username: server.username, password: server.password).utf8))
            }
            let body = try await readHTTPBody(conn)
            let ip = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return ip.isEmpty ? .failed("空响应") : .ip(ip)
        } catch let e as CheckError {
            return .failed(e.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - HTTP 请求

    private static func originGET() -> String {
        "GET / HTTP/1.1\r\nHost: \(echoHost)\r\nUser-Agent: appidge\r\nConnection: close\r\n\r\n"
    }

    private static func absoluteGET(username: String?, password: String?) -> String {
        var req = "GET http://\(echoHost)/ HTTP/1.1\r\nHost: \(echoHost)\r\nUser-Agent: appidge\r\nConnection: close\r\n"
        if let username, let password {
            let cred = Data("\(username):\(password)".utf8)
            req += "Proxy-Authorization: Basic \(cred.base64EncodedString())\r\n"
        }
        req += "\r\n"
        return req
    }

    // MARK: - SOCKS5 最小握手(no-auth / user-pass），CONNECT 到 echoHost:echoPort

    private static func socks5Connect(_ conn: NWConnection, username: String?, password: String?) async throws {
        let hasCreds = (username?.isEmpty == false) && (password?.isEmpty == false)
        // 问候:offer no-auth（+ user/pass 若有凭据）。
        try await send(conn, Data(hasCreds ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]))
        let sel = try await readExactly(conn, 2)
        guard sel.count == 2, sel[0] == 0x05 else { throw CheckError("SOCKS5 问候失败") }
        switch sel[1] {
        case 0x00: break // no-auth
        case 0x02:
            guard let username, let password else { throw CheckError("代理要求认证，但未配账号") }
            let u = Array(username.utf8), p = Array(password.utf8)
            guard u.count <= 255, p.count <= 255 else { throw CheckError("账号过长") }
            try await send(conn, Data([0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p))
            let ar = try await readExactly(conn, 2)
            guard ar.count == 2, ar[1] == 0x00 else { throw CheckError("SOCKS5 认证被拒") }
        default: throw CheckError("SOCKS5 无可用认证方式")
        }
        // CONNECT echoHost:echoPort（域名 ATYP=3）。
        let host = Array(echoHost.utf8)
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host
        req += [UInt8(echoPort >> 8), UInt8(echoPort & 0xff)]
        try await send(conn, Data(req))
        try await readSocks5ConnectReply(conn)
    }

    /// 读并丢弃 SOCKS5 CONNECT 回复:VER REP RSV ATYP BND.ADDR BND.PORT。
    /// 先读前 4 字节判 ATYP，再按类型读余量。拆出来压 `socks5Connect` 的 cyclomatic_complexity。
    private static func readSocks5ConnectReply(_ conn: NWConnection) async throws {
        let head = try await readExactly(conn, 4)
        guard head.count == 4, head[0] == 0x05, head[1] == 0x00 else {
            throw CheckError("SOCKS5 CONNECT 被拒（REP=\(head.count > 1 ? head[1] : 255)）")
        }
        let addrLen: Int
        switch head[3] {
        case 0x01: addrLen = 4          // IPv4
        case 0x04: addrLen = 16         // IPv6
        case 0x03:                      // 域名:先读 1 字节长度
            let l = try await readExactly(conn, 1)
            addrLen = Int(l.first ?? 0)
        default: throw CheckError("SOCKS5 回复 ATYP 未知")
        }
        _ = try await readExactly(conn, addrLen + 2) // BND.ADDR + BND.PORT，丢弃
    }

    // MARK: - NWConnection async I/O

    private static func start(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = OnceBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let e): box.resume(.failure(e))
                case .cancelled: box.resume(.failure(CheckError("连接超时 / 被取消")))
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    /// 读满 n 字节(不足就继续收,连接关了/出错则抛)。
    private static func readExactly(_ conn: NWConnection, _ n: Int) async throws -> [UInt8] {
        var buf = [UInt8]()
        while buf.count < n {
            let chunk = try await receiveOnce(conn, max: n - buf.count)
            if chunk.isEmpty { throw CheckError("连接提前关闭") }
            buf += chunk
        }
        return buf
    }

    /// 读到连接关闭为止,取 HTTP 响应体(`\r\n\r\n` 之后)。ip-echo 响应体就是纯 IP 文本。
    private static func readHTTPBody(_ conn: NWConnection) async throws -> String {
        var data = Data()
        while data.count < 64 * 1024 {
            let chunk = try await receiveOnce(conn, max: 8192)
            if chunk.isEmpty { break }
            data += Data(chunk)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CheckError("响应非文本") }
        if let range = text.range(of: "\r\n\r\n") { return String(text[range.upperBound...]) }
        return text
    }

    private static func receiveOnce(_ conn: NWConnection, max: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: data.map(Array.init) ?? [])
            }
        }
    }
}

private struct CheckError: Error { let message: String; init(_ m: String) { message = m } }

/// CheckedContinuation 只能 resume 一次;stateUpdateHandler 会多次回调,用锁守一次性。
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    init(_ c: CheckedContinuation<Void, Error>) { cont = c }
    func resume(_ result: Swift.Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return }
        cont = nil
        c.resume(with: result)
    }
}
