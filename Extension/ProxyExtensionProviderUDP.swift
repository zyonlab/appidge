import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract

/// UDP 处理拆到独立文件(压 `ProxyExtensionProvider.swift` 的 file_length,同 `TCPFlowPump.swift`
/// 的既有先例)——跨文件访问 provider 的成员,故那几个成员在主文件里放宽到非 `private`
/// (`private` 只在同文件内的 extension 才透明)。
/// `NEAppProxyUDPFlowHandling`(macOS 15 Swift overlay):conform 后 NE 对 UDP flow 走这个
/// **带初始远端**的回调,不再经 handleNewFlow。拿到目的地才能做目的地类硬闸——
/// **DNS(53)/回环/私网/组播广播必须放行直连**,否则一条 `*→*→代理` 通配规则 + UDP 默认
/// 「拦截止漏」就把 mDNSResponder 的系统 DNS 静默丢包,全系统所有应用 timeout
/// (真机实锤 0.2.20,"Chrome 打不开网页、关掉扩展就好")。
extension ProxyExtensionProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        blockOrAllowUDPFlow(flow, remoteEndpoint: remoteEndpoint)
    }

    /// UDP/QUIC:按 3 态策略处理。allowDirect→不接管(原生直连);block→接管并 drop(止漏);
    /// proxy→经 SOCKS5 UDP ASSOCIATE 中继。`remoteEndpoint` 为 nil(老回调路径解析不出)时
    /// 跳过目的地硬闸,只按来源/规则判。
    func blockOrAllowUDPFlow(_ flow: NEAppProxyUDPFlow, remoteEndpoint: Network.NWEndpoint? = nil) -> Bool {
        let sourceID = flow.metaData.sourceAppSigningIdentifier
        let sourcePath = ProcessPathResolver.executablePath(from: flow.metaData.sourceAppAuditToken)
        // 路径维度的来源排除先判(和 TCP 侧的 effectiveRuleSync 对称)——UDPFlowPolicy.disposition
        // 内部只判了签名标识那一路,这里补第二路信号。
        if let sourcePath, ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: ownExecutablePaths) {
            ExtDiag.log("blockOrAllowUDPFlow src=\(sourceID) path=\(sourcePath) decision=bypass:own-path")
            return false
        }
        let hostPort = remoteEndpoint.flatMap(ProxyDialer.hostPort(from:))
        // UDP 发往上游本身(如 SOCKS5 UDP ASSOCIATE 的中继地址)绝不能再拦——防环,与 TCP 侧对称。
        if let (host, port) = hostPort {
            let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) {
                ExtDiag.log("blockOrAllowUDPFlow src=\(sourceID) dst=\(host):\(port) decision=bypass:upstream")
                return false
            }
        }
        let active = proxyConfig?.activeServer
        let disposition = UDPFlowPolicy.disposition(
            sourceIdentifier: sourceID,
            ownIdentifiers: ownIdentifiers,
            matchRules: matchRules,
            perProcessRule: perProcessRules[sourceID],
            udpPolicy: udpPolicy,
            upstreamIsSOCKS5: active?.kind == .socks5,
            host: hostPort?.0,
            port: hostPort?.1
        )
        ExtDiag.log(
            "blockOrAllowUDPFlow src=\(sourceID) path=\(sourcePath ?? "-") "
            + "dst=\(hostPort.map { "\($0.0):\($0.1)" } ?? "-") disposition=\(disposition)"
        )
        switch disposition {
        case .allowDirect:
            return false // 不接管,UDP 原生直连。
        case .block:
            flowLogger.log("blocking UDP flow from \(sourceID, privacy: .public)")
            flow.open(withLocalFlowEndpoint: nil) { error in
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
            return true
        case .proxy:
            // disposition 已保证 active 是 SOCKS5;兜底再判一次。
            guard let active, active.kind == .socks5 else {
                flow.open(withLocalFlowEndpoint: nil) { error in
                    flow.closeReadWithError(error); flow.closeWriteWithError(error)
                }
                return true
            }
            startUDPRelay(flow: flow, proxy: active)
            return true
        }
    }

    /// 建一个 SOCKS5 UDP 中继并按 id 持有(结束时经 onFinished 用同一 id 移除)。id 是 let,可安全
    /// 被 @Sendable 的 onFinished 捕获(不像捕获 relay 变量那样触发并发告警)。
    func startUDPRelay(flow: NEAppProxyUDPFlow, proxy: ProxyServerDTO) {
        let id = UUID().uuidString
        let relay = SOCKS5UDPRelay(flow: flow, proxy: proxy) { [weak self] in
            guard let self else { return }
            self.configLock.withLock { _ = self.storedUDPRelays.removeValue(forKey: id) }
        }
        configLock.withLock { storedUDPRelays[id] = relay }
        Task { await relay.start() }
    }
}
