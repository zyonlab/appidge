/// 「走代理」的进程,它的 UDP/QUIC 怎么处理。默认 `.block`(止漏)。
///
/// 背景:HTTP CONNECT 天生不能代理 UDP;只有 SOCKS5 能(UDP ASSOCIATE)。所以:
/// - `.block`:proxied 进程的 UDP 一律拦截,逼 QUIC 回落 TCP 走代理——安全默认,不泄漏。
/// - `.direct`:放行直连(UDP 可用,但绕过代理、可能泄漏访问目标)——需要 UDP 的应用(游戏/VoIP)用。
/// - `.proxySOCKS5`:上游是 SOCKS5 时真正经 UDP ASSOCIATE 代理出去;上游非 SOCKS5 则退回 `.block`。
public enum UDPPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    case block
    case direct
    case proxySOCKS5
}
