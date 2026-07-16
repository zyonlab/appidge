import IPCContract

/// UDP/QUIC 的接管决策(纯函数,给扩展的 handleNewFlow 同步调用)。
///
/// 背景:HTTP CONNECT 天生不能代理 UDP、SOCKS5 UDP ASSOCIATE 尚未实现,所以对"该走代理"的进程,
/// 它的 UDP 不能真代理出去。若放任直连,proxied 应用的 QUIC(UDP 443)就绕过代理明文泄漏。
/// 主流做法(Surge/Clash 的 block-QUIC 默认)是**拦截止漏**:drop 掉这些 UDP,逼 QUIC 回落 TCP
/// 走代理。本策略据此裁决;完整 SOCKS5 UDP 代理是后续增强。
public enum UDPFlowPolicy {
    public enum Disposition: Sendable, Equatable {
        /// 拦截:接管并 drop,逼回落 TCP。
        case block
        /// 放行直连:不接管,UDP 原生直连。
        case allowDirect
        /// 经 SOCKS5 UDP ASSOCIATE 代理出去。
        case proxy
    }

    /// - Parameters:
    ///   - sourceIdentifier: flow 的来源进程身份(`sourceAppSigningIdentifier`)。
    ///   - ownIdentifiers: 我们自己组件的身份集合;命中则放行(转发环硬化,同 TCP)。
    ///   - perProcessRule: 该进程的每进程规则(nil = 无显式规则,按 direct)。
    ///   - udpPolicy: 全局 UDP 策略(仅对 `.proxied` 进程生效)。
    ///   - upstreamIsSOCKS5: 当前 active 上游是否 SOCKS5(只有 SOCKS5 能代理 UDP)。
    /// - Returns:
    ///   - 我们自己组件 / `.direct` / 无规则 → `.allowDirect`;
    ///   - 每进程 `.block` → 永远 `.block`;
    ///   - 每进程 `.proxied` → 按 `udpPolicy`:block→`.block`,direct→`.allowDirect`,
    ///     proxySOCKS5→上游是 SOCKS5 则 `.proxy`,否则 `.block`(没法代理就止漏)。
    ///   UDP 无固定目的地,这里**不**评估 host/port 细粒度规则,只按每进程规则。
    public static func disposition(
        sourceIdentifier: String,
        ownIdentifiers: Set<String>,
        perProcessRule: ProxyRuleDTO?,
        udpPolicy: UDPPolicyDTO,
        upstreamIsSOCKS5: Bool
    ) -> Disposition {
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceIdentifier, ownIdentifiers: ownIdentifiers) {
            return .allowDirect
        }
        switch perProcessRule {
        case .some(.block):
            return .block
        case .some(.proxied):
            switch udpPolicy {
            case .block: return .block
            case .direct: return .allowDirect
            case .proxySOCKS5: return upstreamIsSOCKS5 ? .proxy : .block
            }
        case .some(.direct), .some(.observe), .none:
            // observe 只对 TCP 有"记录后放行"的语义;对 UDP 没有专门的观测通道,按直连放行处理。
            return .allowDirect
        }
    }
}
