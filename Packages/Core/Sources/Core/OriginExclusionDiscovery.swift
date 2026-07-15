/// 一次「本地代理进程发现」的结果:签名标识 + 可执行文件路径,两路信号都用来做来源排除判定
/// (扩展侧分别用两路信号各判一次 `ProcessOriginExclusion.shouldBypass`,任一命中即强制直连)。
///
/// 两路信号并存的原因:未签名/ad-hoc 签名的本地代理软件(如 xray/yunti)常有多个进程,
/// `sourceAppSigningIdentifier` 对同一个软件的不同进程可能不一致(真机验证实测过:监听配置端口
/// 的那个报 `com.example.yunti`,它另一个做实际出站连接的进程却报成 `a.out`)——可执行文件路径
/// 是更稳的第二信号,同一个软件的多个进程通常共享/关联同一个可执行文件。见
/// `IPCContract.ProcessOriginExclusionMessage` 的 wire-format 孪生。
public struct OriginExclusionDiscovery: Sendable, Equatable {
    public var identifiers: Set<String>
    public var executablePaths: Set<String>

    public init(identifiers: Set<String> = [], executablePaths: Set<String> = []) {
        self.identifiers = identifiers
        self.executablePaths = executablePaths
    }
}
