import IPCContract

/// openRemote 之前唯一的路由决策:把"用户选的路由模式 + 当前下发的上游清单"解析成一条
/// 扩展能直接执行的路由。纯值语义、零 I/O,方便穷举单测。
public enum ResolvedRoute: Sendable, Equatable {
    /// 不走代理(没有可用上游时的兜底)。
    case direct
    /// 单台上游(single 模式,或多台模式降级后只剩一台/为空回落到 active)。
    case single(ProxyServerDTO)
    /// 代理链:client → chain[0] → chain[1] → ... → destination(至少两台)。
    case chain([ProxyServerDTO])
    /// 故障转移:按序尝试,首个连通的胜出(至少一台)。
    case failover([ProxyServerDTO])
    /// 负载均衡:每条连接轮询挑一台(至少一台)。
    case loadBalance([ProxyServerDTO])
}

/// 把 ``ProxyRoutingModeDTO`` 对着"当前有哪些上游"解析成 ``ResolvedRoute``。
///
/// 降级契约(全在这里,扩展现场不必重复处理):
/// - 模式里的 id 逐个对着 `servers` 解析,**认不得的 id 直接丢掉**(配置漂移不致命)。
/// - 解析后为空 → 回落到"单台 active";没有 active → `.direct`。
/// - 链解析后只剩一台 → collapse 成 `.single`(一跳的链就是单台)。
/// - 故障转移/负载均衡即便只剩一台也保持原语义(候选集如实保留)。
public enum ProxyRouteResolver {
    public static func resolve(
        mode: ProxyRoutingModeDTO,
        servers: [ProxyServerDTO],
        activeServerID: String?
    ) -> ResolvedRoute {
        // 同 id 重复时保留第一个;查表用,顺序仍以模式里的 id 列表为准。
        let byID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func resolveIDs(_ ids: [String]) -> [ProxyServerDTO] {
            ids.compactMap { byID[$0] }
        }
        func activeFallback() -> ResolvedRoute {
            guard let activeServerID, let server = byID[activeServerID] else { return .direct }
            return .single(server)
        }

        switch mode {
        case .single:
            return activeFallback()
        case .chain(let ids):
            let list = resolveIDs(ids)
            if list.isEmpty { return activeFallback() }
            if list.count == 1 { return .single(list[0]) }
            return .chain(list)
        case .failover(let ids):
            let list = resolveIDs(ids)
            return list.isEmpty ? activeFallback() : .failover(list)
        case .loadBalance(let ids):
            let list = resolveIDs(ids)
            return list.isEmpty ? activeFallback() : .loadBalance(list)
        }
    }
}
