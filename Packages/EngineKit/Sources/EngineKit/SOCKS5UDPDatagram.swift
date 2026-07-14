import Darwin
import Foundation

// MARK: - SOCKS5 UDP ASSOCIATE datagram codec (RFC 1928 §7)
//
// SOCKS5 的 UDP 中继:每条到/来自 relay 的 UDP 数据报都要带一个头
// `RSV(2)=0x0000 | FRAG(1) | ATYP(1) | DST.ADDR(变长) | DST.PORT(2, 大端) | DATA`。
// 这里是**纯**、可穷举单测的核心:只做 `[UInt8]` 进/出的头拼装与剥离,以及 TCP 控制通道上
// UDP ASSOCIATE 应答的解析。真正的 socket 中继(NEAppProxyUDPFlow ⇄ 到 relay 的 UDP
// NWConnection)是协调者的 device-only 活儿,不在此文件、也不在测试里(B4 不变量)。
//
// ATYP 方案与端口大端序刻意对齐 `SOCKS5Client.swift`(IPv4 0x01 / 域名 0x03 / IPv6 0x04,
// IP 字面量经 `inet_pton`/`inet_ntop` 判定与还原),保持全 SOCKS5 编解码风格一致。

/// SOCKS5 UDP 头编解码可能出的错。`parseAssociateReply` 另会透传 ``SOCKS5Error``(版本/REP)。
public enum SOCKS5UDPError: Error, Equatable, Sendable {
    /// FRAG≠0:数据报被分片。我们不支持重组,直接拒绝(主流实现同样不支持)。
    case fragmentedUnsupported
    /// 缓冲太短 / 地址被截断 / 域名非合法 UTF-8:按自身框长解不出一条完整数据报。
    case malformed
    /// 头里带了我们不认识的 ATYP。
    case unsupportedAddressType(UInt8)
    /// 目标域名超过 ATYP=0x03 的 255 字节长度字段。
    case domainTooLong
}

/// 纯、I/O-free 的 SOCKS5 UDP 数据报编解码。每个函数都是对输入字节的全函数:同样输入必得
/// 同样输出(或同样抛错),这正是它能脱离 socket 被穷举单测的原因。
public enum SOCKS5UDPDatagram {

    /// ``decode(_:)`` 的结果:源地址(IPv4/IPv6 字面量或域名)、大端端口、剥头后的负载。
    /// 用具名结构体而非三元组,既贴合仓库既有风格(如 ``SOCKS5BoundAddress``)也满足 lint。
    public struct Decoded: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let payload: [UInt8]

        public init(host: String, port: UInt16, payload: [UInt8]) {
            self.host = host
            self.port = port
            self.payload = payload
        }
    }

    // 协议常量(RFC 1928 §7),ATYP 取值与 SOCKS5Handshake 保持一致。
    private static let reserved: UInt8 = 0x00
    private static let frag: UInt8 = 0x00
    private static let atypIPv4: UInt8 = 0x01
    private static let atypDomain: UInt8 = 0x03
    private static let atypIPv6: UInt8 = 0x04

    // MARK: - encode

    /// 给发往某 `host:port` 的负载加上 SOCKS5 UDP 头:`00 00`(RSV)+ `00`(FRAG)+ ATYP + 地址 +
    /// 大端端口 + 负载。ATYP 由 `host` 判定:严格 IPv4 字面量→0x01,IPv6 字面量→0x04,否则域名→0x03。
    public static func encode(host: String, port: UInt16, payload: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = [reserved, reserved, frag]
        out.append(contentsOf: try encodeAddress(host))
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        out.append(contentsOf: payload)
        return out
    }

    // MARK: - decode

    /// 解一条来自 relay 的 UDP 数据报:校验 FRAG=0,按 ATYP 剥掉头,返回源地址(IPv4/IPv6 还原为
    /// 字面量字符串、域名原样返回)、端口与剩余负载。FRAG≠0 抛 ``SOCKS5UDPError/fragmentedUnsupported``。
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        // 至少 RSV(2)+FRAG(1)+ATYP(1)=4 字节;RSV 按 RFC 恒为 0,这里宽进不强校验其值。
        guard bytes.count >= 4 else { throw SOCKS5UDPError.malformed }
        guard bytes[2] == frag else { throw SOCKS5UDPError.fragmentedUnsupported }

        var cursor = 4
        let host = try decodeAddress(atyp: bytes[3], bytes: bytes, cursor: &cursor)
        guard cursor + 2 <= bytes.count else { throw SOCKS5UDPError.malformed }
        let port = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
        cursor += 2
        return Decoded(host: host, port: port, payload: Array(bytes[cursor...]))
    }

    // MARK: - parseAssociateReply

    /// 解析 TCP 控制通道上 UDP ASSOCIATE 的应答,取出 relay 的 BND.ADDR:BND.PORT(此后 UDP 发到这里)。
    /// 应答帧与 CONNECT 应答同构(`0x05 REP RSV ATYP BND.ADDR BND.PORT`),故直接复用纯解析器
    /// ``SOCKS5Handshake/parseConnectReply(_:)``:版本校验、REP 映射、变长地址消费都在其中,REP≠0
    /// 时抛 ``SOCKS5Error``。地址再还原为字面量/域名字符串返回。
    public static func parseAssociateReply(_ bytes: [UInt8]) throws -> (host: String, port: UInt16) {
        let bound = try SOCKS5Handshake.parseConnectReply(bytes)
        return (try hostString(from: bound.address), bound.port)
    }

    // MARK: - 地址编码(镜像 SOCKS5Handshake 的 ATYP 方案)

    /// ATYP + 地址字节。IPv4/IPv6 字面量走 `inet_pton`,否则当域名(长度前缀)。
    private static func encodeAddress(_ host: String) throws -> [UInt8] {
        if let v4 = ipv4Bytes(host) {
            return [atypIPv4] + v4
        }
        if let v6 = ipv6Bytes(host) {
            return [atypIPv6] + v6
        }
        let hostBytes = Array(host.utf8)
        guard hostBytes.count <= 255 else { throw SOCKS5UDPError.domainTooLong }
        return [atypDomain, UInt8(hostBytes.count)] + hostBytes
    }

    /// 按 ATYP 从 `cursor` 处读出地址并推进游标,IPv4/IPv6 还原为字面量字符串、域名原样返回。
    private static func decodeAddress(atyp: UInt8, bytes: [UInt8], cursor: inout Int) throws -> String {
        switch atyp {
        case atypIPv4:
            guard cursor + 4 <= bytes.count else { throw SOCKS5UDPError.malformed }
            defer { cursor += 4 }
            return try ipv4String(Array(bytes[cursor..<cursor + 4]))
        case atypIPv6:
            guard cursor + 16 <= bytes.count else { throw SOCKS5UDPError.malformed }
            defer { cursor += 16 }
            return try ipv6String(Array(bytes[cursor..<cursor + 16]))
        case atypDomain:
            guard cursor < bytes.count else { throw SOCKS5UDPError.malformed }
            let length = Int(bytes[cursor])
            cursor += 1
            guard cursor + length <= bytes.count else { throw SOCKS5UDPError.malformed }
            guard let host = String(bytes: bytes[cursor..<cursor + length], encoding: .utf8) else {
                throw SOCKS5UDPError.malformed
            }
            cursor += length
            return host
        default:
            throw SOCKS5UDPError.unsupportedAddressType(atyp)
        }
    }

    /// 把已解好的 ``SOCKS5Address`` 转成字面量/域名字符串(供 associate 应答复用同一还原逻辑)。
    private static func hostString(from address: SOCKS5Address) throws -> String {
        switch address {
        case .ipv4(let bytes): return try ipv4String(bytes)
        case .ipv6(let bytes): return try ipv6String(bytes)
        case .domain(let name): return name
        }
    }

    // MARK: - IP 字面量 <-> 字节(inet_pton/inet_ntop,镜像 SOCKS5Handshake)

    /// 4 个网络序字节:`host` 是严格点分十进制 IPv4 字面量时,否则 nil。
    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    /// 16 个网络序字节:`host` 是合法 IPv6 字面量(任意文本形式)时,否则 nil。
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    /// 4 个网络序字节 → 点分十进制字面量(如 `127.0.0.1`)。
    private static func ipv4String(_ bytes: [UInt8]) throws -> String {
        try presentation(of: bytes, family: AF_INET, capacity: Int(INET_ADDRSTRLEN))
    }

    /// 16 个网络序字节 → 规范化 IPv6 字面量(如 `2001:db8::1`)。
    private static func ipv6String(_ bytes: [UInt8]) throws -> String {
        try presentation(of: bytes, family: AF_INET6, capacity: Int(INET6_ADDRSTRLEN))
    }

    /// 用 `inet_ntop` 把网络序地址字节还原为文本;失败(理论上不会)按 `malformed` 处理。
    private static func presentation(of bytes: [UInt8], family: Int32, capacity: Int) throws -> String {
        var buffer = [CChar](repeating: 0, count: capacity)
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(capacity)) != nil
        }
        guard ok else { throw SOCKS5UDPError.malformed }
        return String(cString: buffer)
    }
}
