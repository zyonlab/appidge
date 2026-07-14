import Foundation
import NetworkExtension
import IPCContract

/// 透明代理的网络设置构造(放 provider 类外,免得撑大类体)。remote/local 均 nil ⇒ 匹配所有
/// 出站 TCP+UDP,**回环除外**(Apple 文档明说 nil/nil 不含 loopback)——正好与 LoopbackDetector
/// 一致:本地/回环流量不进代理、也不被拦。
enum TransparentProxySettings {
    static func make() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0,
                protocol: .any, direction: .outbound
            )
        ]
        return settings
    }
}

/// 单条连接的上下文:身份 + 目标 + 决策(rule/proxyKind)+ 累计字节 + 结束只发一次的闸门。
/// pump 回调从不同队列并发访问字节计数,用锁保护;`@unchecked Sendable` 显式担这份线程安全。
final class ConnectionContext: @unchecked Sendable {
    let id: String
    let processID: ProcessIdentifierDTO
    let host: String
    let port: UInt16
    let rule: ProxyRuleDTO
    let proxyKind: ProxyKindDTO?
    /// 逐连接抓包写入器(抓包开关关时为 nil)。pump 往它写上下行字节,teardown 时 close。
    let capture: PacketCaptureWriter?

    private let lock = NSLock()
    private var up: Int64 = 0
    private var down: Int64 = 0
    private var closed = false

    init(
        id: String, processID: ProcessIdentifierDTO, host: String, port: UInt16,
        rule: ProxyRuleDTO, proxyKind: ProxyKindDTO?, capture: PacketCaptureWriter? = nil
    ) {
        self.id = id
        self.processID = processID
        self.host = host
        self.port = port
        self.rule = rule
        self.proxyKind = proxyKind
        self.capture = capture
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
