import Testing
import Core
@testable import AppFeature

/// utun 分类:getifaddrs 快照(接口名 + 该条地址是否 IPv4)→ 哪些 utun 在「活跃路由」。
/// 判据:同名 utun 任一地址是 IPv4 即算——系统自带的 utun0-3 只有 IPv6 link-local,
/// 带 IPv4 的基本是第三方 VPN/TUN(Clash 系 fake-ip TUN 典型是 198.18.0.1)。
struct TunnelInterfaceClassifierTests {

    @Test("只有带 IPv4 的 utun 算活跃;系统 utun(仅 IPv6)与物理网卡不入选")
    func onlyIPv4TunnelsCount() {
        let entries: [(name: String, hasIPv4: Bool)] = [
            ("utun0", false), ("utun1", false),        // 系统自带,仅 IPv6 link-local
            ("utun6", false), ("utun6", true),         // 第三方 TUN:同名多地址,任一 IPv4 即算
            ("en0", true), ("lo0", true)               // 非 utun 一律无关
        ]
        #expect(TunnelInterfaceClassifier.routedTunnels(entries) == ["utun6"])
    }

    @Test("结果去重且排序稳定")
    func deduplicatedAndSorted() {
        let entries: [(name: String, hasIPv4: Bool)] = [
            ("utun9", true), ("utun4", true), ("utun9", true)
        ]
        #expect(TunnelInterfaceClassifier.routedTunnels(entries) == ["utun4", "utun9"])
    }

    @Test("空快照 → 空结果")
    func emptyInput() {
        #expect(TunnelInterfaceClassifier.routedTunnels([]).isEmpty)
    }
}
