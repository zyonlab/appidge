import Foundation
import NetworkExtension
import IPCContract

/// 透明代理的网络设置构造(放 provider 类外,免得撑大类体)。remote/local 均 nil ⇒ 匹配所有
/// 出站流量,**回环除外**(Apple 文档明说 nil/nil 不含 loopback)——正好与 LoopbackDetector
/// 一致:本地/回环流量不进代理、也不被拦。
///
/// `protocol` 用显式 `.TCP` + `.UDP` 两条,与单条 `.any` 等价(Apple SDK 头文件明确 `.any`
/// 同时匹配 TCP+UDP;ProxyBridge 等真实项目用 `.any` 亦可)。逐协议写只是防御/可读性选择,**不是**
/// 修复本身——"provider connected 却收不到 flow" 的真因是转发环死循环(catch-all + 接管 .direct
/// 并 pump → 自建连接继承系统代理 → Network.framework 代理解析递归),已在 ProxyExtensionProvider
/// 的 handleNewTCPFlow 按进程选择性接管里根治。
enum TransparentProxySettings {
    static func make() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0,
                protocol: .TCP, direction: .outbound
            ),
            NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0,
                protocol: .UDP, direction: .outbound
            )
        ]
        return settings
    }
}

/// `handleNewTCPFlow` 同步解出的、要传给 `beginFlow` 的判定结果:来源身份(含可读显示名)+
/// 最终生效的 rule。打包成一个类型只是为了把 `beginFlow` 的参数数压回 lint 阈值内
/// (处理来源信息的参数原本就有好几个,新增可读进程名会超),不是必须的抽象。
struct FlowOrigin {
    let processID: ProcessIdentifierDTO
    /// 人类可读的进程名(见 `ProcessPathResolver.displayName(fromExecutablePath:)`)。
    /// 解不出可执行文件路径、或路径解不出文件名时为 nil。
    let displayName: String?
    /// 可执行文件路径(audit token 解出,可能为 nil)——环检测命中时随 loopDetected 上报,
    /// app 据此把来源进程双信号自动加入旁路排除(环自愈)。
    let executablePath: String?
    let rule: ProxyRuleDTO
    /// `rule == .proxied` 时命中规则指定走哪个上游 server 的 id;nil = 跟随全局活动 server / 路由模式。
    let proxyServerID: String?
}

/// 单条连接的上下文:身份 + 目标 + 决策(rule/proxyKind)+ 累计字节 + 结束只发一次的闸门。
/// pump 回调从不同队列并发访问字节计数,用锁保护;`@unchecked Sendable` 显式担这份线程安全。
final class ConnectionContext: @unchecked Sendable {
    let id: String
    let processID: ProcessIdentifierDTO
    let host: String
    let port: UInt16
    let rule: ProxyRuleDTO
    /// 拨号前按路由模式估计;拨号后(负载均衡/单台)回填成**实际用的那台**的协议,故为 var。
    var proxyKind: ProxyKindDTO?
    /// 实际走的上游可读标签(单台 host:port / 代理链 / 故障转移 / 负载均衡);直连为 nil。拨号后回填实际那台,故 var。
    var upstreamLabel: String?
    /// 连接建立时间戳,进每条 ConnectionEventDTO(app 侧据此排序 + 显示时间列)。
    let openedAt: Date
    /// 逐连接抓包写入器(抓包开关关时为 nil)。pump 往它写上下行字节,teardown 时 close。
    let capture: PacketCaptureWriter?
    /// 人类可读的进程名,原样透传进 ConnectionEventDTO(见 `FlowOrigin.displayName` 的注释)。
    let processDisplayName: String?

    private let lock = NSLock()
    private var up: Int64 = 0
    private var down: Int64 = 0
    private var closed = false

    init(
        id: String, processID: ProcessIdentifierDTO, host: String, port: UInt16,
        rule: ProxyRuleDTO, proxyKind: ProxyKindDTO?, upstreamLabel: String? = nil,
        openedAt: Date, capture: PacketCaptureWriter? = nil,
        processDisplayName: String? = nil
    ) {
        self.id = id
        self.processID = processID
        self.host = host
        self.port = port
        self.rule = rule
        self.proxyKind = proxyKind
        self.upstreamLabel = upstreamLabel
        self.openedAt = openedAt
        self.capture = capture
        self.processDisplayName = processDisplayName
    }

    func addUp(_ n: Int64) { lock.withLock { up += n } }
    func addDown(_ n: Int64) { lock.withLock { down += n } }
    func snapshotBytes() -> (up: Int64, down: Int64) { lock.withLock { (up, down) } }

    /// 第一次调用返回 true(该发结束事件),之后都返回 false。
    func markClosedOnce() -> Bool {
        lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
    }
}
