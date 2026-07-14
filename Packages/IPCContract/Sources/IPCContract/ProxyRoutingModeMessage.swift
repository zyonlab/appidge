/// 代理路由模式的 wire-format(是 `Core.ProxyRoutingMode` 的传输孪生,id 用字符串)。
/// 关联的 `[String]` 是 `ProxyServerDTO.id` 列表。
public enum ProxyRoutingModeDTO: Sendable, Equatable, Codable {
    case single
    case chain([String])
    case failover([String])
    case loadBalance([String])
}
