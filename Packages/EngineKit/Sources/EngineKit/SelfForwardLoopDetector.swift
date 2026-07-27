/// 「来源即上游」主动环判定 —— 确定性、单条 flow 即判,零阈值零窗口。
///
/// 转发环的充分条件其实不需要任何速率/时序统计:一条被判 `.proxied` 的 flow,若它的**来源进程**
/// 与「即将拨号的本机上游端口的监听进程」是同一个软件(同 pid / 父子 / 兄弟 / 同进程组),
/// 那么把它转发给上游就是把它转发回它自己——按定义成环,当场可报。这是 ``LoopDetector``
/// (速率启发式,60 次/0.25s)之上的一级判定:速率检测对慢环(每圈一次 TCP+SOCKS 握手,
/// 未必冲得到 240/s)可能永远不触发,而这里两跳都不用等;速率检测退居兜底,只覆盖
/// 「监听者解析失败」的 fail-open 缺口。
///
/// 为什么必须比「进程家族」而不是 pid 相等:yunti 一类多进程代理,监听配置端口的进程和实际
/// 出站的进程**不是同一个**(真机实锤,见 `ProcessPathResolver` 的类型注释)——父子/兄弟/同组
/// 才能把「同一个软件的另一个进程」认出来。launchd(pid 1)的子进程不算兄弟,否则所有 GUI app
/// 互相连坐。
///
/// 与 ``LoopDetector`` 同一套设计纪律:纯值类型、无 I/O、不读时钟(时间戳一律调用方传入),
/// 任意隔离域可用。监听者解析(全进程表遍历)是毫秒级系统调用,**不在**本类型内——调用方拿着
/// `portsToResolve` 异步解析后经 ``storeListener(_:forPort:now:)`` 回灌,TTL 缓存;缓存冷/过期
/// 一律 fail-open(不判环),宁漏勿误。
public struct SelfForwardLoopDetector: Sendable {

    /// 一次判定的产出:是否成环 + 需要调用方发起异步解析的端口(已做在途去重)。
    public struct Verdict: Sendable, Equatable {
        public let isLoop: Bool
        public let portsToResolve: [UInt16]
    }

    /// 监听者缓存的有效期。过期后旧值**不再用于判环**(pid 可能已易主/代理已重启),
    /// 等待重新解析——fail-open。
    private let cacheTTLSeconds: Double
    /// 同一来源两次 `loopDetected` 上报之间的最小间隔(环存续期间每条 flow 都会命中,
    /// 不节流会拿转发速率刷爆 XPC)。
    private let reportIntervalSeconds: Double
    /// 解析在途的超时:发起解析后迟迟没有 `storeListener` 回灌(解析任务挂了/被丢弃),
    /// 超过此时限允许重新发起。
    private let resolutionTimeoutSeconds: Double

    private var listenerCache: [UInt16: (family: ProcessFamily?, at: Double)] = [:]
    private var resolutionRequestedAt: [UInt16: Double] = [:]
    private var lastReportedAt: [String: Double] = [:]

    public init(
        cacheTTLSeconds: Double = 30,
        reportIntervalSeconds: Double = 5,
        resolutionTimeoutSeconds: Double = 10
    ) {
        self.cacheTTLSeconds = cacheTTLSeconds
        self.reportIntervalSeconds = reportIntervalSeconds
        self.resolutionTimeoutSeconds = resolutionTimeoutSeconds
    }

    /// 对一条即将转发的 flow 判定。`flowFamily` 是来源进程的家族信息(解析失败传 nil,fail-open);
    /// `localCandidatePorts` 是本次路由里指向**本机**的候选上游端口(远程上游不可能构成本机环,
    /// 调用方已过滤;空列表 = 与本机上游无关,直接惰性返回)。
    public mutating func evaluate(
        flowFamily: ProcessFamily?, localCandidatePorts: [UInt16], now: Double
    ) -> Verdict {
        var isLoop = false
        var portsToResolve: [UInt16] = []

        for port in localCandidatePorts {
            if let cached = listenerCache[port], now - cached.at < cacheTTLSeconds {
                if let listener = cached.family, let flowFamily, flowFamily.isRelated(to: listener) {
                    isLoop = true
                }
                continue
            }
            // 缓存冷/过期:fail-open,不判环;把解析请求交还调用方(在途去重 + 超时重试)。
            if let requestedAt = resolutionRequestedAt[port], now - requestedAt < resolutionTimeoutSeconds {
                continue
            }
            resolutionRequestedAt[port] = now
            portsToResolve.append(port)
        }
        return Verdict(isLoop: isLoop, portsToResolve: portsToResolve)
    }

    /// 回灌一次监听者解析结果。`family` 为 nil 表示「该端口当前无监听者/解析不出」——同样缓存
    /// (负缓存),TTL 内不再反复发起注定失败的全进程表遍历。
    public mutating func storeListener(_ family: ProcessFamily?, forPort port: UInt16, now: Double) {
        listenerCache[port] = (family, now)
        resolutionRequestedAt.removeValue(forKey: port)
    }

    /// 判环后是否该向 app 上报(同一来源按 `reportIntervalSeconds` 节流)。
    public mutating func shouldReport(sourceKey: String, now: Double) -> Bool {
        if let last = lastReportedAt[sourceKey], now - last < reportIntervalSeconds {
            return false
        }
        // 上限防御:key 是来源路径/标识,量级本就有限;真被打爆时整体清空重来,不做 LRU。
        if lastReportedAt.count >= 256 { lastReportedAt.removeAll(keepingCapacity: true) }
        lastReportedAt[sourceKey] = now
        return true
    }
}

import IPCContract

extension SelfForwardLoopDetector {
    /// 一条已解析路由里指向**本机**的候选上游端口(远程上游的出站不经过本机 NE,不可能构成
    /// 本机环,直接排除)。链只看第一跳(扩展只拨它);故障转移/负载均衡列全部候选
    /// (任一台都可能被拨到)。
    public static func localCandidatePorts(of route: ResolvedRoute) -> [UInt16] {
        let candidates: [ProxyServerDTO]
        switch route {
        case .direct: return []
        case .single(let server): candidates = [server]
        case .chain(let servers): candidates = servers.first.map { [$0] } ?? []
        case .failover(let servers), .loadBalance(let servers): candidates = servers
        }
        return candidates.filter { LoopbackDetector.isLoopback(host: $0.host) }.map(\.port)
    }
}

/// 进程亲缘信息:pid + 父 pid + 进程组 id,``isRelated(to:)`` 判两个进程是否属于同一个软件家族。
/// 值语义、可注入构造,真实采样在 ``ListeningProcessFamilyResolver``(系统调用,不进单测)。
public struct ProcessFamily: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32?
    public let groupID: Int32?

    public init(pid: Int32, parentPid: Int32? = nil, groupID: Int32? = nil) {
        self.pid = pid
        self.parentPid = parentPid
        self.groupID = groupID
    }

    /// 同族判定:同 pid / 父子(任一方向)/ 兄弟(共同父进程,launchd 除外)/ 同进程组。
    /// launchd(pid 1)是所有 GUI app 的父进程,把它算作共同父会让全系统互相连坐,故排除;
    /// 进程组同理只认 > 1 的组。
    public func isRelated(to other: ProcessFamily) -> Bool {
        if pid == other.pid { return true }
        if let parentPid, parentPid == other.pid { return true }
        if let otherParent = other.parentPid, otherParent == pid { return true }
        if let parentPid, let otherParent = other.parentPid, parentPid == otherParent, parentPid > 1 {
            return true
        }
        if let groupID, let otherGroup = other.groupID, groupID == otherGroup, groupID > 1 {
            return true
        }
        return false
    }
}
