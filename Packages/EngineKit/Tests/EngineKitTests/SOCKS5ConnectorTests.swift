import Testing
import Foundation
import IPCContract
@testable import EngineKit

// MARK: - Scripted byte-stream double
//
// Hands the connector canned server bytes and records every byte it writes, so tests assert
// the exact request sequence without a socket. `read(exactly:)` underflows loudly if the
// connector asks for more than the script provides — that would itself be a protocol bug.

private enum MockStreamError: Error, Equatable {
    case readUnderflow
}

private actor MockByteStream: ByteStream {
    private let inbound: [UInt8]
    private var readCursor = 0
    private var writeLog: [UInt8] = []

    init(serverBytes: [UInt8]) {
        self.inbound = serverBytes
    }

    func write(_ bytes: [UInt8]) async throws {
        writeLog.append(contentsOf: bytes)
    }

    func read(exactly count: Int) async throws -> [UInt8] {
        guard readCursor + count <= inbound.count else { throw MockStreamError.readUnderflow }
        defer { readCursor += count }
        return Array(inbound[readCursor..<readCursor + count])
    }

    func recordedWrites() -> [UInt8] {
        writeLog
    }
}

// MARK: - SOCKS5Connector driver tests (full handshake over MockByteStream, no real socket)

@Suite("SOCKS5Connector — drives the handshake over an injected ByteStream")
struct SOCKS5ConnectorTests {

    private static func successReplyIPv4Zero() -> [UInt8] {
        [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }

    // MARK: Happy paths

    @Test("no-auth happy path writes greeting then CONNECT and returns the bound address")
    func noAuthHappyPath() async throws {
        let stream = MockByteStream(serverBytes: [0x05, 0x00] + Self.successReplyIPv4Zero())
        let connector = SOCKS5Connector()

        let bound = try await connector.establish(toHost: "example.com", port: 443, over: stream)

        let expectedGreeting: [UInt8] = [0x05, 0x01, 0x00]
        let expectedConnect: [UInt8] =
            [0x05, 0x01, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB]
        #expect(await stream.recordedWrites() == expectedGreeting + expectedConnect)
        #expect(bound.address == .ipv4([0, 0, 0, 0]))
        #expect(bound.port == 0)
    }

    @Test("auth happy path writes greeting, auth, then CONNECT in order")
    func authHappyPath() async throws {
        let server: [UInt8] = [0x05, 0x02] + [0x01, 0x00] + Self.successReplyIPv4Zero()
        let stream = MockByteStream(serverBytes: server)
        let connector = SOCKS5Connector(username: "user", password: "pass")

        _ = try await connector.establish(toHost: "93.184.216.34", port: 443, over: stream)

        let expectedGreeting: [UInt8] = [0x05, 0x02, 0x02, 0x00]
        let expectedAuth: [UInt8] = [0x01, 0x04] + Array("user".utf8) + [0x04] + Array("pass".utf8)
        let expectedConnect: [UInt8] = [0x05, 0x01, 0x00, 0x01, 0x5D, 0xB8, 0xD8, 0x22, 0x01, 0xBB]
        #expect(await stream.recordedWrites() == expectedGreeting + expectedAuth + expectedConnect)
    }

    @Test("init(proxyServer:) carries the DTO credentials into the greeting")
    func initFromProxyServerDTOOffersAuth() async throws {
        let dto = ProxyServerDTO(
            id: "p1", host: "proxy.example", port: 1080, kind: .socks5,
            username: "u", password: "p"
        )
        let server: [UInt8] = [0x05, 0x02] + [0x01, 0x00] + Self.successReplyIPv4Zero()
        let stream = MockByteStream(serverBytes: server)
        let connector = SOCKS5Connector(proxyServer: dto)

        _ = try await connector.establish(toHost: "example.com", port: 80, over: stream)

        let written = await stream.recordedWrites()
        #expect(Array(written.prefix(4)) == [0x05, 0x02, 0x02, 0x00])
    }

    // MARK: Staged variable-length BND.ADDR reads

    @Test("connector reads a domain BND.ADDR reply in stages and decodes it")
    func readsDomainBoundAddress() async throws {
        let reply: [UInt8] =
            [0x05, 0x00, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB]
        let stream = MockByteStream(serverBytes: [0x05, 0x00] + reply)
        let connector = SOCKS5Connector()

        let bound = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        #expect(bound.address == .domain("example.com"))
        #expect(bound.port == 443)
    }

    @Test("connector reads an IPv6 BND.ADDR reply (16 bytes) in stages and decodes it")
    func readsIPv6BoundAddress() async throws {
        let addr: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        let reply: [UInt8] = [0x05, 0x00, 0x00, 0x04] + addr + [0x01, 0xBB]
        let stream = MockByteStream(serverBytes: [0x05, 0x00] + reply)
        let connector = SOCKS5Connector()

        let bound = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        #expect(bound.address == .ipv6(addr))
    }

    // MARK: Failure paths

    @Test("server rejecting all methods (0xFF) throws before any CONNECT is written")
    func serverRejectsMethods() async {
        let stream = MockByteStream(serverBytes: [0x05, 0xFF])
        let connector = SOCKS5Connector()

        await #expect(throws: SOCKS5Error.noAcceptableMethods) {
            _ = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        }
        // Only the greeting went out; the connector never sent a CONNECT after rejection.
        #expect(await stream.recordedWrites() == [0x05, 0x01, 0x00])
    }

    @Test("auth failure reply throws authenticationFailed after greeting+auth are written")
    func authFailure() async {
        let stream = MockByteStream(serverBytes: [0x05, 0x02] + [0x01, 0x01])
        let connector = SOCKS5Connector(username: "user", password: "pass")

        await #expect(throws: SOCKS5Error.authenticationFailed) {
            _ = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        }
        let expected: [UInt8] =
            [0x05, 0x02, 0x02, 0x00] + [0x01, 0x04] + Array("user".utf8) + [0x04] + Array("pass".utf8)
        #expect(await stream.recordedWrites() == expected)
    }

    @Test("a non-zero CONNECT REP is surfaced as the mapped replyFailed error")
    func connectRejected() async {
        let reply: [UInt8] = [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        let stream = MockByteStream(serverBytes: [0x05, 0x00] + reply)
        let connector = SOCKS5Connector()

        await #expect(throws: SOCKS5Error.replyFailed(.connectionRefused)) {
            _ = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        }
    }

    @Test("server selecting user/pass when no credentials exist throws authenticationRequired")
    func serverDemandsAuthWeCannotProvide() async {
        let stream = MockByteStream(serverBytes: [0x05, 0x02])
        let connector = SOCKS5Connector()

        await #expect(throws: SOCKS5Error.authenticationRequired) {
            _ = try await connector.establish(toHost: "example.com", port: 443, over: stream)
        }
        #expect(await stream.recordedWrites() == [0x05, 0x01, 0x00])
    }
}

// MARK: - Test-file import hygiene (enforces the B4 invariant at this file's own level)

@Suite("SOCKS5 client tests import hygiene")
struct SOCKS5ClientTestHygiene {

    @Test("this test file imports only Testing/Foundation/IPCContract/EngineKit — no Network")
    func onlyAllowedImports() throws {
        let url = URL(fileURLWithPath: #filePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        let allowed: Set<String> = ["Testing", "Foundation", "IPCContract", "EngineKit"]

        let importedModules = source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ") }
            .map { line in
                line
                    .replacingOccurrences(of: "@testable ", with: "")
                    .replacingOccurrences(of: "import ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }

        #expect(!importedModules.isEmpty)
        for module in importedModules {
            #expect(allowed.contains(module), "Unexpected import in SOCKS5 tests: \(module)")
        }
    }
}
