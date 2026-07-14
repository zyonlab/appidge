import Testing
import Foundation
@testable import EngineKit

// MARK: - SOCKS5 UDP ASSOCIATE datagram codec tests (RFC 1928 §7)
//
// 与 SOCKS5HandshakeTests 一样,断言全部落在纯函数产出/解析的**确切字节**上——不碰 socket、
// 不碰 Network.framework(B4 不变量)。这是 SOCKS5 UDP 中继逻辑里唯一可穷举单测的核心:给
// 每条 UDP 数据报加/剥 `RSV|FRAG|ATYP|ADDR|PORT` 头,以及解析 TCP 控制通道上的 ASSOCIATE 应答。

@Suite("SOCKS5UDPDatagram — RFC 1928 §7 UDP 头编解码")
struct SOCKS5UDPDatagramTests {

    // MARK: encode —— 确切头字节

    @Test("encode 到 IPv4 目标:00 00 00 01 <ip4> <port> <payload>")
    func encodeIPv4() throws {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let bytes = try SOCKS5UDPDatagram.encode(host: "127.0.0.1", port: 53, payload: payload)
        #expect(bytes == [0x00, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x35, 0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test("encode 到域名目标:00 00 00 03 <len> <name> <port> <payload>")
    func encodeDomain() throws {
        let payload: [UInt8] = [0x01, 0x02]
        let bytes = try SOCKS5UDPDatagram.encode(host: "example.com", port: 443, payload: payload)
        let expected: [UInt8] =
            [0x00, 0x00, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB, 0x01, 0x02]
        #expect(bytes == expected)
    }

    @Test("encode 到 IPv6 目标:ATYP 0x04 + 16 字节地址")
    func encodeIPv6() throws {
        let payload: [UInt8] = [0xAA]
        let bytes = try SOCKS5UDPDatagram.encode(host: "2001:db8::1", port: 443, payload: payload)
        let addr: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        #expect(bytes == [0x00, 0x00, 0x00, 0x04] + addr + [0x01, 0xBB, 0xAA])
    }

    @Test("encode 空负载只产出头(RSV+FRAG+ATYP+ADDR+PORT)")
    func encodeEmptyPayload() throws {
        let bytes = try SOCKS5UDPDatagram.encode(host: "127.0.0.1", port: 53, payload: [])
        #expect(bytes == [0x00, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x35])
    }

    @Test("encode 拒绝超长(>255 字节)域名 → domainTooLong")
    func encodeRejectsLongDomain() {
        let longHost = String(repeating: "a", count: 256) + ".com"
        #expect(throws: SOCKS5UDPError.domainTooLong) {
            _ = try SOCKS5UDPDatagram.encode(host: longHost, port: 443, payload: [0x00])
        }
    }

    // MARK: decode —— 剥头,取源地址 + 负载

    @Test("decode IPv4 数据报剥头得到 host/port/payload")
    func decodeIPv4() throws {
        let datagram: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x35, 0xDE, 0xAD]
        let out = try SOCKS5UDPDatagram.decode(datagram)
        #expect(out.host == "127.0.0.1")
        #expect(out.port == 53)
        #expect(out.payload == [0xDE, 0xAD])
    }

    @Test("decode 域名数据报正确消费长度前缀")
    func decodeDomain() throws {
        let datagram: [UInt8] =
            [0x00, 0x00, 0x00, 0x03, 0x0B] + Array("example.com".utf8) + [0x01, 0xBB, 0x09]
        let out = try SOCKS5UDPDatagram.decode(datagram)
        #expect(out.host == "example.com")
        #expect(out.port == 443)
        #expect(out.payload == [0x09])
    }

    // MARK: round-trip —— 三种 ATYP 都保真

    @Test("round-trip encode→decode 保真 host/port/payload(IPv4/域名/IPv6)")
    func roundTripAllAtyps() throws {
        let cases: [SOCKS5UDPDatagram.Decoded] = [
            .init(host: "127.0.0.1", port: 53, payload: [0xDE, 0xAD, 0xBE, 0xEF]),
            .init(host: "example.com", port: 443, payload: [0x01, 0x02, 0x03]),
            .init(host: "2001:db8::1", port: 8080, payload: [0xAA, 0xBB]),
            .init(host: "::1", port: 1080, payload: [])
        ]
        for expected in cases {
            let encoded = try SOCKS5UDPDatagram.encode(
                host: expected.host, port: expected.port, payload: expected.payload)
            #expect(try SOCKS5UDPDatagram.decode(encoded) == expected)
        }
    }

    // MARK: decode 错误路径

    @Test("decode FRAG≠0(分片)抛 fragmentedUnsupported")
    func decodeFragmentedThrows() {
        let datagram: [UInt8] = [0x00, 0x00, 0x01, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x35]
        #expect(throws: SOCKS5UDPError.fragmentedUnsupported) {
            _ = try SOCKS5UDPDatagram.decode(datagram)
        }
    }

    @Test("decode 缓冲太短(不足 RSV+FRAG+ATYP)抛 malformed")
    func decodeTooShortThrows() {
        #expect(throws: SOCKS5UDPError.malformed) {
            _ = try SOCKS5UDPDatagram.decode([0x00, 0x00])
        }
    }

    @Test("decode 地址被截断(ATYP 说 IPv4 却只跟 2 字节)抛 malformed")
    func decodeTruncatedAddressThrows() {
        #expect(throws: SOCKS5UDPError.malformed) {
            _ = try SOCKS5UDPDatagram.decode([0x00, 0x00, 0x00, 0x01, 0x7F, 0x00])
        }
    }

    @Test("decode 域名长度前缀越界抛 malformed")
    func decodeTruncatedDomainThrows() {
        // 长度字节说 10,实际只跟 3 字节。
        let datagram: [UInt8] = [0x00, 0x00, 0x00, 0x03, 0x0A, 0x61, 0x62, 0x63]
        #expect(throws: SOCKS5UDPError.malformed) {
            _ = try SOCKS5UDPDatagram.decode(datagram)
        }
    }

    @Test("decode 未知 ATYP 抛 unsupportedAddressType")
    func decodeUnsupportedAtypThrows() {
        #expect(throws: SOCKS5UDPError.unsupportedAddressType(0x02)) {
            _ = try SOCKS5UDPDatagram.decode([0x00, 0x00, 0x00, 0x02, 0x00, 0x00])
        }
    }

    // MARK: parseAssociateReply —— 复用 CONNECT 应答同构解析

    @Test("parseAssociateReply 成功(REP 0x00)取出 relay 的 IPv4 BND.ADDR:BND.PORT")
    func parseAssociateReplyIPv4() throws {
        let reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x04, 0x38]
        let relay = try SOCKS5UDPDatagram.parseAssociateReply(reply)
        #expect(relay.host == "127.0.0.1")
        #expect(relay.port == 1080)
    }

    @Test("parseAssociateReply 成功取出域名 BND.ADDR")
    func parseAssociateReplyDomain() throws {
        let reply: [UInt8] =
            [0x05, 0x00, 0x00, 0x03, 0x0B] + Array("relay.local".utf8) + [0x04, 0x38]
        let relay = try SOCKS5UDPDatagram.parseAssociateReply(reply)
        #expect(relay.host == "relay.local")
        #expect(relay.port == 1080)
    }

    @Test("parseAssociateReply 成功取出 IPv6 BND.ADDR")
    func parseAssociateReplyIPv6() throws {
        let addr: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        let reply: [UInt8] = [0x05, 0x00, 0x00, 0x04] + addr + [0x04, 0x38]
        let relay = try SOCKS5UDPDatagram.parseAssociateReply(reply)
        #expect(relay.host == "2001:db8::1")
        #expect(relay.port == 1080)
    }

    @Test("parseAssociateReply 遇非 0 REP 抛 SOCKS5Error")
    func parseAssociateReplyRejectsNonZeroRep() {
        let reply: [UInt8] = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        #expect(throws: SOCKS5Error.replyFailed(.generalFailure)) {
            _ = try SOCKS5UDPDatagram.parseAssociateReply(reply)
        }
    }

    @Test("parseAssociateReply 截断缓冲抛 SOCKS5Error.malformedResponse")
    func parseAssociateReplyTruncated() {
        #expect(throws: SOCKS5Error.malformedResponse) {
            _ = try SOCKS5UDPDatagram.parseAssociateReply([0x05, 0x00, 0x00, 0x01, 0x7F, 0x00])
        }
    }
}
