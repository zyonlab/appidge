/// 动态发现的「来源进程排除」标识集合的 wire-format：app 侧用 libproc+SecCode 查到的本地代理
/// 进程(如 xray/yunti)签名标识。扩展侧与自身 app/扩展的静态标识合并后喂给
/// `EngineKit.ProcessOriginExclusion.shouldBypass`，命中即强制直连——是转发环硬化的补充一层。
public struct ProcessOriginExclusionMessage: Sendable, Equatable, Codable {
    public let identifiers: [String]

    public init(identifiers: [String]) {
        self.identifiers = identifiers
    }
}
