/// proxied 进程 UDP 处理策略的 wire-format(对齐 Core.UDPPolicy)。
public enum UDPPolicyDTO: String, Sendable, Equatable, Codable {
    case block
    case direct
    case proxySOCKS5
}
