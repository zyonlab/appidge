import Core
import IPCContract

/// 纯函数翻译层：把 Core 的上游代理状态（`[Core.ProxyServer]` + 当前生效的 id）翻成
/// 下发给扩展的 wire-format `IPCContract.AppToExtensionMessage.applyProxyConfig`。
/// 跟 `ExtensionMessageHandling` 同一套设计——Core 零依赖认不得 IPCContract 的类型，
/// 这层住在 AppFeature（既 import Core 又 import IPCContract），是两者之间唯一的桥。
/// 无副作用、方便单测穷举每个分支。
public enum ProxyConfigMapping {
    /// 把当前配置的所有上游 + active id 打包成一条 `applyProxyConfig` 消息。
    /// 服务器顺序原样保留（调用方负责排序），active id 原样透传。
    public static func proxyConfigMessage(
        servers: [Core.ProxyServer], activeID: Core.ProxyServerID?
    ) -> IPCContract.AppToExtensionMessage {
        .applyProxyConfig(
            IPCContract.ProxyConfigMessage(
                servers: servers.map(dto(from:)),
                activeServerID: activeID?.value
            )
        )
    }

    /// 把代理路由模式翻成 `applyRoutingMode` 消息。id 列表逐个取 `.value`。
    public static func routingModeMessage(_ mode: Core.ProxyRoutingMode) -> IPCContract.AppToExtensionMessage {
        .applyRoutingMode(dtoMode(from: mode))
    }

    /// 把抓包开关翻成 `setPacketCapture` 消息。
    public static func packetCaptureMessage(_ enabled: Bool) -> IPCContract.AppToExtensionMessage {
        .setPacketCapture(enabled)
    }

    /// 把 UDP 策略翻成 `setUDPPolicy` 消息。
    public static func udpPolicyMessage(_ policy: Core.UDPPolicy) -> IPCContract.AppToExtensionMessage {
        .setUDPPolicy(dtoUDPPolicy(from: policy))
    }

    /// 把动态发现的本地代理进程身份(签名标识 + 可执行文件路径)翻成 `applyProcessOriginExclusions`
    /// 消息。`Set` 无序,wire 上用 `[String]` 承载(和其它列表型 DTO 一致),顺序不作约定。
    public static func processOriginExclusionsMessage(
        direct: Core.OriginExclusionDiscovery,
        hardBypass: Core.OriginExclusionDiscovery
    ) -> IPCContract.AppToExtensionMessage {
        .applyProcessOriginExclusions(IPCContract.ProcessOriginExclusionMessage(
            identifiers: Array(direct.identifiers),
            executablePaths: Array(direct.executablePaths),
            hardBypassIdentifiers: Array(hardBypass.identifiers),
            hardBypassExecutablePaths: Array(hardBypass.executablePaths)
        ))
    }

    /// 穷举 switch(不带 default):`Core.UDPPolicy` 新增 case 时这里编译报错。
    private static func dtoUDPPolicy(from policy: Core.UDPPolicy) -> IPCContract.UDPPolicyDTO {
        switch policy {
        case .block: .block
        case .direct: .direct
        case .proxySOCKS5: .proxySOCKS5
        }
    }

    /// 穷举 switch(不带 default):`Core.ProxyRoutingMode` 新增 case 时这里编译报错。
    private static func dtoMode(from mode: Core.ProxyRoutingMode) -> IPCContract.ProxyRoutingModeDTO {
        switch mode {
        case .single: .single
        case .chain(let ids): .chain(ids.map(\.value))
        case .failover(let ids): .failover(ids.map(\.value))
        case .loadBalance(let ids): .loadBalance(ids.map(\.value))
        }
    }

    private static func dto(from server: Core.ProxyServer) -> IPCContract.ProxyServerDTO {
        IPCContract.ProxyServerDTO(
            id: server.id.value,
            host: server.host,
            port: server.port,
            kind: dtoKind(from: server.kind),
            username: server.username,
            password: server.password
        )
    }

    /// 穷举 switch（不带 default）：`Core.ProxyKind` 以后新增 case 时这里编译报错，
    /// 而不是悄悄漏映射一个协议类型。
    private static func dtoKind(from kind: Core.ProxyKind) -> IPCContract.ProxyKindDTO {
        switch kind {
        case .socks5: .socks5
        case .httpConnect: .httpConnect
        }
    }
}
