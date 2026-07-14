/// 代理流量如何使用配置的上游:
/// - `.single`:用当前 active 那一台(现有行为,见 `AppState.activeProxyServerID`)。
/// - `.chain`:依次串起 client → ids[0] → ids[1] → ... → 目的地(每一跳 CONNECT 到下一跳)。
/// - `.failover`:按顺序试 ids,首个连上的用它;都连不上就失败。
/// - `.loadBalance`:每条连接从 ids 里轮询挑一台。
public enum ProxyRoutingMode: Sendable, Equatable, Codable {
    case single
    case chain([ProxyServerID])
    case failover([ProxyServerID])
    case loadBalance([ProxyServerID])
}
