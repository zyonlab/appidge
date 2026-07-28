// swiftlint:disable file_length
// 稳定性零容忍:本文件是 NE provider 的转发热路径(beginFlow/openRemote/pump…)。仅超阈值 21 行,
// 已按既有先例把路由拆到 ProxyExtensionProviderRouting.swift;不为凑 file_length 再切分热路径,
// 避免为一个纯长度阈值给转发链引入回归风险。新增大块逻辑时应优先拆到同类型 extension 文件。
import Foundation
import Network
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract
import os.log

/// smoke-ne.sh 用 `log stream` 观测这个 subsystem，确认真实流量下
/// `sourceAppSigningIdentifier` 拿到的是父 app 级还是 CLI 子进程级身份。
let flowLogger = Logger(subsystem: "com.appidge.app.ProxyExtension", category: "FlowIdentity")

/// NEAppProxyTCPFlow 是 NetworkExtension 的旧 Obj-C API，早于 Swift 6 并发审计，
/// 但按文档「Instances of this class are thread safe」，用 `@retroactive @unchecked
/// Sendable` 显式承担这个保证（比 `@preconcurrency` 把错误压成警告更干净：A3 要求
/// 零并发警告，`@retroactive` 避免了「未来 Apple 自己加 Sendable 会冲突」的警告）。
extension NEAppProxyTCPFlow: @retroactive @unchecked Sendable {}

/// `effectiveRuleSync` 对一条 TCP flow 的判定结论。
enum TCPFlowDecision: Equatable {
    /// 完全不碰:返回 false 让系统原生处理,活动栏看不到(自身组件 / 回环 / 私网 / 上游)。
    case bypass
    /// 接管数据通路:`.proxied` 走上游、`.direct` 自己拨号直连、`.block` 拒绝——都在活动栏可见、可计量。
    /// `proxyServerID`:命中规则指定走哪个上游 server(仅 `.proxied` 有意义);nil = 跟随全局活动/路由模式。
    case handle(ProxyRuleDTO, proxyServerID: String?)
    /// 观测(B):不接管数据通路,但在活动栏记一条连接事件(进程+目的地),随即返回 false 放行。
    /// 看得见"连了哪里"、零转发开销,代价是没有逐连接速率/字节。
    case observe
}

/// NETransparentProxyProvider 的真实实现（E1）：接管每条 flow，真实双向转发字节（不是空壳），
/// 计量经 ``FlowRouter`` 批量上报，诊断经 ``DiagnosticsRunner``。
///
/// 路由决策（``effectiveRuleSync``）——**策略 A(默认全量接管展示)**,从强到弱:
/// 1. **硬边界 → `.bypass`**(见 `hardBypassReason`,不受任何规则影响):
///    - **自身组件**:发起方是我们 app/扩展本体(静态标识/路径)——接管自己必然自套死循环。
///      注意这里**不含**本地代理:后者在策略 A 下要接管展示(见第 3 条)。
///    - **回环**（``LoopbackDetector``）/ **私网段**（``PrivateNetworkExclusion``）/
///      **上游**（``UpstreamExclusion``）:基础设施噪声 + 防环("扩展连上游"这一跳若被自己再抓
///      一次就成环)。
/// 2. **解出动作**:细粒度规则表（``RuleMatcher``,首个命中)→ 每进程规则 → **默认 `.direct`**。
///    默认即接管+自己拨号直连+计量,活动栏因此能对**所有**进程显示真实速率/流量(含本地代理
///    自己的出站),不再局限于走代理的进程。用户新建的规则插在表首、优先级最高(见
///    `Core.Reducer.addMatchRule`),手动改的策略必定生效。
/// 3. **本地代理防环(两档)**:发起方是 app 动态查到的本地代理(如 xray/yunti)时走**观测**
///    ——登记可见但绝不接管数据通路(它是全系统代理流量的汇聚点,接管=全量二次转发放大,
///    三次断网同根因,见 `resolveDecision` ⑤);环检测自愈加入的进程则**完全旁路**(彻底不接管,
///    当场断环,见 ②)。
/// 4. **`.observe`(策略 B)**:不接管数据通路,只记一条连接事件让它在活动栏可见后放行——零转发
///    开销,代价是没有逐连接速率/字节。用户可对任意进程/规则显式选用。
///
/// 转发（``openRemote``）：`.proxied` 且有 active 上游 → 经 ``SOCKS5Connector`` 隧道；
/// 否则直连目的地（``ProxyDialer/openDirect(to:)`` 显式清空代理配置，避免重蹈 5a7ad53 的覆辙）。
/// 拨号/握手失败 fail-open：关掉这条 flow，不阻塞其它流量。
final class ProxyExtensionProvider: NETransparentProxyProvider, @unchecked Sendable {
    // 不是 private:UDP 中继计量在同 target 的 ProxyExtensionProviderUDP.swift 里也要上报
    // (router.route),同 transport/matchRules 的拆文件先例。
    var router: FlowRouter?
    // 非 private:`emitObservedFlow` 在同类型的跨文件 extension 里投递观测事件(同 beginFlow 的先例)。
    var transport: XPCFlowTransport?
    // 不是 private:makeDiagnosticsRunner 拆到同 target 的 ProxyExtensionProviderRouting.swift。
    var diagnosticsRunner: DiagnosticsRunner?
    private let appGroup = "group.com.appidge"
    let appliedRuleSetStore = AppliedRuleSetStore()
    let routingHistoryTracker = RoutingHistoryTracker()
    // 负载均衡的游标要跨 flow 存活才能真的轮转,所以 selector 是 provider 级的单例。
    // 非 private:`openRemote` 在同类型的跨文件 extension 里用(同 beginFlow/transport 的先例)。
    let roundRobinSelector = RoundRobinSelector()

    /// 我们自己组件(扩展 + 主 app)的进程身份集合,用于按来源做转发环硬化:这些身份发起的
    /// 连接强制直连,不再被自己抓回来代理(见 ``ProcessOriginExclusion``,与基于地址的
    /// ``UpstreamExclusion`` 正交)。扩展自己的 bundle id 从 Bundle 取,主 app 是它的父级
    /// (bundle id 去掉最后一段)。
    private static let ownProcessIdentifiers: Set<String> = {
        guard let ext = Bundle.main.bundleIdentifier else { return [] }
        let parent = ext.split(separator: ".").dropLast().joined(separator: ".")
        return parent.isEmpty ? [ext] : [ext, parent]
    }()

    /// 同上,但按可执行文件路径——从 flow 的 audit token 解出来的第二信号,和签名标识各自独立
    /// 比对(见 `ownExecutablePaths` 计算属性、`ProcessPathResolver` 的类型注释)。只收自己扩展这一个。
    private static let ownProcessExecutablePaths: Set<String> = {
        guard let path = Bundle.main.executablePath else { return [] }
        return [path]
    }()

    /// 本扩展在自己 Info.plist 里声明的 `NEMachServiceName`(版本化,构建期展开)。
    /// 注册监听必须与 plist 声明**逐字一致**,所以直接读 plist、不在代码里重拼版本公式;
    /// 读不到(不该发生)回落 legacy 名。
    static func ownMachServiceName() -> String {
        let networkExtension = Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any]
        return (networkExtension?["NEMachServiceName"] as? String) ?? XPCTransportConfig.machServiceName
    }

    // App 下发的代理配置。handleAppMessage（写）和 handleNewFlow 的 Task（读）并发访问，
    // 用锁保护——provider 已是 @unchecked Sendable，这里显式担起这份线程安全。
    // 不是 private:UDP 处理拆到同 target 的 ProxyExtensionProviderUDP.swift,需要跨文件访问
    // (private 只在同文件内的 extension 才透明,见「拆文件压行数」的既有先例,同 TCPFlowPump)。
    let configLock = NSLock()
    private var storedProxyConfig: ProxyConfigMessage?
    private var storedRoutingMode: ProxyRoutingModeDTO = .single
    // 每进程规则的同步快照:handleNewFlow(TCP 和 UDP)都必须同步决定接管与否(返回 Bool,
    // 读 actor 是 async 来不及),所以在 applyRuleSet 时额外维护这份锁保护的快照。
    private var storedPerProcessRules: [String: ProxyRuleDTO] = [:]
    // 细粒度 match 规则(进程 × 主机 × 端口)的同步快照,配合 storedPerProcessRules 让 TCP 的
    // handleNewFlow 能同步解出 effectiveRule(见 effectiveRuleSync)——不接管的流量必须在返回
    // false 前就判定,绝不能先接管再 async 决定。
    private var storedMatchRules: [MatchRuleDTO] = []
    // 主动环检测(兜底安全网):同一目标在极短窗口内被反复捕获即疑似转发环。阈值刻意调高——真实
    // 环会以每秒上千次的速度重捕,远超正常并发连接;精确阈值需真机微调(见 PROGRESS)。锁保护。
    // 环检测阈值:signature=host:port,窗内累计到 threshold 次判成环、把来源进程加自动旁路。
    // 之前 50/1s 仍误报——微信等聊天 app 一秒内对同一推送服务器开 50+ 条是正常的。真正的转发环
    // 是**瞬时爆发**(一秒上千条),合法 app 是**散在一秒里**。故收紧成「0.25s 窗内 60 次」(≈240/s
    // 的持续高速率):合法 app 达不到,真环一瞬即触发。real loop 本身也已被「本地代理来源→放行」
    // 挡在 beginFlow 之前,这里只是二级兜底,可以放宽而不牺牲安全。
    private var storedLoopDetector = LoopDetector(threshold: 60, windowSeconds: 0.25)
    // 「来源即上游」确定性环判定(一级,零阈值):flow 来源进程与本机上游端口的监听进程同族
    // ⇒ 转发即回环,单条 flow 即报;上面的速率检测器退居兜底(覆盖监听者解析失败的 fail-open
    // 缺口)。锁保护;非 private——判定编排在 ProxyExtensionProviderRouting.swift(跨文件
    // extension,同 storedUDPRelays/configLock 先例)。
    var storedSelfForwardDetector = SelfForwardLoopDetector()
    // 逐连接抓包开关(默认关)。锁保护;开着时 beginFlow 给每条连接建一个 .dmp 写入器。
    private var storedPacketCaptureEnabled = false
    // proxied 进程的 UDP 策略(默认 .block 止漏)。锁保护。
    private var storedUDPPolicy: UDPPolicyDTO = .block
    // 活跃的 SOCKS5 UDP 中继,按 flow 生命周期持有(否则 relay 被释放、连接被取消)。按生成的
    // id 存,relay 结束时经 onFinished 拿 id 移除。锁保护。
    var storedUDPRelays: [String: SOCKS5UDPRelay] = [:]
    // App 侧动态查到的本地代理进程(如 xray/yunti)签名标识集合(**直连档**:接管+强制直连,
    // 可见、有字节数,绝不代理回它自己)。运行时发现的结果,不持久化,重启后由 app 重新查、
    // applyProcessOriginExclusions 重新下发。
    private var storedDynamicOriginExclusions: Set<String> = []
    // 同上,但按可执行文件路径(见 ownExecutablePaths)——未签名/ad-hoc 签名的本地代理软件常有
    // 多个进程、签名标识因进程而异,路径是更稳的第二信号(照抄开源 ProxyBridge 的做法)。
    private var storedDynamicOriginExclusionPaths: Set<String> = []
    // **完全旁路档**(环检测自愈加入):数据通路彻底不接管。环命中说明直连档不够,降到最保守。
    private var storedHardBypassIdentifiers: Set<String> = []
    private var storedHardBypassPaths: Set<String> = []
    // 主 App 经 XPC 下发的真实 .app 根路径。安装后的系统扩展位于 /Library/SystemExtensions，
    // 无法从 Bundle.main 向上找到宿主；Sparkle helper 的 bundle-path bypass 必须用这条路径。
    private var storedHostAppBundlePath: String?
    // 配置对账:最近一次**原样收到**的排除/规则消息(apply 即整体替换,「最后收到」=「已落地」),
    // 指纹直接对它们计算——与 app 侧期望指纹同一份 ConfigFingerprint 代码、同一套 DTO 字节。
    // 锁保护;非 private——上报编排在 ConnectionStatsRefreshDriver.swift(跨文件 extension 先例)。
    var storedExclusionsMessage: ProcessOriginExclusionMessage?
    var storedRuleSetMessage: RuleSetMessage?
    // 指纹上报防抖(1s 合并一批 apply)与心跳计数(挂在 2s 统计回填 tick 上,30 tick ≈ 60s)。锁保护。
    var storedFingerprintReportScheduled = false
    var storedFingerprintHeartbeatTicks = 0
    // 观测事件的合并+节流:本地代理的高频短连接观测按 (进程×目标) 确定性 id upsert + 同目标
    // 每 2s 最多一条,避免 app 侧连接表被洪流驱动重排(见 EngineKit.ObserveCoalescer)。锁保护。
    // 非 private:emitObservedFlow 在同 target 的跨文件 extension 里访问(同其它 stored 成员先例)。
    var storedObserveCoalescer = ObserveCoalescer(interval: 2.0)
    // XPC 监听器注册自检状态(升级换血竞态下 NSXPCListener 会静默注册失败,app 永远连不上;
    // 见 ProxyExtensionProviderXPCHealth.swift 的驱动与退出决策)。锁保护。
    // 非 private:驱动逻辑拆在同 target 的跨文件 extension(同其它 stored 成员先例)。
    var storedListenerSelfCheck = XPCListenerSelfCheck()
    // 当前是否有活跃的透明代理会话(startProxy→true / stopProxy→false)。退出重生的安全闸:
    // 有会话时绝不 exit(杀进程=全系统断网,见记忆「升级黑洞」)。锁保护。
    var storedSessionActive = false
    // 活跃连接注册表(TCP + UDP 中继):周期回填驱动据此对「字节有变化」的连接重发 .opened
    // 事件刷新活动栏的发送/接收列(否则长连接存活期间字节一直显示 0,见 ConnectionStatsRefresher
    // 的类型注释)。emitClose/中继结束时移除。锁保护。
    // 非 private:驱动拆在同 target 的 ConnectionStatsRefreshDriver.swift(同其它 stored 先例)。
    var storedActiveContexts: [String: ConnectionContext] = [:]
    // 回填的差分判定(纯值,EngineKit 有测试):与上次发射的快照比,变了才发。锁保护。
    var storedStatsRefresher = ConnectionStatsRefresher()
    // 周期回填驱动任务:startProxy 起、stopProxy 取消。
    var storedStatsRefreshTask: Task<Void, Never>?

    private var packetCaptureEnabled: Bool {
        configLock.withLock { storedPacketCaptureEnabled }
    }

    var udpPolicy: UDPPolicyDTO {
        configLock.withLock { storedUDPPolicy }
    }

    var proxyConfig: ProxyConfigMessage? {
        configLock.withLock { storedProxyConfig }
    }

    var perProcessRules: [String: ProxyRuleDTO] {
        configLock.withLock { storedPerProcessRules }
    }

    // 不是 private:effectiveRuleSync 拆到同 target 的 ProxyExtensionProviderRouting.swift。
    var matchRules: [MatchRuleDTO] {
        configLock.withLock { storedMatchRules }
    }

    var routingMode: ProxyRoutingModeDTO {
        configLock.withLock { storedRoutingMode }
    }

    /// **自身组件**(app/扩展本体)的标识/路径——静态、启动时定。这一类**永远 `.bypass`**,
    /// 绝不接管自己的连接(否则必然自套死循环)。与"本地代理"区分开:后者在策略 A 下要**接管+直连+
    /// 展示**(不是 bypass),只是禁止把它代理出去(那才会转发环)。
    var selfIdentifiers: Set<String> { Self.ownProcessIdentifiers }
    var selfExecutablePaths: Set<String> { Self.ownProcessExecutablePaths }

    /// **本地代理进程**(如 xray/yunti)的标识/路径(直连档)——app 动态查到、运行时可变。
    /// 接管 + 强制直连(可见、有字节数),绝不把它的流量再代理回它自己。
    var localProxyIdentifiers: Set<String> { configLock.withLock { storedDynamicOriginExclusions } }
    var localProxyExecutablePaths: Set<String> { configLock.withLock { storedDynamicOriginExclusionPaths } }

    /// **完全旁路档**(环检测自愈):数据通路彻底不接管。
    var hardBypassIdentifiers: Set<String> { configLock.withLock { storedHardBypassIdentifiers } }
    var hardBypassPaths: Set<String> { configLock.withLock { storedHardBypassPaths } }
    var hostAppBundlePath: String? { configLock.withLock { storedHostAppBundlePath } }

    /// 自身 ∪ 本地代理 ∪ 完全旁路的并集——UDP 路径用这个"全排除"语义(本地代理/被旁路进程的
    /// UDP 一律放行直连)。TCP 的 `resolveDecision` 用上面分开的各档,不用这两个。
    var ownIdentifiers: Set<String> {
        selfIdentifiers.union(localProxyIdentifiers).union(hardBypassIdentifiers)
    }
    var ownExecutablePaths: Set<String> {
        selfExecutablePaths.union(localProxyExecutablePaths).union(hardBypassPaths)
    }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        ExtDiag.log("startProxy called")
        // 防御:startProxy 若被再次调用(app 侧双 start 竞争等),先 invalidate 上一个监听器,
        // 否则新旧两个 NSXPCListener 抢同一 mach service,app 连到旧的、flow 投到新 transport 全丢。
        // stopProxy 的 invalidate 只挡 stop→start;这里补挡 start→start。
        transport?.invalidate()
        // mach service 名以扩展自己的 Info.plist 为唯一真相源(版本化,防升级窗口新旧 job 抢
        // 同一个名字——名字占用的根治,见 Info.plist 注释);读不到时回落 legacy 名(防御)。
        let serviceName = Self.ownMachServiceName()
        ExtDiag.log("startProxy machServiceName=\(serviceName)")
        let transport = XPCFlowTransport(
            machServiceName: serviceName, upstreamHost: "127.0.0.1", upstreamPort: 1080
        )
        // 版本握手:app 每次连上就收到"是哪个版本的 provider 在服务",据此检测会话是否绑在旧扩展上。
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        transport.setReadyMessage(.extensionReady(version: version))
        self.transport = transport
        router = FlowRouter(transport: transport, flushInterval: 0.5, now: Date())
        diagnosticsRunner = makeDiagnosticsRunner(upstreamHost: "127.0.0.1", upstreamPort: 1080)

        transport.startListeningForAppMessages { [weak self] message in
            guard let self else { return }
            Task { await self.handleAppMessage(message, transport: transport) }
        }
        // 会话从此算活跃(退出重生的安全闸),随后自检监听器是否真的注册成功——升级换血竞态下
        // NSXPCListener 会静默失败,app 永远连不上(bootstrap "No such process"),扩展却带着
        // 空排除名单接管流量。自检失败先重建 listener 重试;判死后等 stopProxy(sessionless)退出重生。
        configLock.withLock { storedSessionActive = true }
        startListenerSelfCheck(transport: transport)
        // 活跃连接字节回填:每 2s 对字节有变化的连接重发 .opened 事件(见 ConnectionStatsRefreshDriver)。
        startConnectionStatsRefresh()

        // 透明代理网络设置:拦截所有出站 TCP + UDP。此前完全没设置——拦截从未真正生效(也是
        // 「待人工回填」里 flow metadata 观测被卡住的一环)。UDP 纳入拦截是 A1「拦截 QUIC/UDP
        // 止漏」的前提。⚠️ 只能在真机 + 系统扩展获批后验证,见 PROGRESS.md 人工自测。
        setTunnelNetworkSettings(TransparentProxySettings.make()) { error in
            ExtDiag.log("setTunnelNetworkSettings done error=\(error.map { "\($0)" } ?? "nil")")
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ExtDiag.log("stopProxy called reason=\(reason.rawValue)")
        configLock.withLock { storedSessionActive = false }
        stopConnectionStatsRefresh()
        // 先 invalidate 旧 XPC 监听器,释放 mach service——否则它泄漏、仍占着服务,下次 startProxy
        // 新建的监听器与它抢同一服务,新 app 连上被路由到旧监听器,flow 投到新 transport 全丢
        // (退出重开「会话通却收不到 flow」的真因)。
        transport?.invalidate()
        router = nil
        transport = nil
        diagnosticsRunner = nil
        completionHandler()
        // 自检曾判死(监听器注册失败,进程内无解)的进程,趁 sessionless 退出让 launchd 重生——
        // 这是「重启接管」能真正修复注册失败的关键一环(否则 stop→start 仍复用同一个坏进程)。
        // 健康进程 no-op;退出前有缓冲+复查,新 startProxy 随即进来也绝不带活跃会话退出。
        exitIfRegistrationFailed(reason: "stopProxy reason=\(reason.rawValue)")
    }

    private func handleAppMessage(_ message: AppToExtensionMessage, transport: XPCFlowTransport) async {
        switch message {
        case .applyRuleSet(let ruleSet):
            await applyRuleSetMessage(ruleSet)
        case .requestDiagnostic(let request):
            guard let diagnosticsRunner else { return }
            let results = await diagnosticsRunner.run(processID: request.processID, kinds: request.kinds)
            for result in results {
                await transport.deliver(.diagnosticResult(result))
            }
            return // 诊断不是配置,不触发指纹上报。
        case .applyProxyConfig(let config):
            configLock.withLock { storedProxyConfig = config }
            // active 上游变了，让 upstreamReachable 诊断跟着探新的上游地址。
            if let active = config.activeServer {
                diagnosticsRunner = makeDiagnosticsRunner(upstreamHost: active.host, upstreamPort: active.port)
            }
            ExtDiag.log("applyProxyConfig received: servers=\(config.servers.count) active=\(config.activeServerID ?? "nil")")
        case .applyRoutingMode(let mode):
            configLock.withLock { storedRoutingMode = mode }
        case .setPacketCapture(let enabled):
            configLock.withLock { storedPacketCaptureEnabled = enabled }
        case .setUDPPolicy(let policy):
            configLock.withLock { storedUDPPolicy = policy }
        case .applyProcessOriginExclusions(let message):
            applyOriginExclusionsMessage(message)
        }
        // 配置对账:任一配置落地后防抖上报当前已落地配置的指纹(见 scheduleConfigFingerprintReport)。
        scheduleConfigFingerprintReport()
    }

    private func applyRuleSetMessage(_ ruleSet: RuleSetMessage) async {
        await appliedRuleSetStore.apply(ruleSet)
        // 同步快照供 handleNewFlow(TCP+UDP)决策用。后到的同 id 覆盖先到的。
        let snapshot = Dictionary(
            ruleSet.assignments.map { ($0.processID.value, $0.rule) },
            uniquingKeysWith: { _, latest in latest }
        )
        let matchRulesSnapshot = ruleSet.matchRules
        configLock.withLock {
            storedPerProcessRules = snapshot
            storedMatchRules = matchRulesSnapshot
            storedRuleSetMessage = ruleSet // 原样留存,配置指纹对账用(见 configFingerprintLocked)
        }
        // 定位「配置到底有没有下发到扩展」的关键日志:这次收到的规则表长什么样。
        let matchRulesSummary = matchRulesSnapshot.map { rule -> String in
            let port = rule.portRange.map(String.init(describing:)) ?? "any"
            return "[\(rule.appPattern)/\(rule.hostPattern)/\(port)->\(rule.rule)]"
        }.joined(separator: ",")
        ExtDiag.log(
            "applyRuleSet received: "
            + "perProcess=\(snapshot.map { "\($0.key)->\($0.value)" }.joined(separator: ",")) "
            + "matchRules=\(matchRulesSummary)"
        )
    }

    private func applyOriginExclusionsMessage(_ message: ProcessOriginExclusionMessage) {
        configLock.withLock {
            storedDynamicOriginExclusions = Set(message.identifiers)
            storedDynamicOriginExclusionPaths = Set(message.executablePaths)
            storedHardBypassIdentifiers = Set(message.hardBypassIdentifiers)
            storedHardBypassPaths = Set(message.hardBypassExecutablePaths)
            storedHostAppBundlePath = message.hostAppBundlePath
            storedExclusionsMessage = message // 原样留存,配置指纹对账用(见 configFingerprintLocked)
        }
        ExtDiag.log(
            "applyProcessOriginExclusions received: direct=\(message.identifiers.joined(separator: ","))"
            + "/\(message.executablePaths.joined(separator: ",")) "
            + "hardBypass=\(message.hardBypassIdentifiers.joined(separator: ","))"
            + "/\(message.hardBypassExecutablePaths.joined(separator: ","))"
            + " hostAppBundle=\(message.hostAppBundlePath ?? "-")"
        )
    }

    /// 已落地配置的指纹(**调用方持 configLock**)。与 app 侧 ExpectedConfigFingerprint 调同一份
    /// `ConfigFingerprint`——指纹相等 ⟺ 两侧配置一致。nil 消息按「从未收到」的空形态计算
    /// (与 app 侧空配置指纹相等,首推前不误报)。非 private:上报编排在 Routing 文件。
    func configFingerprintLocked() -> String {
        ConfigFingerprint.compute(ConfigFingerprint.Input(
            exclusions: storedExclusionsMessage ?? ProcessOriginExclusionMessage(identifiers: []),
            proxyConfig: storedProxyConfig,
            routingMode: storedRoutingMode,
            packetCaptureEnabled: storedPacketCaptureEnabled,
            udpPolicy: storedUDPPolicy,
            ruleSet: storedRuleSetMessage ?? RuleSetMessage(assignments: [])
        ))
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleNewTCPFlow(tcpFlow)
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            return blockOrAllowUDPFlow(udpFlow)
        }
        return false
    }

    private func handleNewTCPFlow(_ tcpFlow: NEAppProxyTCPFlow) -> Bool {
        guard let router else { return false }

        let sourceID = tcpFlow.metaData.sourceAppSigningIdentifier
        let sourcePath = ProcessPathResolver.executablePath(from: tcpFlow.metaData.sourceAppAuditToken)
        let processID = ProcessIdentifierDTO(sourceID)
        let remoteEndpoint = tcpFlow.remoteFlowEndpoint
        // 原始主机名（app 用域名连的话 NE 会保留）——DNS-over-proxy 用它把域名交给代理去解析。
        let remoteHostname = tcpFlow.remoteHostname
        let hostPort = ProxyDialer.hostPort(from: remoteEndpoint)

        // 策略 A(默认):除了自身组件 / 回环 / 私网 / 上游这几道硬边界 `.bypass`,其余一律接管——
        // 含 `.direct`(自己拨号直连,不走代理),这样活动栏能对**所有**进程(含本地代理自己的出站)
        // 显示真实速率/流量。`.observe`(B)是例外:记一条连接事件让它可见,随即放行、不接管数据通路。
        // effectiveRuleSync 内部把每条 flow 的判定原因记进 ExtDiag(不只是被接管的)——定位
        // "配置没生效 vs 压根没拦截到"的关键证据,见该函数的文档注释。
        let decision = effectiveRuleSync(
            sourceID: sourceID, sourcePath: sourcePath, host: hostPort?.0, hostname: remoteHostname, port: hostPort?.1
        )
        let name = sourcePath.flatMap(ProcessPathResolver.displayName(fromExecutablePath:))
        switch decision {
        case .bypass:
            return false
        case .observe:
            // 不接管数据通路:记一条"观测"连接事件(0 字节)让活动栏看得到"这进程连了哪里",随即放行。
            // 展示优先域名(app 用域名连时 NE 保留),对齐 Proxifier 的 Target 列。
            emitObservedFlow(
                processID: processID, displayName: name, host: remoteHostname ?? hostPort?.0, port: hostPort?.1
            )
            return false
        case .handle(let rule, let proxyServerID):
            flowLogger.log("""
            handleNewTCPFlow INTERCEPT src=\(sourceID, privacy: .public) \
            rule=\(String(describing: rule), privacy: .public) host=\(hostPort?.0 ?? "-", privacy: .public)
            """)
            let sourcePid = tcpFlow.metaData.sourceAppAuditToken.flatMap(ProcessPathResolver.pid(fromAuditToken:))
            beginHandledFlow(
                tcpFlow: tcpFlow,
                origin: FlowOrigin(processID: processID, displayName: name, executablePath: sourcePath,
                                   pid: sourcePid, rule: rule, proxyServerID: proxyServerID),
                to: remoteEndpoint, remoteHostname: remoteHostname, router: router
            )
            return true
        }
    }

    // 转发热路径:仅超阈值 2 行。稳定性零容忍下不为凑 function_body_length 抽取热路径中间步骤,
    // 那会打断"解路由→建远端→双向 pump"的线性可读性并引入回归面。故就地 region-disable。
    // swiftlint:disable function_body_length
    /// 非 private:`beginHandledFlow` 在同类型的跨文件 extension(`ProxyExtensionProviderRouting`)里
    /// 调用它——同 `matchRules`/`effectiveRuleSync` 的既有先例(拆文件压 lint 阈值)。
    func beginFlow(
        tcpFlow: NEAppProxyTCPFlow,
        to remoteEndpoint: Network.NWEndpoint,
        remoteHostname: String?,
        origin: FlowOrigin,
        router: FlowRouter
    ) async {
        let processID = origin.processID
        let rule = origin.rule
        // rule 由 handleNewTCPFlow 同步解出并传入(只有 .proxied/.block 才会走到这里);不再在此
        // async 重解,既省一次 actor 往返,也避免"同步判接管、异步又判成 .direct"的竞态。
        await routingHistoryTracker.record(processID: processID, wasProxied: rule == .proxied)

        // 展示/日志/环签名优先域名(app 用域名连时 NE 保留),对齐 Proxifier 的 Target 列——
        // 同一域名换 IP 不再看起来是"不同目标",环签名也更稳。端口仍取自 endpoint。
        let endpointHostPort = ProxyDialer.hostPort(from: remoteEndpoint)
        let host = remoteHostname ?? endpointHostPort?.0 ?? "?"
        let port = endpointHostPort?.1 ?? 0

        // 主动环判定一级(确定性,「来源即上游」):来源进程与本机上游监听进程同族 ⇒ 转发即回环,
        // 单条 flow 即报,不依赖速率。监听者解析失败时 fail-open,由下面的速率检测器兜底。
        let loopSignature = "\(host):\(port)"
        evaluateSelfForwardLoop(origin: origin, signature: loopSignature)
        // 主动环检测二级(速率兜底):把这次捕获喂给检测器,命中(同目标短窗口内反复捕获)就提示
        // app,并随事件带上来源进程双信号——app 会把它自动加入旁路排除并回推(环自愈,对齐
        // Proxifier 的 auto-created Direct 规则),兜底 passive 的回环/上游/来源排除漏网的情况。
        let looped = configLock.withLock {
            storedLoopDetector.record(signature: loopSignature, now: Date().timeIntervalSince1970)
        }
        if looped, let transport {
            let origin = origin
            Task {
                await transport.deliver(.loopDetected(
                    signature: loopSignature, processID: origin.processID, executablePath: origin.executablePath
                ))
            }
        }

        // 实际所用代理协议:按解析后的路由取第一跳的 kind——proxied 但降级成直连时记 nil,
        // 让连接日志里"到底走没走代理"如实。
        let proxyKind = ProxyDialer.representativeKind(rule: rule, config: proxyConfig, mode: routingMode)
        // 上游标签(内容 + 模式),与 openRemote 用同一处路由解析;模式前缀由 app 本地化。
        let upstream = routeLabel(resolvedRoute(rule: rule, proxyServerID: origin.proxyServerID))
        // 抓包开着时给这条连接建一个 .dmp 写入器;关着(或拿不到容器)就 nil,pump 里是 no-op。
        let capture = packetCaptureEnabled
            ? PacketCaptureWriter.forConnection(
                appGroup: appGroup, processID: processID.value, host: host, port: port,
                at: Date().timeIntervalSince1970
            )
            : nil
        let context = ConnectionContext(
            id: UUID().uuidString, processID: processID, host: host, port: port,
            rule: rule, proxyKind: proxyKind, upstreamLabel: upstream?.content, upstreamKind: upstream?.kind,
            openedAt: Date(), capture: capture,
            processDisplayName: origin.displayName
        )

        // 命中 Block 规则:直接拒绝这条 flow,不建立任何远端连接。记一条 closed 事件
        // (rule=block、0 字节)让连接日志里能看到"这条被拦截了",然后返回。
        if rule == .block {
            flowLogger.log("flow blocked by rule: \(processID.value, privacy: .public) -> \(host, privacy: .public):\(port)")
            tcpFlow.closeReadWithError(nil)
            tcpFlow.closeWriteWithError(nil)
            emitClose(context, failed: false)
            return
        }

        do {
            let (remote, used) = try await openRemote(to: remoteEndpoint, remoteHostname: remoteHostname,
                                                       rule: rule, proxyServerID: origin.proxyServerID)
            // 拨号后把上游/协议回填成实际用的那台(负载均衡才看得出轮询),再发 .opened。
            applyActualUpstream(context, used: used, ruleServer: origin.proxyServerID)
            emitConnectionEvent(context, phase: .opened)
            registerActiveContext(context) // 进周期字节回填(长连接存活期间发送/接收列才会动)
            pumpClientToRemote(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
            pumpRemoteToClient(tcpFlow: tcpFlow, remote: remote, context: context, router: router)
        } catch {
            flowLogger.error("openRemote failed, closing flow: \(String(describing: error), privacy: .public)")
            tcpFlow.closeReadWithError(error)
            tcpFlow.closeWriteWithError(error)
            emitClose(context, failed: true)
        }
    }
    // swiftlint:enable function_body_length

}
