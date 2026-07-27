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
/// UDP 中继连接行的来源/目标要素(打包只为把 `startUDPRelay` 的参数数压回 lint 阈值内,
/// 同 `FlowOrigin` 的既有先例,不是必须的抽象)。
struct UDPRelayOrigin {
    let processID: ProcessIdentifierDTO
    let displayName: String?
    /// flow 的**初始**远端(UDP flow 可向多端点发包,连接行以首个端点代表,同 NE 的 flow 归组语义)。
    let host: String?
    let port: UInt16?
}

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
            return startProxiedUDPRelay(
                flow: flow, active: active, sourceID: sourceID, sourcePath: sourcePath, hostPort: hostPort
            )
        }
    }

    /// `.proxy` 分支的落地(从 `blockOrAllowUDPFlow` 抽出压 function_body_length):
    /// disposition 已保证 active 是 SOCKS5,这里兜底再判一次;不满足就接管并关闭(止漏)。
    private func startProxiedUDPRelay(
        flow: NEAppProxyUDPFlow, active: ProxyServerDTO?,
        sourceID: String, sourcePath: String?, hostPort: (String, UInt16)?
    ) -> Bool {
        guard let active, active.kind == .socks5 else {
            flow.open(withLocalFlowEndpoint: nil) { error in
                flow.closeReadWithError(error); flow.closeWriteWithError(error)
            }
            return true
        }
        let origin = UDPRelayOrigin(
            processID: ProcessIdentifierDTO(sourceID),
            displayName: sourcePath.flatMap(ProcessPathResolver.displayName(fromExecutablePath:)),
            host: hostPort?.0, port: hostPort?.1
        )
        startUDPRelay(flow: flow, proxy: active, origin: origin)
        return true
    }

    /// 建一个 SOCKS5 UDP 中继并按 id 持有(结束时经 onFinished 用同一 id 移除)。id 是 let,可安全
    /// 被 @Sendable 的 onFinished 捕获(不像捕获 relay 变量那样触发并发告警)。
    ///
    /// 计量与可见性(此前 UDP 两者皆无):按 flow 建 ``ConnectionContext``——association 建立后发
    /// .opened 并进周期字节回填注册表,中继泵双向计数(连接行)+ 经 router 批量上报(应用页/状态栏),
    /// 结束时发 closed/failed(经 emitClose,自动出注册表)。host/port 取 flow 的**初始**远端
    /// (UDP flow 可向多个端点发包,连接行以首个端点代表这条 flow,同 NE 的 flow 归组语义)。
    func startUDPRelay(flow: NEAppProxyUDPFlow, proxy: ProxyServerDTO, origin: UDPRelayOrigin) {
        let id = UUID().uuidString
        let context = ConnectionContext(
            id: id, processID: origin.processID, host: origin.host ?? "?", port: origin.port ?? 0,
            rule: .proxied, proxyKind: .socks5,
            upstreamLabel: "\(proxy.host):\(proxy.port)", upstreamKind: .single,
            openedAt: Date(), processDisplayName: origin.displayName
        )
        let relay = SOCKS5UDPRelay(
            flow: flow, proxy: proxy, context: context, router: router,
            onEstablished: { [weak self] in
                guard let self else { return }
                self.emitConnectionEvent(context, phase: .opened)
                self.registerActiveContext(context)
            },
            onFinished: { [weak self] failed in
                guard let self else { return }
                self.configLock.withLock { _ = self.storedUDPRelays.removeValue(forKey: id) }
                // association 没建立就失败的没发过 .opened,这里发 failed 让这条 flow 照样可见。
                self.emitClose(context, failed: failed)
            }
        )
        configLock.withLock { storedUDPRelays[id] = relay }
        Task { await relay.start() }
    }
}
