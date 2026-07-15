/// 动态发现的「来源进程排除」信息的 wire-format：app 侧用 libproc+SecCode 查到的本地代理
/// 进程(如 xray/yunti)的签名标识 + 可执行文件路径。扩展侧与自身 app/扩展的静态标识/路径
/// 合并后喂给 `EngineKit.ProcessOriginExclusion.shouldBypass`(两路信号分别判定，任一命中即
/// 强制直连)——是转发环硬化的补充一层。
///
/// 两路信号并存的原因：未签名/ad-hoc 签名的本地代理软件常有多个进程，`sourceAppSigningIdentifier`
/// 对同一个软件的不同进程可能不一致（真机验证实测过），可执行文件路径是更稳的第二信号（同一个
/// 软件的多个进程通常共享/关联同一个可执行文件）。
public struct ProcessOriginExclusionMessage: Sendable, Equatable, Codable {
    public let identifiers: [String]
    public let executablePaths: [String]

    public init(identifiers: [String], executablePaths: [String] = []) {
        self.identifiers = identifiers
        self.executablePaths = executablePaths
    }
}
