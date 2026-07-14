import Darwin
import Foundation
import IPCContract

// MARK: - SOCKS5 upstream client (RFC 1928 + RFC 1929)
//
// The protocol logic lives in `SOCKS5Handshake` as *pure* functions over `[UInt8]`: they
// produce the exact bytes to send for each phase and parse the bytes received, with zero I/O.
// That is the exhaustively byte-testable core. `SOCKS5Connector` (below) is a thin driver that
// pumps those bytes over an injected `ByteStream`, so the network seam is fully mockable —
// unit tests never touch a real socket (see the `MockByteStream` in the tests and the B4
// architecture invariant). The real, `NWConnection`-backed `ByteStream` lives in a separate
// file and is never instantiated by tests.

// MARK: - Value types

/// The auth method the server selected in its greeting reply (RFC 1928 §3).
public enum SOCKS5Method: Sendable, Equatable {
    case noAuth
    case usernamePassword
}

/// A decoded BND.ADDR from a CONNECT reply (or, symmetrically, an encoded target address).
public enum SOCKS5Address: Sendable, Equatable {
    case ipv4([UInt8])   // exactly 4 bytes, network order
    case ipv6([UInt8])   // exactly 16 bytes, network order
    case domain(String)
}

/// The bound address + port the proxy reports on a successful CONNECT (RFC 1928 §6).
public struct SOCKS5BoundAddress: Sendable, Equatable {
    public let address: SOCKS5Address
    public let port: UInt16

    public init(address: SOCKS5Address, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// The standard non-zero REP codes a CONNECT reply can carry (RFC 1928 §6). `0x00`
/// (succeeded) is never represented here — it is the absence of a `SOCKS5Error`.
public enum SOCKS5ReplyCode: UInt8, Sendable, Equatable {
    case generalFailure = 0x01
    case connectionNotAllowed = 0x02
    case networkUnreachable = 0x03
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case ttlExpired = 0x06
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08

    public var description: String {
        switch self {
        case .generalFailure: return "general SOCKS server failure"
        case .connectionNotAllowed: return "connection not allowed by ruleset"
        case .networkUnreachable: return "network unreachable"
        case .hostUnreachable: return "host unreachable"
        case .connectionRefused: return "connection refused"
        case .ttlExpired: return "TTL expired"
        case .commandNotSupported: return "command not supported"
        case .addressTypeNotSupported: return "address type not supported"
        }
    }
}

/// Every way a SOCKS5 exchange can fail. Cases carry enough to explain the failure without a
/// separate message table; `replyFailed` wraps the server's own REP code.
public enum SOCKS5Error: Error, Equatable, Sendable {
    /// A reply's version byte was not `0x05` (or `0x01` for the auth sub-negotiation).
    case invalidVersion
    /// A reply was shorter than its own framing requires (truncated / not enough bytes).
    case malformedResponse
    /// The server's greeting reply was `0x05 0xFF` — none of our offered methods is acceptable.
    case noAcceptableMethods
    /// The server selected a method we never offered.
    case unexpectedMethod(UInt8)
    /// The server selected username/password auth but no credentials were configured.
    case authenticationRequired
    /// Username or password exceeds the 255-byte field limit (RFC 1929).
    case credentialTooLong
    /// The auth sub-negotiation reply reported a non-zero (failure) status.
    case authenticationFailed
    /// The auth reply's version byte was not `0x01`.
    case invalidAuthReply
    /// The target domain name exceeds the 255-byte ATYP=0x03 length field.
    case domainTooLong
    /// The server returned a recognized non-zero CONNECT REP code.
    case replyFailed(SOCKS5ReplyCode)
    /// The server returned a non-zero CONNECT REP code outside the RFC 1928 range.
    case unknownReplyCode(UInt8)
    /// A reply used an ATYP byte we do not understand.
    case unsupportedAddressType(UInt8)
}

// MARK: - Pure protocol logic

/// Pure, I/O-free SOCKS5 wire encoding/decoding. Every function is a total function over its
/// input bytes: given the same input it always yields the same output (or the same thrown
/// error), which is exactly what makes the whole protocol unit-testable without a socket.
public enum SOCKS5Handshake {

    // Protocol constants (RFC 1928 / RFC 1929).
    private static let version: UInt8 = 0x05
    private static let authVersion: UInt8 = 0x01
    private static let commandConnect: UInt8 = 0x01
    private static let commandUDPAssociate: UInt8 = 0x03
    private static let reserved: UInt8 = 0x00

    private static let methodNoAuth: UInt8 = 0x00
    private static let methodUsernamePassword: UInt8 = 0x02
    private static let methodNoAcceptable: UInt8 = 0xFF

    private static let replySucceeded: UInt8 = 0x00

    private static let atypIPv4: UInt8 = 0x01
    private static let atypDomain: UInt8 = 0x03
    private static let atypIPv6: UInt8 = 0x04

    // MARK: Greeting

    /// Client greeting (RFC 1928 §3). With credentials we offer username/password *and* no-auth
    /// (preferring the former); without, only no-auth.
    public static func greetingBytes(hasCredentials: Bool) -> [UInt8] {
        if hasCredentials {
            return [version, 2, methodUsernamePassword, methodNoAuth]
        }
        return [version, 1, methodNoAuth]
    }

    /// Parse the server's method-selection reply `0x05 <method>`.
    public static func parseMethodSelection(_ bytes: [UInt8]) throws -> SOCKS5Method {
        guard bytes.count >= 2 else { throw SOCKS5Error.malformedResponse }
        guard bytes[0] == version else { throw SOCKS5Error.invalidVersion }
        switch bytes[1] {
        case methodNoAuth:
            return .noAuth
        case methodUsernamePassword:
            return .usernamePassword
        case methodNoAcceptable:
            throw SOCKS5Error.noAcceptableMethods
        default:
            throw SOCKS5Error.unexpectedMethod(bytes[1])
        }
    }

    // MARK: Auth (RFC 1929)

    /// Username/password auth request: `0x01 ulen username plen password`.
    public static func authRequestBytes(username: String, password: String) throws -> [UInt8] {
        let user = Array(username.utf8)
        let pass = Array(password.utf8)
        guard user.count <= 255, pass.count <= 255 else { throw SOCKS5Error.credentialTooLong }
        var out: [UInt8] = [authVersion, UInt8(user.count)]
        out.append(contentsOf: user)
        out.append(UInt8(pass.count))
        out.append(contentsOf: pass)
        return out
    }

    /// Parse the auth sub-negotiation reply `0x01 <status>`; status `0x00` is success.
    public static func parseAuthReply(_ bytes: [UInt8]) throws {
        guard bytes.count >= 2 else { throw SOCKS5Error.malformedResponse }
        guard bytes[0] == authVersion else { throw SOCKS5Error.invalidAuthReply }
        guard bytes[1] == 0x00 else { throw SOCKS5Error.authenticationFailed }
    }

    // MARK: CONNECT request

    /// CONNECT request: `0x05 0x01 0x00` + ATYP + addr + big-endian port. The ATYP is chosen by
    /// inspecting `host`: a strict IPv4 literal → 0x01, a strict IPv6 literal → 0x04, otherwise a
    /// domain name → 0x03 (length-prefixed).
    public static func connectRequestBytes(host: String, port: UInt16) throws -> [UInt8] {
        var out: [UInt8] = [version, commandConnect, reserved]
        out.append(contentsOf: try encodeAddress(host))
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    /// UDP ASSOCIATE 请求(CMD=0x03)。DST 用 `0.0.0.0:0`——RFC 1928 允许客户端事先不知道自己的
    /// UDP 源地址时这样填,代理据此在回复里给出 relay 的 BND.ADDR:BND.PORT。此后 UDP 数据报发到那里。
    public static func associateRequestBytes() -> [UInt8] {
        [version, commandUDPAssociate, reserved, atypIPv4, 0, 0, 0, 0, 0, 0]
    }

    /// ATYP + address bytes for a target host string.
    private static func encodeAddress(_ host: String) throws -> [UInt8] {
        if let v4 = ipv4Bytes(host) {
            return [atypIPv4] + v4
        }
        if let v6 = ipv6Bytes(host) {
            return [atypIPv6] + v6
        }
        let hostBytes = Array(host.utf8)
        guard hostBytes.count <= 255 else { throw SOCKS5Error.domainTooLong }
        return [atypDomain, UInt8(hostBytes.count)] + hostBytes
    }

    // MARK: CONNECT reply

    /// Parse a full CONNECT reply `0x05 REP RSV ATYP BND.ADDR BND.PORT`. On REP `0x00` returns the
    /// bound address/port; on any non-zero REP throws the mapped ``SOCKS5Error``. Correctly
    /// consumes the variable-length BND.ADDR according to its ATYP so BND.PORT is read from the
    /// right offset.
    public static func parseConnectReply(_ bytes: [UInt8]) throws -> SOCKS5BoundAddress {
        guard bytes.count >= 4 else { throw SOCKS5Error.malformedResponse }
        guard bytes[0] == version else { throw SOCKS5Error.invalidVersion }
        try throwIfReplyFailed(bytes[1])

        var cursor = 4
        let address = try decodeAddress(atyp: bytes[3], bytes: bytes, cursor: &cursor)
        guard cursor + 2 <= bytes.count else { throw SOCKS5Error.malformedResponse }
        let port = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
        return SOCKS5BoundAddress(address: address, port: port)
    }

    private static func throwIfReplyFailed(_ rep: UInt8) throws {
        guard rep != replySucceeded else { return }
        if let code = SOCKS5ReplyCode(rawValue: rep) {
            throw SOCKS5Error.replyFailed(code)
        }
        throw SOCKS5Error.unknownReplyCode(rep)
    }

    private static func decodeAddress(atyp: UInt8, bytes: [UInt8], cursor: inout Int) throws -> SOCKS5Address {
        switch atyp {
        case atypIPv4:
            guard cursor + 4 <= bytes.count else { throw SOCKS5Error.malformedResponse }
            defer { cursor += 4 }
            return .ipv4(Array(bytes[cursor..<cursor + 4]))
        case atypIPv6:
            guard cursor + 16 <= bytes.count else { throw SOCKS5Error.malformedResponse }
            defer { cursor += 16 }
            return .ipv6(Array(bytes[cursor..<cursor + 16]))
        case atypDomain:
            guard cursor < bytes.count else { throw SOCKS5Error.malformedResponse }
            let length = Int(bytes[cursor])
            cursor += 1
            guard cursor + length <= bytes.count else { throw SOCKS5Error.malformedResponse }
            guard let host = String(bytes: bytes[cursor..<cursor + length], encoding: .utf8) else {
                throw SOCKS5Error.malformedResponse
            }
            cursor += length
            return .domain(host)
        default:
            throw SOCKS5Error.unsupportedAddressType(atyp)
        }
    }

    // MARK: IP literal detection (strict, via inet_pton — mirrors LoopbackDetector)

    /// 4 network-order bytes if `host` is a strict dotted-quad IPv4 literal, else nil.
    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    /// 16 network-order bytes if `host` is a valid IPv6 literal (any textual form), else nil.
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }
}

// MARK: - ByteStream seam

/// The single, minimal abstraction the connector needs from a transport: write some bytes,
/// or read *exactly* N bytes (blocking until they arrive or the stream ends). Keeping this
/// tiny is what lets unit tests inject a scripted double while production plugs in a real
/// `NWConnection`-backed stream (see `SOCKS5ByteStream.swift`, never touched by tests).
public protocol ByteStream: Sendable {
    func write(_ bytes: [UInt8]) async throws
    func read(exactly count: Int) async throws -> [UInt8]
}

// MARK: - SOCKS5Connector

/// Drives a full SOCKS5 CONNECT over an injected ``ByteStream``: greeting → optional
/// username/password auth → CONNECT, reading exactly the bytes each phase needs and throwing a
/// typed ``SOCKS5Error`` on any protocol failure. Holds only immutable credentials, so it is
/// trivially `Sendable`; all the wire logic is delegated to the pure ``SOCKS5Handshake``.
///
/// The connector deliberately does *not* know the proxy's own host/port — the caller connects
/// the `ByteStream` to the proxy first, then hands it in. That keeps the handshake fully
/// mockable and the proxy-dialing concern in the stream implementation.
public final class SOCKS5Connector: Sendable {
    private let username: String?
    private let password: String?

    public init(username: String? = nil, password: String? = nil) {
        self.username = username
        self.password = password
    }

    /// Convenience for the app→extension config path: pulls credentials straight off a
    /// ``ProxyServerDTO`` (its `host`/`port` belong to whoever opens the ``ByteStream``).
    public convenience init(proxyServer: ProxyServerDTO) {
        self.init(username: proxyServer.username, password: proxyServer.password)
    }

    /// Perform the handshake against `host:port` (the ultimate destination) over `stream`
    /// (already connected to the proxy). Returns the proxy's reported bound address on success.
    @discardableResult
    public func establish(
        toHost host: String,
        port: UInt16,
        over stream: any ByteStream
    ) async throws -> SOCKS5BoundAddress {
        try await stream.write(SOCKS5Handshake.greetingBytes(hasCredentials: username != nil))
        let method = try SOCKS5Handshake.parseMethodSelection(try await stream.read(exactly: 2))
        try await authenticateIfNeeded(method: method, over: stream)

        try await stream.write(try SOCKS5Handshake.connectRequestBytes(host: host, port: port))
        return try await readConnectReply(over: stream)
    }

    private func authenticateIfNeeded(method: SOCKS5Method, over stream: any ByteStream) async throws {
        guard method == .usernamePassword else { return }
        guard let username else { throw SOCKS5Error.authenticationRequired }
        let request = try SOCKS5Handshake.authRequestBytes(username: username, password: password ?? "")
        try await stream.write(request)
        try SOCKS5Handshake.parseAuthReply(try await stream.read(exactly: 2))
    }

    /// Reads the CONNECT reply incrementally — a stream can't know the frame length up front —
    /// then validates the assembled frame with the pure parser. The BND.ADDR length depends on
    /// the ATYP byte (and, for domains, a further length byte), so those are read in stages.
    private func readConnectReply(over stream: any ByteStream) async throws -> SOCKS5BoundAddress {
        let header = try await stream.read(exactly: 4) // VER REP RSV ATYP
        var frame = header
        frame += try await readBoundAddress(atyp: header[3], over: stream)
        frame += try await stream.read(exactly: 2) // BND.PORT
        return try SOCKS5Handshake.parseConnectReply(frame)
    }

    private func readBoundAddress(atyp: UInt8, over stream: any ByteStream) async throws -> [UInt8] {
        switch atyp {
        case 0x01: // IPv4
            return try await stream.read(exactly: 4)
        case 0x04: // IPv6
            return try await stream.read(exactly: 16)
        case 0x03: // domain: 1-byte length prefix, then that many bytes
            let lengthByte = try await stream.read(exactly: 1)
            return lengthByte + (try await stream.read(exactly: Int(lengthByte[0])))
        default:
            throw SOCKS5Error.unsupportedAddressType(atyp)
        }
    }
}
