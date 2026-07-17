import SwiftUI
import Core
import IPCContract
import AppFeature

/// 只为一件事存在:app 退出时同步停掉透明代理会话(SwiftUI 生命周期没有等价钩子)。
/// UI 不在,接管就不该在——否则 catch-all 拦截挂在系统上没人能管,扩展一异常全系统断网,
/// 用户只能重启电脑(见 TransparentProxyController.stopCachedSessionForTermination)。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        TransparentProxyController.stopCachedSessionForTermination()
    }
}

@main
struct AppidgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: Store
    @State private var ipcReceiver: IPCReceiver
    @State private var profilesModel: ProfilesModel
    // 类而非局部变量：`store.onAction` 闭包按引用捕获它,多次 dispatch 之间能共享同一个
    // "有没有待落盘的 Task" 状态(struct 会在每次闭包创建时拿到不同的副本，防抖就失效了)。
    @State private var persistenceDebouncer = PersistenceDebouncer()
    @Environment(\.scenePhase) private var scenePhase

    // 代理密码存 Keychain，不落 JSON（见 PersistedProxyServer 结构上无 password 字段）。
    private let credentialStore: any CredentialStore = KeychainCredentialStore()
    // 连接日志落盘：每条连接事件顺带写 rolling JSONL，启动时 loadRecent 回灌（重启不丢历史）。
    private let connectionLogFileStore: ConnectionLogFileStore

    init() {
        let transport = XPCAppSideTransport()
        let connectionLogFileStore = ConnectionLogFileStore()
        self.connectionLogFileStore = connectionLogFileStore
        // 本地代理进程(如 xray/yunti)签名标识查询：libproc 查监听端口 + SecCode 取签名标识，
        // 用于转发环硬化的「来源进程自动排除」第二正交维度（见 LocalProxyOriginDiscovery）。
        let processIdentityResolver: any LocalProcessIdentityResolving = LibprocSecCodeProcessIdentityResolver()
        let store = Store(effectHandler: { effect in
            await Self.handleEffect(
                effect, transport: transport, connectionLogFileStore: connectionLogFileStore,
                processIdentityResolver: processIdentityResolver
            )
        })
        // XPC(重)连上扩展时全量重推当前配置。扩展升级/重启/掉线重连后是空规则起步的,不补推
        // 就一直空转(每条 flow 回落默认直连、什么都不接管)。[weak store] 断开 store→transport→
        // store 的保留环;dispatch 必须回到主 actor。
        transport.setOnConnect { [weak store] in
            Task { @MainActor in store?.dispatch(.resyncExtension) }
        }
        _store = State(initialValue: store)
        _ipcReceiver = State(initialValue: IPCReceiver(
            store: store, transport: transport, connectionLogFileStore: connectionLogFileStore
        ))
        _profilesModel = State(initialValue: ProfilesModel(
            store: store, profileStore: ProfileStore(), credentialStore: KeychainCredentialStore()
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.state.hasCompletedOnboarding {
                    MainWindow(store: store, profiles: profilesModel)
                } else {
                    OnboardingView(store: store)
                }
            }
            .task {
                // 扩展激活状态经 activator 的 delegate 回调回灌 store（状态栏据此如实显示）。
                SystemExtensionActivator.shared.onStateChange = { activation in
                    store.dispatch(.extensionActivationChanged(activation))
                    // 扩展获批(.active)后,必须由 app 侧启动透明代理会话,系统才会把流量交给 provider。
                    if case .active = activation {
                        Task { await TransparentProxyController.start() }
                    }
                }
                SystemExtensionActivator.shared.diagnose() // 启动即打印 app 看到的扩展目录(排查 not-found)
                await ipcReceiver.start()
                await restorePersistedConfiguration()
                await restoreRecentConnectionLog()
                await profilesModel.loadLibrary()
                // 接线放在两次 restore 之后：restore 本身就是靠重放 processDiscovered/assignRule/
                // addMatchRule 等"值得存盘"的 action 来灌回状态的,提前接线只会导致启动时又把刚读出来
                // 的东西原样存回去一次——浪费一次磁盘 I/O,不是错误,但没必要。
                store.onAction = { action in
                    guard Self.isPersistenceRelevant(action) else { return }
                    persistenceDebouncer.schedule { persistCurrentConfiguration() }
                }
                store.dispatch(.appLaunched)
                // 启动恢复完成后,把最终的完整配置全量重推给扩展一次。onConnect 那次可能发生在
                // 恢复之前(状态还空);这次确保扩展拿到的是恢复后的最新全量(规则+代理+路由+UDP+
                // 排除名单)。effect 已串行化,这次 resync 的推送排在恢复推送之后、最终胜出。
                store.dispatch(.resyncExtension)
                // **先查真实状态,再决定要不要激活/起会话**(propertiesRequest 只查询、零 UI):
                // 扩展被用户在系统设置里**停用**时,activate() 只会打扰、startVPNTunnel 必然失败,
                // XPC 也无人监听——这种状态下什么都不做,状态栏如实显示「已停用」,把人指向系统
                // 设置(真机实锤:0.2.20 前 app 曾在此状态下因 XPC 重连风暴空转 100%+ CPU)。
                // 其余状态维持老路:已完成引导就重新提交激活(幂等,兼顾升级 replace),并直接
                // 尝试起会话一次(不依赖 activate() 的 .completed 回调,旧版本它可能不回)。
                SystemExtensionActivator.shared.checkStatus { state in
                    if case .disabled = state { return }
                    if store.state.hasCompletedOnboarding {
                        SystemExtensionActivator.shared.activate()
                        Task { await TransparentProxyController.start() }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 简单的持久化触发点：场景失焦/进后台时落盘一次（覆盖"规则/目录被改过、
            // app 被关闭或切到后台"的常见路径）。onboarding 完成那一下已经在
            // OnboardingView 里单独存过一次，这里补的是之后规则/目录的变更，不做
            // 全量响应式持久化管线（每次 dispatch 都存）——那超出了这一轮的范围。
            if newPhase != .active {
                persistCurrentConfiguration()
            }
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra("appidge", systemImage: "network") {
            MenuBarView(store: store)
        }
        // .window 而非默认 .menu：内容是「仪表盘」(状态行 + Top-5 列表 + 开关),
        // 需要完整 SwiftUI 排版(语义色 / caption / 对齐),菜单渲染器会把这些收着。
        .menuBarExtraStyle(.window)
    }

    /// 启动时把上次保存的配置（扫描到的目录、分配过规则的进程、是否已完成引导）
    /// 灌回 store。只用 Core.Action 里已有的 case（见
    /// AppFeature.PersistedConfiguration.restorationActions() 的 TDD 覆盖），没有
    /// 新增任何 Core.Action。没有保存过配置（首次启动，或读取失败）就什么也不做，
    /// 让 onboarding 走它本来的路。
    @MainActor
    private func restorePersistedConfiguration() async {
        guard let configuration = await FilePersistenceStore().load() else { return }
        // 从 Keychain 回填密码，重启后恢复的代理不用重输。
        for action in await configuration.restorationActions(rehydratingCredentialsFrom: credentialStore) {
            store.dispatch(action)
        }
    }

    /// 启动时把上次落盘的连接日志（最近若干条）回灌进 store，重启后仍能看到历史连接。
    /// 每条走既有的 `connectionEventReceived`（按 id upsert），顺序 oldest→newest 与内存
    /// 环形缓冲一致。读不到（首次启动/无文件）就什么也不做。
    ///
    /// 回灌前统一过一遍 `normalizedForRestore()`:仍停在 `opened` 阶段的记录不可能真的还活着
    /// (上一次 app/扩展进程已经没了,不会再收到 close 事件)，原样回灌会让"活动"页永远显示一批
    /// 绿色圆点、误导用户以为它们还在跑。
    @MainActor
    private func restoreRecentConnectionLog() async {
        let recent = await connectionLogFileStore.loadRecent(limit: 200)
        for entry in recent {
            store.dispatch(.connectionEventReceived(entry.normalizedForRestore()))
        }
    }

    /// 决定哪些 action 改动了 `PersistedConfiguration` 覆盖的字段(进程规则/细粒度规则表/目录/
    /// 代理服务器/路由模式/引导完成态)——这些改动只挂在 `scenePhase` 切后台才存盘的话,应用在
    /// 切后台之前被重装/崩溃/强制重启,改动就静默丢了(这正是 WeChat 规则被重启打回"直连"、
    /// 手动加的 a.out 精确规则重启就消失的根因)。其余 action(流量统计、诊断结果、连接日志等)
    /// 都是运行时状态,`PersistedConfiguration` 里本来就没有对应字段，不用触发存盘。
    private static func isPersistenceRelevant(_ action: Core.Action) -> Bool {
        switch action {
        case .assignRule, .addMatchRule, .removeMatchRule, .reorderMatchRules, .setMatchRuleEnabled,
             .directoryScanned, .addProxyServer, .updateProxyServer, .removeProxyServer,
             .setActiveProxyServer, .setProxyRoutingMode, .onboardingCompleted:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func persistCurrentConfiguration() {
        let configuration = PersistedConfiguration(from: store.state)
        let servers = Array(store.state.proxyServers.values)
        let credentialStore = credentialStore
        Task {
            await FilePersistenceStore().save(configuration)            // 无密码落盘
            await PersistedConfiguration.saveCredentials(from: servers, to: credentialStore) // 密码进 Keychain
        }
    }

    /// `Store` 的 effectHandler 本体——从 `init` 里的闭包拆出来只是压 `function_body_length`
    /// (init 本身塞了 store/ipcReceiver/profilesModel 三个 `_xxx = State(...)` 赋值,
    /// 闭包体一长就超预算),逻辑跟原来内联时完全一样,分支对 `Core.Effect` 一一映射。
    private static func handleEffect(
        _ effect: Core.Effect, transport: XPCAppSideTransport, connectionLogFileStore: ConnectionLogFileStore,
        processIdentityResolver: any LocalProcessIdentityResolving
    ) async -> Core.Action? {
        switch effect {
        case .log:
            return nil
        case .scanDirectory:
            let entries = await FileSystemDirectoryScanner().scan()
            return .directoryScanned(entries)
        case .runDiagnostic(let processID, let kinds):
            let message = ExtensionMessageHandling.diagnosticRequestMessage(processID: processID, kinds: kinds)
            await transport.send(message)
            return nil // 结果异步经 IPCReceiver -> diagnosticResultReceived 回灌
        case .applyProxyConfig(let servers, let activeID):
            let message = ProxyConfigMapping.proxyConfigMessage(servers: servers, activeID: activeID)
            await transport.send(message)
            return await Self.resolveProcessOriginExclusions(
                servers: servers, activeID: activeID, using: processIdentityResolver
            )
        case .applyRuleSet(let assignments, let matchRules):
            let message = RuleSetMapping.ruleSetMessage(assignments: assignments, matchRules: matchRules)
            await transport.send(message)
            return nil // 纯下发，扩展据此更新每进程规则 + 细粒度规则表
        case .applyRoutingMode(let mode):
            await transport.send(ProxyConfigMapping.routingModeMessage(mode))
            return nil // 纯下发，扩展据此在单台/链/故障转移/负载均衡之间切换
        case .applyPacketCapture(let enabled):
            await transport.send(ProxyConfigMapping.packetCaptureMessage(enabled))
            return nil // 纯下发，扩展据此开/关逐连接 .dmp 抓包
        case .applyUDPPolicy(let policy):
            await transport.send(ProxyConfigMapping.udpPolicyMessage(policy))
            return nil // 纯下发，扩展据此在拦截/直连/SOCKS5 代理之间切换 UDP 处理
        case .applyProcessOriginExclusions(let direct, let hardBypass):
            await transport.send(ProxyConfigMapping.processOriginExclusionsMessage(direct: direct, hardBypass: hardBypass))
            return nil // 纯下发，扩展据此更新两档来源排除(直连档 / 完全旁路档)
        case .clearConnectionLogFile:
            await connectionLogFileStore.clear()
            return nil // 内存里的 connectionLog 已经在 reducer 里清空了,这里只清磁盘那份
        }
    }

    /// applyProxyConfig 下发之后顺带查一次:active 上游若指向本机(如用户配的是本地
    /// xray/yunti),查出它的签名标识 + 可执行文件路径、包成 `.proxyProcessIdentitiesResolved`
    /// 供 store 回灌——转发环硬化的「来源进程自动排除」（见 LocalProxyOriginDiscovery）。拆成
    /// 静态方法只是为了不撑爆 init 里 effectHandler 闭包的长度，逻辑本身不复杂。
    private static func resolveProcessOriginExclusions(
        servers: [Core.ProxyServer], activeID: Core.ProxyServerID?, using resolver: any LocalProcessIdentityResolving
    ) async -> Core.Action {
        let discoveryState = Core.AppState(
            proxyServers: Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) }),
            activeProxyServerID: activeID
        )
        let discovery = await LocalProxyOriginDiscovery.discover(state: discoveryState, using: resolver)
        return .proxyProcessIdentitiesResolved(discovery)
    }
}

/// 防抖动的存盘触发器：连续多次"值得持久化"的 action(比如拖拽重排规则表连续触发
/// `reorderMatchRules`)只在停顿下来之后落盘一次，避免每条 dispatch 都读写一次磁盘。
/// 类而非 struct——`AppidgeApp.store.onAction` 闭包要按引用捕获同一份"待落盘 Task"状态。
@MainActor
final class PersistenceDebouncer {
    private var pendingTask: Task<Void, Never>?

    func schedule(delay: Duration = .milliseconds(400), _ action: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
