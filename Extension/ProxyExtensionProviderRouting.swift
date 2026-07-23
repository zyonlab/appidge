import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract

/// 本 app bundle 的根路径（形如 `/…/appidge.app`）——从扩展自身位置往上找到 `.app` 容器
/// （扩展在 `<app>.app/Contents/Library/SystemExtensions/<uuid>/<ext>.systemextension`）。
/// 放文件级常量（不进 `ProxyExtensionProvider` 类体，避免撑破 type_body_length）；只被本文件的
/// `selfBypassReason` 使用——凡从本 bundle 内运行的可执行文件（含 Sparkle Autoupdate/Updater/XPC
/// 等辅助组件，签名标识 org.sparkle-project.*、不在 ownProcessIdentifiers）都强制直连、别再代理。
private let ownAppBundlePath: String? = {
    var url = Bundle.main.bundleURL.resolvingSymlinksInPath()
    while url.pathComponents.count > 1 {
        if url.pathExtension == "app" { return url.path }
        url = url.deletingLastPathComponent()
    }
    return nil
}()

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
    ///
    /// `hostname`:flow 的 `remoteHostname`(app 用域名连时 NE 保留的原始主机名,可能为 nil)。
    /// 规则匹配与地址类硬闸对 hostname、endpoint host **两个候选各判一次,任一命中即命中**——
    /// 用户从连接现拼的规则记录的是当时观测到的字面 host(常是 IP),同一域名下次解析到另一个
    /// IP、或 NE 这次给的是域名,规则就"时灵时不灵";按两路候选匹配后,域名规则和 IP 规则都稳定生效。
    func effectiveRuleSync(
        sourceID: String, sourcePath: String?, host: String?, hostname: String?, port: UInt16?
    ) -> TCPFlowDecision {
        let (decision, reason) = resolveDecision(
            sourceID: sourceID, sourcePath: sourcePath, host: host, hostname: hostname, port: port
        )
        // 每条 flow 的判定都记一笔(不只是被接管的)——如果这里连日志都没有,说明 handleNewFlow
        // 根本没被 NE 调用;如果有但全是 bypass,说明拦截到了但规则/排除判定把它放行了。
        ExtDiag.log(
            "handleNewTCPFlow src=\(sourceID) path=\(sourcePath ?? "-") host=\(host ?? "-"):\(port?.description ?? "-") "
            + "hostname=\(hostname ?? "-") decision=\(reason)"
        )
        return decision
    }

    /// 参与匹配/硬闸的目标主机候选:remoteHostname(域名)优先、endpoint host(常为 IP)在后,
    /// 去重、去 nil。两者常常只有一个非空。
    private func hostCandidates(host: String?, hostname: String?) -> [String] {
        var seen = Set<String>()
        return [hostname, host].compactMap { $0 }.filter { seen.insert($0.lowercased()).inserted }
    }

    private func resolveDecision(
        sourceID: String, sourcePath: String?, host: String?, hostname: String?, port: UInt16?
    ) -> (TCPFlowDecision, String) {
        let candidates = hostCandidates(host: host, hostname: hostname)
        // ① 自身组件硬 bypass(接管自己必然自套死循环)。
        if let reason = selfBypassReason(sourceID: sourceID, sourcePath: sourcePath) {
            return (.bypass, reason)
        }
        // ② 完全旁路档(环检测自愈加入的进程):数据通路彻底不接管——环命中过,说明对它
        //    直连接管也不安全(或识别有漏),降到最保守,当场断环并保持断开。
        if isHardBypassOrigin(sourceID: sourceID, sourcePath: sourcePath) {
            return (.bypass, "bypass:loop-hard-bypass")
        }
        // ③ 地址类硬闸(回环/私网/上游)—— 一律 .bypass,不接管、活动栏不可见。
        //    注:回环流量实测**从不**到达 transparent proxy provider(平台限制,ExtDiag 实证
        //    loopback 判定 0 命中),这里的回环分支只是防御性兜底。
        if let reason = addressBypassReason(hosts: candidates, port: port) {
            return (.bypass, reason)
        }
        // ④ 本地代理(xray/yunti):**观测**——登记连接让活动栏可见(它连了哪里),但**绝不接管
        //    数据通路**。这不是保守,是架构决定的硬约束:本地代理是全系统代理流量的**汇聚点**,
        //    「接管+直连」意味着所有经它代理的应用的每一字节都要被我们的 pump 二次读写 =
        //    把全系统代理吞吐翻倍过一遍扩展进程(0.2.12/0.2.24/0.2.30 三次同根因事故都是这个;
        //    Proxifier 能显示 xray「Direct」是注入式拦截、Direct 零开销,与我们重写字节的语义不同)。
        //    可见性用零开销的观测通道拿,字节吞吐去「应用」表看聚合统计。
        if isLocalProxyOrigin(sourceID: sourceID, sourcePath: sourcePath) {
            return (.observe, "observe:local-proxy-origin")
        }
        // ⑤ 解出动作:细粒度规则表(首个命中)优先于每进程规则;都没有 → 默认 .direct(策略 A:
        //    默认就接管并直连计量,活动栏能看到每条连接)。
        let resolved = resolveAction(sourceID: sourceID, hosts: candidates, port: port)
        let action = resolved.rule
        let ruleSource = resolved.source
        switch action {
        case .observe:
            return (.observe, "observe:\(ruleSource)")
        case .direct, .proxied, .block:
            // 规则指定的上游 server 只对 .proxied 有意义;其余动作忽略。
            return (.handle(action, proxyServerID: action == .proxied ? resolved.serverID : nil),
                    "handle:\(ruleSource)(\(action))")
        }
    }

    /// 自身组件(app/扩展本体)硬边界:接管自己必然自套死循环。只比对静态的 `selfXxx`,
    /// **不含**本地代理(后者直连接管展示,见 `resolveDecision` ④)。
    private func selfBypassReason(sourceID: String, sourcePath: String?) -> String? {
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: selfIdentifiers) {
            return "bypass:self-identifier"
        }
        if let sourcePath,
           ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: selfExecutablePaths) {
            return "bypass:self-path(\(sourcePath))"
        }
        // 凡从本 app bundle 内运行的可执行文件都放行——覆盖 Sparkle 的 Autoupdate/Updater/XPC 等
        // 辅助组件（签名标识 org.sparkle-project.*、不在 selfIdentifiers，可执行文件也非扩展本体，
        // 但都落在本 bundle 内）发起的取 appcast / 下载更新流量，别再被自己代理（否则自更新失败）。
        if ProcessOriginExclusion.isWithinBundle(sourcePath: sourcePath, bundlePrefix: ownAppBundlePath) {
            return "bypass:self-bundle"
        }
        return nil
    }

    /// 地址类硬边界:回环 / 私网 / 上游——基础设施噪声 + 防环,与来源无关。hostname/endpoint host
    /// 两个候选各判一次(任一命中即 bypass):上游若按域名配置、flow 端点却是 IP(或反之)也兜得住。
    private func addressBypassReason(hosts: [String], port: UInt16?) -> String? {
        guard let port, !hosts.isEmpty else { return nil }
        let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
        for host in hosts {
            if LoopbackDetector.isLoopback(host: host) { return "bypass:loopback" }
            if PrivateNetworkExclusion.isPrivateNetwork(host: host) { return "bypass:private-network" }
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) { return "bypass:upstream" }
        }
        return nil
    }

    /// 解出的路由动作(规则 + 指定上游 + 命中来源标签)。取代三元组，满足 large_tuple。
    private struct ResolvedAction {
        let rule: ProxyRuleDTO
        let serverID: String?
        let source: String
    }

    /// 规则表(首个命中,hostname/endpoint host 两候选各试一次)→ 每进程规则 → 默认 `.direct`(策略 A)。
    private func resolveAction(sourceID: String, hosts: [String], port: UInt16?) -> ResolvedAction {
        if let port {
            for host in hosts {
                // firstMatchRule(非 firstMatch)拿到整条规则,才能读出它指定的 proxyServerID。
                if let matched = RuleMatcher.firstMatchRule(matchRules, app: sourceID, host: host, port: port) {
                    return ResolvedAction(rule: matched.rule, serverID: matched.proxyServerID, source: "matchRule(\(host))")
                }
            }
        }
        if let perProcess = perProcessRules[sourceID] {
            return ResolvedAction(rule: perProcess, serverID: nil, source: "perProcess")
        }
        return ResolvedAction(rule: .direct, serverID: nil, source: "default")
    }

    /// 来源是不是 app 动态查到的本地代理进程(签名标识或可执行文件路径任一命中,直连档)。
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

    /// 来源是不是环检测自愈加入的完全旁路进程(签名标识或可执行文件路径任一命中,旁路档)。
    private func isHardBypassOrigin(sourceID: String, sourcePath: String?) -> Bool {
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: hardBypassIdentifiers) {
            return true
        }
        if let sourcePath,
           ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: hardBypassPaths) {
            return true
        }
        return false
    }

    /// 观测(B):不接管数据通路,只投一条连接事件(0 字节),让它以"观测"胶囊出现在活动栏。
    /// 拿不到目的地(极少数解析不出)就跳过——没有 host 的观测行没有意义。
    ///
    /// **合并 + 节流**(见 `ObserveCoalescer`):id 由 (进程×主机×端口) 确定性生成 → app 侧
    /// upsert 同一行(不无限追加);同一目标 2s 内最多投一条 → 事件速率与连接洪流解耦。
    /// 本地代理每秒上百条短连接因此只产生"每目的地每 2s 一次"的表更新,app CPU 不再被重排吃掉。
    func emitObservedFlow(processID: ProcessIdentifierDTO, displayName: String?, host: String?, port: UInt16?) {
        guard let host, let port, let transport else { return }
        let id = ObserveCoalescer.stableID(processID: processID.value, host: host, port: port)
        let shouldEmit = configLock.withLock {
            storedObserveCoalescer.shouldEmit(key: id, now: Date().timeIntervalSince1970)
        }
        guard shouldEmit else { return }
        let event = ConnectionEventDTO(
            id: id, processID: processID, targetHost: host, targetPort: port,
            rule: .observe, proxyKind: nil, phase: .closed, bytesUp: 0, bytesDown: 0,
            openedAt: Date(), processDisplayName: displayName
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// `.proxied` → 按 ``ProxyRouteResolver`` 解析出的路由拨上游、做隧道握手,返回已就绪、可直接
    /// pump 的连接;`.direct`(含 proxied 但没配上游的 fail-open、以及本地代理被降级的那一路)则
    /// 直连目的地。实际拨号交给无状态的 ``ProxyDialer``。目标地址经 ``ProxyTargetSelector`` 优先取
    /// 原始主机名(DNS-over-proxy,让代理去解析)。
    /// 返回:已就绪连接 + 本次实际用的那台上游(负载均衡/单台带出;直连/故障转移/链为 nil)。
    func openRemote(
        to endpoint: Network.NWEndpoint, remoteHostname: String?, rule: ProxyRuleDTO,
        proxyServerID: String? = nil
    ) async throws -> (connection: NWConnection, usedServer: ProxyServerDTO?) {
        guard rule == .proxied, let (endpointHost, port) = ProxyDialer.hostPort(from: endpoint) else {
            return (try await ProxyDialer.openDirect(to: endpoint), nil)
        }
        let route = resolvedRoute(rule: rule, proxyServerID: proxyServerID)
        let target = ProxyTargetSelector.selectTarget(
            remoteHostname: remoteHostname, endpointHost: endpointHost, port: port
        )
        return try await ProxyDialer.open(
            route: route, to: target, directEndpoint: endpoint, roundRobin: roundRobinSelector
        )
    }

    /// 拨号后把连接事件的上游/协议回填成**实际用的那台**——负载均衡时每条连接落到不同上游,活动栏
    /// 因此如实显示轮询(而不是永远显示第一台的协议)。规则指定单台 / 单台模式只显示 host:port;
    /// 负载均衡带「负载均衡 · 」前缀,让模式与实际那台都可见。故障转移/链的 usedServer 为 nil,保留原标签。
    func applyActualUpstream(_ context: ConnectionContext, used: ProxyServerDTO?, ruleServer: String?) {
        guard let used else { return }
        context.proxyKind = used.kind
        context.upstreamLabel = "\(used.host):\(used.port)"   // 内容部分,模式前缀由 app 本地化
        // 规则指定了单台 → 单台(无前缀);否则按当前路由模式给出实际那台的模式。
        if ruleServer != nil {
            context.upstreamKind = .single
        } else {
            switch routingMode {
            case .loadBalance: context.upstreamKind = .loadBalance
            case .failover: context.upstreamKind = .failover
            case .single, .chain: context.upstreamKind = .single
            }
        }
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

    /// 发一条连接生命周期事件给 app(取当前累计字节)。非 private:beginFlow(主文件)与
    /// emitClose(本文件/TCPFlowPump)共用——从主文件挪来压 file_length,同既有拆文件先例。
    /// 解析这条 flow 实际要走的路由:规则指定了具体 server 且存在 → 强制 `.single`;否则按全局路由
    /// 模式 + 活动 server 解析。认不得的 id(server 被删)→ 回落全局。`openRemote` 与上游标签共用同一处。
    func resolvedRoute(rule: ProxyRuleDTO, proxyServerID: String?) -> ResolvedRoute {
        guard rule == .proxied else { return .direct }
        let config = proxyConfig
        let servers = config?.servers ?? []
        if let proxyServerID, let picked = servers.first(where: { $0.id == proxyServerID }) {
            return .single(picked)
        }
        return ProxyRouteResolver.resolve(
            mode: routingMode, servers: servers, activeServerID: config?.activeServerID
        )
    }

    /// 路由 → 上游标签的(内容, 模式)。内容语言中立(host:port 或 `A → B`),模式前缀由 app 本地化。
    /// 直连 nil;单台 host:port;链列出跳序;故障转移/负载均衡列出候选。
    func routeLabel(_ route: ResolvedRoute) -> (content: String, kind: UpstreamKindDTO)? {
        func hp(_ s: ProxyServerDTO) -> String { "\(s.host):\(s.port)" }
        switch route {
        case .direct: return nil
        case .single(let s): return (hp(s), .single)
        case .chain(let list): return (list.map(hp).joined(separator: " → "), .chain)
        case .failover(let list): return (list.map(hp).joined(separator: ", "), .failover)
        case .loadBalance(let list): return (list.map(hp).joined(separator: ", "), .loadBalance)
        }
    }

    func emitConnectionEvent(_ context: ConnectionContext, phase: ConnectionPhaseDTO) {
        guard let transport else { return }
        let bytes = context.snapshotBytes()
        let event = ConnectionEventDTO(
            id: context.id, processID: context.processID, targetHost: context.host, targetPort: context.port,
            rule: context.rule, proxyKind: context.proxyKind, phase: phase, bytesUp: bytes.up, bytesDown: bytes.down,
            openedAt: context.openedAt, processDisplayName: context.processDisplayName,
            upstreamLabel: context.upstreamLabel, upstreamKind: context.upstreamKind
        )
        Task { await transport.deliver(.connectionEvent(event)) }
    }

    /// 结束事件只发一次(两个 pump 都可能触发 teardown)。
    func emitClose(_ context: ConnectionContext, failed: Bool) {
        guard context.markClosedOnce() else { return }
        context.capture?.close() // 抓包文件随连接结束落盘关闭。
        emitConnectionEvent(context, phase: failed ? .failed : .closed)
    }
}
