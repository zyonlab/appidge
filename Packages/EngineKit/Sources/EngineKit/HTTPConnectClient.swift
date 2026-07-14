import Foundation
import IPCContract

public enum HTTPConnectError: Error, Equatable, Sendable {
    case proxyAuthenticationRequired
    case unexpectedStatus(Int)
    case malformedResponse
}

/// 纯逻辑层：构造 HTTP CONNECT 请求字节、解析响应状态行。不碰 I/O，字节级可测。
/// 结构对齐 ``SOCKS5Handshake``（同一个 ``ByteStream`` 接缝上跑）。
public enum HTTPConnectHandshake {

    /// `CONNECT host:port HTTP/1.1\r\nHost: host:port\r\n[Proxy-Authorization: Basic ...]\r\n\r\n`
    public static func requestBytes(host: String, port: UInt16, username: String?, password: String?) -> [UInt8] {
        let hostPort = "\(host):\(port)"
        var request = "CONNECT \(hostPort) HTTP/1.1\r\nHost: \(hostPort)\r\n"
        if let username {
            let credential = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credential)\r\n"
        }
        request += "\r\n"
        return Array(request.utf8)
    }

    /// 校验响应头块（到 `\r\n\r\n` 为止）：状态码 2xx → 通过；407 → 需认证；其它 → 带码的错误；
    /// 状态行本身不合法 → malformedResponse。
    public static func validateResponse(_ headerBlock: [UInt8]) throws {
        guard let text = String(bytes: headerBlock, encoding: .utf8),
              let statusLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            throw HTTPConnectError.malformedResponse
        }
        // "HTTP/1.1 200 Connection established" → 中间那段是状态码
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw HTTPConnectError.malformedResponse
        }
        switch code {
        case 200..<300: return
        case 407: throw HTTPConnectError.proxyAuthenticationRequired
        default: throw HTTPConnectError.unexpectedStatus(code)
        }
    }
}

/// 驱动 HTTP CONNECT 隧道：写 CONNECT 请求，读响应头**恰好到 `\r\n\r\n` 为止**（不多读一个字节，
/// 免得吞掉后面隧道的应用数据），交纯层校验状态。握手成功后连接就是通往目的地的隧道。
/// 只持不可变凭据 → 天然 Sendable。真实网络由 ``NWConnectionByteStream`` 提供，测试注入 mock。
public final class HTTPConnectClient: Sendable {
    private let username: String?
    private let password: String?

    public init(username: String? = nil, password: String? = nil) {
        self.username = username
        self.password = password
    }

    public convenience init(proxyServer: ProxyServerDTO) {
        self.init(username: proxyServer.username, password: proxyServer.password)
    }

    public func establish(toHost host: String, port: UInt16, over stream: any ByteStream) async throws {
        try await stream.write(HTTPConnectHandshake.requestBytes(host: host, port: port, username: username, password: password))
        let headerBlock = try await readHeaderBlock(over: stream)
        try HTTPConnectHandshake.validateResponse(headerBlock)
    }

    /// 逐字节读到看见 `\r\n\r\n`（头块结束）为止，绝不越过——后面是隧道净荷，留给转发层。
    private func readHeaderBlock(over stream: any ByteStream) async throws -> [UInt8] {
        var accumulated: [UInt8] = []
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        // 防御性上限，避免恶意/异常代理让我们无限读下去。
        let maxHeaderBytes = 64 * 1024
        while accumulated.count < maxHeaderBytes {
            accumulated += try await stream.read(exactly: 1)
            if accumulated.count >= terminator.count, Array(accumulated.suffix(terminator.count)) == terminator {
                return accumulated
            }
        }
        throw HTTPConnectError.malformedResponse
    }
}
