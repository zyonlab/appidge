import Foundation
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
    /// 返回值第二项是**判定原因**的简短标签,只用于 `ExtDiag` 诊断日志(定位"用户配置不对 vs
    /// 根本没拦截到"用),不参与任何业务逻辑分支。
    ///
    /// `sourcePath`:`ProcessPathResolver` 从 flow 的 audit token 解出的可执行文件路径(可能为
    /// nil,解不出就跳过路径维度的排除)——和 `sourceID`(签名标识)是两个独立信号,各判一次
    /// `ProcessOriginExclusion.shouldBypass`,任一命中就 `.bypass`。见 `ownExecutablePaths`
    /// 的类型注释:为什么需要这第二个信号。
    func effectiveRuleSync(
        sourceID: String, sourcePath: String?, host: String?, port: UInt16?
    ) -> (TCPFlowDecision, String) {
        // 转发环硬化(按来源):我们自己组件(app/扩展)+ app 动态查到的本地代理进程发起的连接
        // 不接管——无关目的地,先判。签名标识、可执行文件路径两路信号独立判定。
        if ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourceID, ownIdentifiers: ownIdentifiers) {
            return (.bypass, "bypass:own-identifier")
        }
        if let sourcePath,
           ProcessOriginExclusion.shouldBypass(sourceIdentifier: sourcePath, ownIdentifiers: ownExecutablePaths) {
            return (.bypass, "bypass:own-path(\(sourcePath))")
        }
        if let host, let port {
            if LoopbackDetector.isLoopback(host: host) { return (.bypass, "bypass:loopback") }
            // 私网段/link-local 目的地址强制直连(本地/局域网服务不该走代理),与回环正交、互补。
            if PrivateNetworkExclusion.isPrivateNetwork(host: host) { return (.bypass, "bypass:private-network") }
            let upstreams = Set((proxyConfig?.servers ?? []).map { UpstreamEndpoint(host: $0.host, port: $0.port) })
            if UpstreamExclusion.isUpstream(host: host, port: port, upstreams: upstreams) {
                return (.bypass, "bypass:upstream")
            }
            // 细粒度规则表(进程 × 主机 × 端口)优先于每进程粗粒度规则;命中即用其动作,
            // 但命中的动作本身是 .direct 时同样不接管(见上面的回退说明)。
            if let matched = RuleMatcher.firstMatch(matchRules, app: sourceID, host: host, port: port) {
                return matched == .direct
                    ? (.bypass, "bypass:matchRule-direct")
                    : (.handle(matched), "handle:matchRule(\(matched))")
            }
        }
        let resolved = perProcessRules[sourceID] ?? .direct
        return resolved == .direct
            ? (.bypass, "bypass:perProcess-direct(hasRule=\(perProcessRules[sourceID] != nil))")
            : (.handle(resolved), "handle:perProcess(\(resolved))")
    }
}
