/// 代理可达性探测的**可测试接缝**（Proxifier 的 "Proxy Checker" 那颗按钮）。
///
/// 分层意图：这里只放纯抽象 + 编排，**不碰 socket**。真实的 NWConnection 实现和
/// 触发它的「测试」按钮住在 App target（协调者后续接线），这样 AppFeature 保持
/// 零 Network 依赖、可单测。UI 侧的瞬时态（.idle/.checking）是 view-local 的，
/// 不在这层建模——这层只负责把「一次探测的结果」收敛成终态。

/// TCP 层可达性探测：能连上 `host:port` 即 `true`；连不上/超时 `false`。
/// 纯抽象，真实现用 NWConnection（在 App 里），测试注入 ``MockProxyReachabilityProbe``。
public protocol ProxyReachabilityProbe: Sendable {
    func isReachable(host: String, port: UInt16) async -> Bool
}

/// 一次代理检查的状态。`.idle`/`.checking` 供 View 表达「还没点 / 检查中」的瞬时态；
/// ``ProxyChecker/check(host:port:using:)`` 只会落到两个终态之一。
public enum ProxyCheckStatus: Sendable, Equatable {
    case idle
    case checking
    case reachable
    case unreachable
}

/// 测试专用 mock：按 `"host:port"` 预置每个目标的返回值，并按调用顺序记录每次调用。
/// 未预置的 key 走合理默认值 `false`（当作「连不上」），让「忘了预置」不会假装成功。
public actor MockProxyReachabilityProbe: ProxyReachabilityProbe {
    /// 一次被记录下来的探测调用。
    public struct Call: Sendable, Equatable {
        public let host: String
        public let port: UInt16
    }

    private let results: [String: Bool]
    /// 按发生顺序累积的调用记录，供测试断言「用对的 host/port 调了」。
    public private(set) var calls: [Call] = []

    /// - Parameter results: 以 `"host:port"` 为 key 的脚本化返回表，缺省空表（一律 `false`）。
    public init(results: [String: Bool] = [:]) {
        self.results = results
    }

    public func isReachable(host: String, port: UInt16) async -> Bool {
        calls.append(Call(host: host, port: port))
        return results["\(host):\(port)"] ?? false
    }
}

/// 编排层：跑一次检查，把 probe 的布尔结果映射成终态。
/// 「怎么连」委托给注入的 probe；这层只管结果 → 状态的映射，
/// 以后要加超时/重试也落在这里，方便单测。
public enum ProxyChecker {
    public static func check(
        host: String,
        port: UInt16,
        using probe: any ProxyReachabilityProbe
    ) async -> ProxyCheckStatus {
        let reachable = await probe.isReachable(host: host, port: port)
        return reachable ? .reachable : .unreachable
    }
}
