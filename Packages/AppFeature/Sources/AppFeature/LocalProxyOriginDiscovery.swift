import Core

/// 编排层(跟 ``ProxyChecker`` 同一套设计):给定当前 ``Core/AppState`` 里的代理服务器配置,
/// 判断「当前 active 上游是不是指向本机」,是就用注入的 ``LocalProcessIdentityResolving``
/// 查询该端口的身份(签名标识 + 可执行文件路径),产出要 dispatch
/// `.proxyProcessIdentitiesResolved(_:)` 所需的 ``Core/OriginExclusionDiscovery``。真正怎么查
/// (libproc/SecCode)委托给 resolver;这层只管「什么时候该查、查到 nil 怎么办」这套决策,
/// 保持同步可测。
///
/// 决策与理由:
/// - **只查 active 上游**——只有它会真的产生转发流量;`proxyRoutingMode` 是链式/故障转移/
///   负载均衡时,非 active 的其余 `proxyServers` 此刻并不转发流量,查它们的监听端口没有
///   「防环」意义上的必要性(它们变成 active 时,下一次 discover 自然会覆盖到)。
/// - **active host 不是本机回环字面量 → 直接返回空结果,不查询**——语义上,对着一个远程
///   `10.x`/域名地址去查「本机监听表」没有意义,也避免了无谓的系统调用。
/// - **本机回环判定只做字面量精确匹配**(`127.0.0.1`/`::1`/`localhost`),不做完整
///   CIDR/私网段判定——那是 `EngineKit` 里另一支正交的地址判定(``UpstreamExclusion`` 一类)
///   的职责,这里不重复造轮子。
/// - **resolver 返回 nil(查不到监听者/进程未签名且拿不到路径)→ 视为「本轮没发现」,返回空结果**,
///   不是把上一轮的结果原样保留下去——「变化才要不要重新下发」这层幂等已经在
///   `Reducer.reduce` 里对 `dynamicOriginExclusion` 做了差分守卫
///   (见 `case .proxyProcessIdentitiesResolved`),这里没必要重复维护「记住上次结果」的状态。
public enum LocalProxyOriginDiscovery {

    /// 视为「指向本机」的 host 字面量;精确匹配,大小写敏感(配置里这几个写法本就是规范形态)。
    public static let loopbackHostLiterals: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// `host` 是否是本机回环字面量之一。
    public static func isLocalLoopback(host: String) -> Bool {
        loopbackHostLiterals.contains(host)
    }

    /// 跑一次发现:active 代理服务器若指向本机,查询该端口的身份并包成
    /// ``Core/OriginExclusionDiscovery`` 返回(签名标识、可执行文件路径各自可能为空,
    /// 取决于 resolver 查到了哪些);没有 active server、active server 不是本机回环、
    /// 或查不到任何身份信号,均返回空结果。
    public static func discover(
        state: Core.AppState,
        using resolver: any LocalProcessIdentityResolving
    ) async -> Core.OriginExclusionDiscovery {
        guard let activeID = state.activeProxyServerID,
              let activeServer = state.proxyServers[activeID],
              isLocalLoopback(host: activeServer.host) else {
            return Core.OriginExclusionDiscovery()
        }

        guard let identity = await resolver.identity(forListeningPort: activeServer.port) else {
            return Core.OriginExclusionDiscovery()
        }

        return Core.OriginExclusionDiscovery(
            identifiers: identity.signingIdentifier.map { [$0] } ?? [],
            executablePaths: identity.executablePath.map { [$0] } ?? []
        )
    }
}
