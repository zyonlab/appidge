import Testing
import Foundation
import IPCContract
@testable import EngineKit

// MARK: - Pure SOCKS5Handshake byte-level tests (RFC 1928 + RFC 1929)
//
// Every assertion below is on the *exact* bytes produced/parsed by the pure handshake
// functions — no sockets, no Network.framework. This is the exhaustively-testable heart of
// the SOCKS5 client; the connector (further down) just drives these over a byte stream.

@Suite("SOCKS5Handshake — RFC 1928/1929 pure byte encoding & parsing")
struct SOCKS5HandshakeTests {

    // MARK: Greeting

    @Test("associateRequestBytes is the fixed UDP ASSOCIATE command with 0.0.0.0:0")
    func associateRequestBytes() {
        // VER=05 CMD=03(ASSOCIATE) RSV=00 ATYP=01(IPv4) 0.0.0.0 :0
        #expect(SOCKS5Handshake.associateRequestBytes() == [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    @Test("greeting without credentials offers only the no-auth method (0x00)")
    func greetingWithoutCredentials() {
        #expect(SOCKS5Handshake.greetingBytes(hasCredentials: false) == [0x05, 0x01, 0x00])
    }

    @Test("greeting with credentials offers user/pass (0x02) then no-auth (0x00)")
    func greetingWithCredentials() {
        #expect(SOCKS5Handshake.greetingBytes(hasCredentials: true) == [0x05, 0x02, 0x02, 0x00])
    }

    // MARK: Method selection parsing

    @Test("method selection 0x05 0x00 parses as no-auth")
    func methodSelectionNoAuth() throws {
        #expect(try SOCKS5Handshake.parseMethodSelection([0x05, 0x00]) == .noAuth)
    }

    @Test("method selection 0x05 0x02 parses as username/password")
    func methodSelectionUsernamePassword() throws {
        #expect(try SOCKS5Handshake.parseMethodSelection([0x05, 0x02]) == .usernamePassword)
    }

    @Test("method selection 0x05 0xFF throws noAcceptableMethods")
    func methodSelectionNoAcceptable() {
        #expect(throws: SOCKS5Error.noAcceptableMethods) {
            _ = try SOCKS5Handshake.parseMethodSelection([0x05, 0xFF])
        }
    }

    @Test("method selection with a non-0x05 version byte throws invalidVersion")
    func methodSelectionBadVersion() {
        #expect(throws: SOCKS5Error.invalidVersion) {
            _ = try SOCKS5Handshake.parseMethodSelection([0x04, 0x00])
        }
    }

    @Test("method selection with an unoffered method byte throws unexpectedMethod")
    func methodSelectionUnexpectedMethod() {
        #expect(throws: SOCKS5Error.unexpectedMethod(0x03)) {
            _ = try SOCKS5Handshake.parseMethodSelection([0x05, 0x03])
        }
    }

    @Test("method selection with a short buffer throws malformedResponse")
    func methodSelectionShort() {
        #expect(throws: SOCKS5Error.malformedResponse) {
            _ = try SOCKS5Handshake.parseMethodSelection([0x05])
        }
    }

    // MARK: Auth request (RFC 1929)

    @Test("auth request lays out VER=0x01, ulen, username, plen, password")
    func authRequestBytes() throws {
        let bytes = try SOCKS5Handshake.authRequestBytes(username: "user", password: "pass")
        let expected: [UInt8] = [0x01, 0x04] + Array("user".utf8) + [0x04] + Array("pass".utf8)
        #expect(bytes == expected)
        // Spelled out fully so the byte layout is unmistakable:
        #expect(bytes == [0x01, 0x04, 0x75, 0x73, 0x65, 0x72, 0x04, 0x70, 0x61, 0x73, 0x73])
    }

    @Test("auth request rejects an over-long (>255 byte) username")
    func authRequestRejectsLongUsername() {
        let longName = String(repeating: "a", count: 256)
        #expect(throws: SOCKS5Error.credentialTooLong) {
            _ = try SOCKS5Handshake.authRequestBytes(username: longName, password: "p")
        }
    }

    @Test("auth reply 0x01 0x00 is accepted as success")
    func authReplySuccess() throws {
        try SOCKS5Handshake.parseAuthReply([0x01, 0x00])
    }

    @Test("auth reply with a non-zero status throws authenticationFailed")
    func authReplyFailure() {
        #expect(throws: SOCKS5Error.authenticationFailed) {
            try SOCKS5Handshake.parseAuthReply([0x01, 0x01])
        }
    }

    // MARK: CONNECT request

    @Test("CONNECT request for a domain target uses ATYP 0x03 with a length-prefixed host")
    func connectRequestDomain() throws {
        let bytes = try SOCKS5Handshake.connectRequestBytes(host: "example.com", port: 443)
        let expected: [UInt8] =
            [0x05, 0x01, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB]
        #expect(bytes == expected)
    }

    @Test("CONNECT request for an IPv4 target uses ATYP 0x01 with 4 raw address bytes")
    func connectRequestIPv4() throws {
        let bytes = try SOCKS5Handshake.connectRequestBytes(host: "127.0.0.1", port: 8080)
        #expect(bytes == [0x05, 0x01, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x1F, 0x90])
    }

    @Test("CONNECT request for an IPv6 target uses ATYP 0x04 with 16 raw address bytes")
    func connectRequestIPv6() throws {
        let bytes = try SOCKS5Handshake.connectRequestBytes(host: "2001:db8::1", port: 443)
        let expectedAddr: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        #expect(bytes == [0x05, 0x01, 0x00, 0x04] + expectedAddr + [0x01, 0xBB])
    }

    @Test("CONNECT request for the compressed IPv6 loopback ::1 encodes 15 zero bytes then 0x01")
    func connectRequestIPv6Loopback() throws {
        let bytes = try SOCKS5Handshake.connectRequestBytes(host: "::1", port: 1080)
        let expectedAddr: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        #expect(bytes == [0x05, 0x01, 0x00, 0x04] + expectedAddr + [0x04, 0x38])
    }

    @Test("CONNECT request rejects an over-long (>255 byte) domain name")
    func connectRequestRejectsLongDomain() {
        let longHost = String(repeating: "a", count: 256) + ".com"
        #expect(throws: SOCKS5Error.domainTooLong) {
            _ = try SOCKS5Handshake.connectRequestBytes(host: longHost, port: 443)
        }
    }

    // MARK: CONNECT reply parsing (success + REP mapping + BND.ADDR consumption)

    @Test("CONNECT reply success with an IPv4 BND.ADDR yields the bound address and port")
    func connectReplySuccessIPv4() throws {
        let reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x1F, 0x90]
        let bound = try SOCKS5Handshake.parseConnectReply(reply)
        #expect(bound.address == .ipv4([0x7F, 0x00, 0x00, 0x01]))
        #expect(bound.port == 8080)
    }

    @Test("CONNECT reply success with a domain BND.ADDR consumes the length prefix correctly")
    func connectReplySuccessDomain() throws {
        let reply: [UInt8] =
            [0x05, 0x00, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB]
        let bound = try SOCKS5Handshake.parseConnectReply(reply)
        #expect(bound.address == .domain("example.com"))
        #expect(bound.port == 443)
    }

    @Test("CONNECT reply success with an IPv6 BND.ADDR consumes 16 address bytes correctly")
    func connectReplySuccessIPv6() throws {
        let addr: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        let reply: [UInt8] = [0x05, 0x00, 0x00, 0x04] + addr + [0x01, 0xBB]
        let bound = try SOCKS5Handshake.parseConnectReply(reply)
        #expect(bound.address == .ipv6(addr))
        #expect(bound.port == 443)
    }

    @Test("CONNECT reply REP 0x01 maps to generalFailure")
    func connectReplyGeneralFailure() {
        let reply: [UInt8] = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        #expect(throws: SOCKS5Error.replyFailed(.generalFailure)) {
            _ = try SOCKS5Handshake.parseConnectReply(reply)
        }
    }

    @Test("CONNECT reply REP 0x03 maps to networkUnreachable")
    func connectReplyNetworkUnreachable() {
        let reply: [UInt8] = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        #expect(throws: SOCKS5Error.replyFailed(.networkUnreachable)) {
            _ = try SOCKS5Handshake.parseConnectReply(reply)
        }
    }

    @Test("CONNECT reply REP 0x05 maps to connectionRefused")
    func connectReplyConnectionRefused() {
        let reply: [UInt8] = [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        #expect(throws: SOCKS5Error.replyFailed(.connectionRefused)) {
            _ = try SOCKS5Handshake.parseConnectReply(reply)
        }
    }

    @Test("CONNECT reply REP 0x07 maps to commandNotSupported")
    func connectReplyCommandNotSupported() {
        let reply: [UInt8] = [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        #expect(throws: SOCKS5Error.replyFailed(.commandNotSupported)) {
            _ = try SOCKS5Handshake.parseConnectReply(reply)
        }
    }

    @Test("CONNECT reply with a truncated buffer throws malformedResponse")
    func connectReplyTruncated() {
        #expect(throws: SOCKS5Error.malformedResponse) {
            // ATYP says IPv4 (needs 4 addr + 2 port = 6 more bytes) but only 2 follow.
            _ = try SOCKS5Handshake.parseConnectReply([0x05, 0x00, 0x00, 0x01, 0x7F, 0x00])
        }
    }

    @Test("CONNECT reply with a non-0x05 version byte throws invalidVersion")
    func connectReplyBadVersion() {
        #expect(throws: SOCKS5Error.invalidVersion) {
            _ = try SOCKS5Handshake.parseConnectReply([0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        }
    }
}
