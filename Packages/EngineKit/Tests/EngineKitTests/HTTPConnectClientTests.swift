import Testing
import Foundation
import IPCContract
@testable import EngineKit

@Suite("HTTPConnectClient — RFC 7231 CONNECT tunnel, byte-level, mock ByteStream only")
struct HTTPConnectClientTests {

    private func ascii(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    // MARK: request bytes (pure)

    @Test("request without credentials: CONNECT line + Host header + blank-line terminator, no auth")
    func requestNoCredentials() throws {
        let bytes = HTTPConnectHandshake.requestBytes(host: "example.com", port: 443, username: nil, password: nil)
        #expect(ascii(bytes) == "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
    }

    @Test("request with credentials carries Proxy-Authorization: Basic <base64(user:pass)>")
    func requestWithCredentials() throws {
        let bytes = HTTPConnectHandshake.requestBytes(host: "h", port: 8080, username: "alice", password: "hunter2")
        let expectedB64 = Data("alice:hunter2".utf8).base64EncodedString()
        #expect(ascii(bytes) == "CONNECT h:8080 HTTP/1.1\r\nHost: h:8080\r\nProxy-Authorization: Basic \(expectedB64)\r\n\r\n")
    }

    @Test("an IP target is used literally as host:port, same as a domain")
    func requestIPTarget() throws {
        let bytes = HTTPConnectHandshake.requestBytes(host: "93.184.216.34", port: 443, username: nil, password: nil)
        #expect(ascii(bytes) == "CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: 93.184.216.34:443\r\n\r\n")
    }

    // MARK: status parsing (pure)

    @Test("200 status parses as success")
    func status200() throws {
        try HTTPConnectHandshake.validateResponse(Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
    }

    @Test("407 parses as proxyAuthenticationRequired")
    func status407() {
        #expect(throws: HTTPConnectError.proxyAuthenticationRequired) {
            try HTTPConnectHandshake.validateResponse(Array("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
        }
    }

    @Test("502 parses as unexpectedStatus(502)")
    func status502() {
        #expect(throws: HTTPConnectError.unexpectedStatus(502)) {
            try HTTPConnectHandshake.validateResponse(Array("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
        }
    }

    @Test("a malformed status line throws malformedResponse")
    func malformed() {
        #expect(throws: HTTPConnectError.malformedResponse) {
            try HTTPConnectHandshake.validateResponse(Array("GARBAGE\r\n\r\n".utf8))
        }
    }

    // MARK: connector over a scripted stream

    @Test("establish happy path: writes the exact CONNECT request and consumes only through the header terminator")
    func establishHappyPath() async throws {
        // Header block + a byte of tunneled payload placed right after \r\n\r\n; the reader must
        // stop exactly at the terminator and leave the payload byte unread (no over-read).
        let response = "HTTP/1.1 200 Connection established\r\nX-Proxy: v1\r\n\r\n"
        let payloadAfter: [UInt8] = [0xAB]
        let stream = MockByteStream(scriptedReads: Array(response.utf8) + payloadAfter)

        let client = HTTPConnectClient(username: nil, password: nil)
        try await client.establish(toHost: "example.com", port: 443, over: stream)

        #expect(ascii(await stream.written) == "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        // exactly the payload byte remains unread
        #expect(await stream.remainingReadBytes == payloadAfter)
    }

    @Test("establish with credentials writes the Proxy-Authorization header")
    func establishWithCredentials() async throws {
        let stream = MockByteStream(scriptedReads: Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        let client = HTTPConnectClient(proxyServer: ProxyServerDTO(id: "p", host: "h", port: 8080, kind: .httpConnect, username: "u", password: "p"))
        try await client.establish(toHost: "d", port: 80, over: stream)
        #expect(ascii(await stream.written).contains("Proxy-Authorization: Basic \(Data("u:p".utf8).base64EncodedString())"))
    }

    @Test("establish throws on 407")
    func establish407() async {
        let stream = MockByteStream(scriptedReads: Array("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
        let client = HTTPConnectClient(username: nil, password: nil)
        await #expect(throws: HTTPConnectError.proxyAuthenticationRequired) {
            try await client.establish(toHost: "d", port: 80, over: stream)
        }
    }

    @Test("establish throws on 5xx")
    func establish5xx() async {
        let stream = MockByteStream(scriptedReads: Array("HTTP/1.1 503 Service Unavailable\r\n\r\n".utf8))
        let client = HTTPConnectClient(username: nil, password: nil)
        await #expect(throws: HTTPConnectError.unexpectedStatus(503)) {
            try await client.establish(toHost: "d", port: 80, over: stream)
        }
    }
}

/// Scripted mock ``ByteStream`` for HTTP CONNECT tests: hands back queued bytes on read(exactly:),
/// records everything written, and exposes what's left unread so tests can prove no over-read.
private actor MockByteStream: ByteStream {
    private var reads: [UInt8]
    private(set) var written: [UInt8] = []

    init(scriptedReads: [UInt8]) { self.reads = scriptedReads }

    var remainingReadBytes: [UInt8] { reads }

    func write(_ bytes: [UInt8]) async throws { written += bytes }

    func read(exactly count: Int) async throws -> [UInt8] {
        guard reads.count >= count else { throw MockByteStreamError.underrun }
        let head = Array(reads.prefix(count))
        reads.removeFirst(count)
        return head
    }
}

private enum MockByteStreamError: Error { case underrun }
