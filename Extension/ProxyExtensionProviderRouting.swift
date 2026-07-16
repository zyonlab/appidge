import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract

/// `effectiveRuleSync` 拆到独立文件(压 `ProxyExtensionProvider.swift` 的 file_length/
/// type_body_length,同 `TCPFlowPump.swift`/`ProxyExtensionProviderUDP.swift` 的既有先例)——
/// 跨文件访问 provider 的成员,故 `matchRules` 在主文件里放宽到非 `private`。
extension ProxyExtensionProvider {
    /// 复用同一个 appliedRuleSetStore/routingHistoryTracker 实例——诊断器读到的必须是
    /// handleAppMessage/handleNewFlow 实际在写的那两个 store，不是各查各的空壳。
    /// upstreamHost/Port 指向真实上游，让 upstreamReachable 诊断探的是"我们配的代理还在不在"。
    func makeDiagnosticsRunner(upstreamHost: String, upstreamPort: UInt16) -> DiagnosticsRunner {
        DiagnosticsRunner(
            ruleLookup: appliedRuleSetStore,
            routingLookup: routingHistoryTracker,
            upstreamProbe: NWConnectionUpstreamProbe(),
            dnsResolver: NWConnectionDNSResolver(),
            environmentReader: ProcessInfoEnvironmentReader(),
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort
        )
    }

    /// handleNewFlow 必须**同步**决定接管与否(返回 Bool),不能 await actor。这是原 async effectiveRule
    /// 的同步镜像:用锁保护的快照(storedMatchRules / storedPerProcessRules / storedProxyConfig)做
    /// 完全相同的判定,结论分两种:
    /// - `.bypass`:转发环硬化的四道闸(自身来源 / 回环 / 私网段 / 上游排除)命中,**或者**最终解出
    ///   的规则就是 `.direct`——一律不接管,让系统原生处理。
    /// - `.handle(rule)`:只有 `.proxied`/`.block` 才接管。
    ///
    /// ⚠️ **`.direct` 曾经短暂改成"接管但自己直连"(想让"应用"页对任意进程展示速率),已回退**:
    /// 真机验证发现本地代理软件(如 xray/yunti)在系统里往往不止一个进程——`sourceAppSigningIdentifier`
    /// 报告的身份可能因进程而异(例:监听配置端口的那个报 `com.example.yunti`,能被
    /// `LocalProxyOriginDiscovery` 正确排除;但它另一个做实际出站连接的进程却报成了完全不同的
    /// `a.out`),现有的"来源进程自动排除"只精确匹配了前者。一旦 `.direct` 也被接管,这类没被
    /// 排除到的第二个进程的**全部真实流量**都会被透明地二次转发进我们自己的 pump——不是死循环,
    /// 但是会把用户已经在用的真实代理软件的全部流量套一层不必要的转发,增加真实的 CPU/延迟开销
    /// (真机 15 分钟内 8892 条接管里 8781 条是这个进程)。
    ///
    /// **本轮补的修复**(不是再放开 `.direct`):`ownIdentifiers`/`ownExecutablePaths` 现在各自
    /// 独立比对签名标识 + 可执行文件路径两路信号(见 `ProcessPathResolver`),覆盖住了上面那次
    /// 回归里"签名标识因进程而异"的漏洞——但 `.direct` 本身是否要重新放开接管,还是留到下一轮
    /// 真机验证过两路信号确实兜住了本地代理软件的所有进程之后再说。
    ///
    /// host/port 拿不到(极少数解析不出目的地)时跳过地址类判定,只按每进程规则。
    ///
    /// 判定原因会记进 `ExtDiag` 诊断日志(定位"用户配置不对 vs 根本没拦截到"用),
    /// 不参与任何业务逻辑分支。
    ///
    /// `sourcePath`:`ProcessPathResolver` 从 flow 的 audit token 解出的可执行文件路径(可能为
    /// nil,解不出就跳过路径维度的排除)——和 `sourceID`(签名标识)是两个独立信号,各判一次
    /// `ProcessOriginExclusion.shouldBypass`,任一命中就 `.bypass`。见 `ownExecutablePaths`
    /// 的类型注释:为什么需要这第二个信号。
    func effectiveRuleSync(sourceID: String, sourcePath: String?, host: String?, port: UInt16?) -> TCPFlowDecision {
        let (decision, reason) = resolveDecision(sourceID: sourceID, sourcePath: sourcePath, host: host, port: port)
        // 每条 flow 的判定都记一笔(不只是被接管的)——如果这里连日志都没有,说明 handleNewFlow
        // 根本没被 NE 调用;如果有但全是 bypass,说明拦截到了但规则/排除判定把它放行了。
        ExtDiag.log(
            "handleNewTCPFlow src=\(sourceID) path=\(sourcePath ?? "-") host=\(host ?? "-"):\(port?.description ?? "-") "
            + "decision=\(reason)"
        )
        return decision
    }

    private func resolveDecision(
        sourceID: String, sourcePath: String?, host: String?, port: UInt16?
    ) -> (TCPFlowDecision, String) {
        // ①② 硬边界:自身组件 + 地址类(回环/私网/上游)—— 一律 .bypass,不接管、活动栏不可见。
        if let reason = hardBypassReason(sourceID: sourceID, sourcePath: sourcePath, host: host, port: port) {
            return (.bypass, reason)
        }
        // ③ 解出动作:细粒度规则表(首个命中)优先于每进程规则;都没有 → 默认 .direct(策略 A:
        //    默认就接管并直连计量,活动栏能看到每条连接,含本地代理自己的出站)。
        let (action, ruleSource) = resolveAction(sourceID: sourceID, host: host, port: port)
        // ④ 防环唯一约束:本地代理(xray/yunti)的流量**绝不能再代理回它**——解出 .proxied 就降级
        //    成 .direct(照常接管+直连+展示,只是不转发去上游)。其余动作(direct/block/observe)原样生效。
        if action == .proxied, isLocalProxyOrigin(sourceID: sourceID, sourcePath: sourcePath) {
            return (.handle(.direct), "handle:local-proxy-direct(downgraded from proxied)")
        }
        switch action {
        case .observe:
            return (.observe, "observe:\(ruleSource)")
        case .direct, .proxied, .block:
            return (.handle(action), "handle:\(ruleSource)(\(action))")
        }
    }

    /// 硬边界:命中就永远 `.bypass`(返回原因标签),不受任何规则影响。
    /// - 自身组件(app/扩展本体):接管自己必然自套死循环。只比对静态的 `selfXxx`,**不含**本地代理
    ///   (后者在策略 A 下要接管展示,只是禁止代理出去,见 `resolveDecision` ④)。
    /// - 回环 / 私网 / 上游:基础设施噪声 + 防环,与来源无关。
    private func hardBypassReason(sourceID: String, sourcePath: String?, host: String?, port: UInt16?) -> String? {
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: selfIdentifiers) {
            return "bypass:self-identifier"
        }
        if let sourcePath,
           ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: selfExecutablePaths) {
            return "bypass:self-path(\(sourcePath))"
        }
        guard let host, let port else { return nil }
        if LoopbackDetector.isLoopback(host: host) { return "bypass:loopback" }
        if PrivateNetworkExclusion.isPrivateNetwork(host: host) { return "bypass:private-network" }
        let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
        return UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) ? "bypass:upstream" : nil
    }

    /// 规则表(首个命中)→ 每进程规则 → 默认 `.direct`(策略 A)。
    private func resolveAction(sourceID: String, host: String?, port: UInt16?) -> (ProxyRuleDTO, String) {
        if let host, let port,
           let matched = RuleMatcher.firstMatch(matchRules, app: sourceID, host: host, port: port) {
            return (matched, "matchRule")
        }
        if let perProcess = perProcessRules[sourceID] { return (perProcess, "perProcess") }
        return (.direct, "default")
    }

    /// 来源是不是 app 动态查到的本地代理进程(签名标识或可执行文件路径任一命中)。
    private func isLocalProxyOrigin(sourceID: String, sourcePath: String?) -> Bool {
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: localProxyIdentifiers) {
            return true
        }
        if let sourcePath,
           ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: localProxyExecutablePaths) {
            return true
        }
        return false
    }

    /// 观测(B):不接管数据通路,只投一条连接事件(0 字节),让它以"观测"胶囊出现在活动栏。
    /// 拿不到目的地(极少数解析不出)就跳过——没有 host 的观测行没有意义。
    func emitObservedFlow(processID: ProcessIdentifierDTO, displayName: String?, host: String?, port: UInt16?) {
        guard let host, let port, let transport else { return }
        let event = ConnectionEventDTO(
            id: UUID().uuidString, processID: processID, targetHost: host, targetPort: port,
            rule: .observe, proxyKind: nil, phase: .closed, bytesUp: 0, bytesDown: 0,
            openedAt: Date(), processDisplayName: displayName
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// `.proxied` → 按 ``ProxyRouteResolver`` 解析出的路由拨上游、做隧道握手,返回已就绪、可直接
    /// pump 的连接;`.direct`(含 proxied 但没配上游的 fail-open、以及本地代理被降级的那一路)则
    /// 直连目的地。实际拨号交给无状态的 ``ProxyDialer``。目标地址经 ``ProxyTargetSelector`` 优先取
    /// 原始主机名(DNS-over-proxy,让代理去解析)。
    func openRemote(
        to endpoint: Network.NWEndpoint, remoteHostname: String?, rule: ProxyRuleDTO
    ) async throws -> NWConnection {
        guard rule == .proxied, let (endpointHost, port) = ProxyDialer.hostPort(from: endpoint) else {
            return try await ProxyDialer.openDirect(to: endpoint)
        }
        let config = proxyConfig
        let route = ProxyRouteResolver.resolve(
            mode: routingMode, servers: config?.servers ?? [], activeServerID: config?.activeServerID
        )
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: remoteHostname, endpointHost: endpointHost, port: port
        )
        return try await ProxyDialer.open(
            route: route, to: target, directEndpoint: endpoint, roundRobin: roundRobinSelector
        )
    }

    /// 接管(A):`.proxied` 走上游、`.direct` 自己拨号直连、`.block` 拒绝——都进 pump、可计量。
    func beginHandledFlow(
        tcpFlow: NEAppProxyTCPFlow, origin: FlowOrigin,
        to remoteEndpoint: Network.NWEndpoint, remoteHostname: String?, router: FlowRouter
    ) {
        tcpFlow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self, error == nil else {
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                return
            }
            Task {
                await self.beginFlow(
                    tcpFlow: tcpFlow, to: remoteEndpoint, remoteHostname: remoteHostname,
                    origin: origin, router: router
                )
            }
        }
    }
}
