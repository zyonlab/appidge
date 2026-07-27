/// 一次「本地代理进程发现」的结果:签名标识 + 可执行文件路径,两路信号都用来做来源排除判定
/// (扩展侧分别用两路信号各判一次 `ProcessOriginExclusion.shouldBypass`,任一命中即强制直连)。
///
/// 两路信号并存的原因:未签名/ad-hoc 签名的本地代理软件(如 xray/yunti)常有多个进程,
/// `sourceAppSigningIdentifier` 对同一个软件的不同进程可能不一致(真机验证实测过:监听配置端口
/// 的那个报 `com.example.yunti`,它另一个做实际出站连接的进程却报成 `a.out`)——可执行文件路径
/// 是更稳的第二信号,同一个软件的多个进程通常共享/关联同一个可执行文件。见
/// `IPCContract.ProcessOriginExclusionMessage` 的 wire-format 孪生。
/// `Codable`:环自愈档(`AppState.loopAutoExclusions`)要随 `PersistedConfiguration` 落盘——
/// 切语言是重启生效的,不持久化就等于每次切语言都把学到的硬旁路清零。
public struct OriginExclusionDiscovery: Sendable, Equatable, Codable {
    public var identifiers: Set<String>
    public var executablePaths: Set<String>

    public init(identifiers: Set<String> = [], executablePaths: Set<String> = []) {
        self.identifiers = identifiers
        self.executablePaths = executablePaths
    }

    /// 这个"签名标识"是否**无法区分具体软件**:未签名/ad-hoc 二进制在
    /// `sourceAppSigningIdentifier` 上常报成链接器默认的 `a.out`——xray 和任何未签名 CLI
    /// (node/npx、自编译工具)共享这个标识。拿它进 identifier 排除集会把无关进程一起旁路
    /// (真机实锤:xray 被排除后,npx 因同为 a.out 而被连坐、从活动里消失且不走代理)。
    /// 这类标识**只能**靠可执行文件路径那一路信号做排除;发现器与环自愈在建集合时都要过这道滤。
    public static func isAmbiguousIdentifier(_ value: String) -> Bool {
        value.isEmpty || value == "a.out"
    }
}
