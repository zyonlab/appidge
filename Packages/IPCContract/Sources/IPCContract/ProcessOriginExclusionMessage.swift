/// 动态发现的「来源进程排除」信息的 wire-format：app 侧用 libproc+SecCode 查到的本地代理
/// 进程(如 xray/yunti)的签名标识 + 可执行文件路径。扩展侧与自身 app/扩展的静态标识/路径
/// 合并后喂给 `EngineKit.ProcessOriginExclusion.shouldBypass`(两路信号分别判定，任一命中即
/// 强制直连)——是转发环硬化的补充一层。
///
/// 两路信号并存的原因：未签名/ad-hoc 签名的本地代理软件常有多个进程，`sourceAppSigningIdentifier`
/// 对同一个软件的不同进程可能不一致（真机验证实测过），可执行文件路径是更稳的第二信号（同一个
/// 软件的多个进程通常共享/关联同一个可执行文件）。
public struct ProcessOriginExclusionMessage: Sendable, Equatable, Codable {
    /// **直连档**(端口发现的本地代理,如 xray/yunti):接管 + 强制直连——活动栏可见、有真实
    /// 字节数(对齐 Proxifier 的 auto-created Direct 规则),但绝不代理回它自己。
    public let identifiers: [String]
    public let executablePaths: [String]
    /// **完全旁路档**(环检测自愈加入):数据通路彻底不接管。环命中说明直连档不够
    /// (或识别有漏),降一级到最保守的处理,当场断环。
    public let hardBypassIdentifiers: [String]
    public let hardBypassExecutablePaths: [String]

    public init(
        identifiers: [String], executablePaths: [String] = [],
        hardBypassIdentifiers: [String] = [], hardBypassExecutablePaths: [String] = []
    ) {
        self.identifiers = identifiers
        self.executablePaths = executablePaths
        self.hardBypassIdentifiers = hardBypassIdentifiers
        self.hardBypassExecutablePaths = hardBypassExecutablePaths
    }
}
