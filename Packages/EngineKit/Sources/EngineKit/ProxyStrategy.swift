import IPCContract

public enum ProxyStrategyError: Error, Equatable, Sendable {
    case noProxies
}

/// 轮询选择器:负载均衡时每条连接挑一个上游。actor 保护内部游标。
public actor RoundRobinSelector {
    private var cursor = 0

    public init() {}

    /// 返回 `0..<count` 里的下一个下标(轮转);`count == 0` 返回 nil。
    public func next(count: Int) -> Int? {
        guard count > 0 else { return nil }
        let index = cursor % count
        cursor = (cursor + 1) % count
        return index
    }
}

/// 代理链:client → proxies[0] → proxies[1] → ... → destination。
/// 纯序列器——真正的"拨号 + 握手"由注入的 `hop` 完成(生产环境用真实 NWConnection + SOCKS5/HTTP,
/// 测试注入 mock)。`hop(proxy, targetHost, targetPort, base)`:
/// - `base == nil` → 新拨到 `proxy`,握手 targeting `targetHost:targetPort`;
/// - `base != nil` → 在上一跳已建立的、通往 `proxy` 的隧道(`base`)上握手 targeting 目标;
/// 返回通往该 target 的 ByteStream(链里就是复用同一条、逐层深入的隧道)。
public enum ChainConnector {
    @discardableResult
    public static func connect(
        proxies: [ProxyServerDTO],
        destinationHost: String,
        destinationPort: UInt16,
        hop: (_ proxy: ProxyServerDTO, _ targetHost: String, _ targetPort: UInt16, _ base: (any ByteStream)?) async throws -> any ByteStream
    ) async throws -> any ByteStream {
        guard !proxies.isEmpty else { throw ProxyStrategyError.noProxies }
        var base: (any ByteStream)?
        for index in proxies.indices {
            let isLast = index == proxies.count - 1
            let targetHost = isLast ? destinationHost : proxies[index + 1].host
            let targetPort = isLast ? destinationPort : proxies[index + 1].port
            base = try await hop(proxies[index], targetHost, targetPort, base)
        }
        // proxies 非空 → 循环至少跑一次 → base 一定非 nil。
        return base!
    }
}

/// 故障转移:按顺序尝试每个上游,返回**首个**成功的结果;全失败则抛最后一个错误。
/// 实际"单跳连接"由注入的 `attempt` 完成(生产用真实连接,测试注入 mock)。
public enum FailoverConnector {
    public static func connect<Result>(
        proxies: [ProxyServerDTO],
        attempt: (_ proxy: ProxyServerDTO) async throws -> Result
    ) async throws -> Result {
        guard !proxies.isEmpty else { throw ProxyStrategyError.noProxies }
        var lastError: Error?
        for proxy in proxies {
            do {
                return try await attempt(proxy)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProxyStrategyError.noProxies
    }
}
