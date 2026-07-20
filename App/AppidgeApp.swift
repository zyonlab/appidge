import SwiftUI
import Core
import IPCContract
import AppFeature

/// 只为一件事存在:app 退出时同步停掉透明代理会话(SwiftUI 生命周期没有等价钩子)。
/// UI 不在,接管就不该在——否则 catch-all 拦截挂在系统上没人能管,扩展一异常全系统断网,
/// 用户只能重启电脑(见 TransparentProxyController.stopCachedSessionForTermination)。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 启动最早期(UI 尚未构建、本地化尚未读取):把界面语言对齐到用户所选,必要时重启一次生效。
    func applicationWillFinishLaunching(_ notification: Notification) {
        LanguageBootstrap.applyAtLaunch()
    }

    /// 单实例强制:代理工具**不能多开**——两个实例会抢同一个扩展的 XPC 连接与透明代理会话
    /// (重复 resync、并发 start/stop 会话、活动栏重复/错乱)。已有一个更早启动的实例在跑,就激活它、
    /// 自己退出。**例外**:语言切换重启出的新实例带 `APPIDGE_LANG_RELAUNCHED`,是有意的接班者
    /// (旧实例正随即退出),不能自杀。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["APPIDGE_LANG_RELAUNCHED"] == nil else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        // 只在存在「更早启动」的实例时退让 → 存活者确定是最早那个,避免两个几乎同时启动互相退出。
        let incumbent = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { other in
                guard other != current else { return false }
                guard let mine = current.launchDate, let theirs = other.launchDate else { return true }
                return theirs < mine
            }
        guard let incumbent else { return }
        incumbent.activate()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 先强制同步存盘(退出前把最新配置落地,防 400ms 防抖没触发就退出丢改动),再停会话。
        AppTermination.persist?()
        TransparentProxyController.stopCachedSessionForTermination()
    }
}

/// 退出时的同步存盘钩子。`applicationWillTerminate` 在 AppDelegate 里、拿不到 `store`;由 App 的
/// `.task` 在窗口出现时注入一个捕获了 store 的同步存盘闭包(规则/代理只能在主窗口里改,窗口没开过
/// 就没有需要抢救的改动,所以在 `.task` 注入已足够)。只在主线程读写,满足 Swift 6 严格并发。
@MainActor
enum AppTermination {
    static var persist: (() -> Void)?
}

/// 主窗口选中的顶层分段(活动/应用/规则/代理)提升为**跨窗口共享状态**:主窗口的分段 Picker 与
/// 菜单栏的「打开入口」都绑到同一份,菜单栏点某个入口就能把主窗口切到对应 tab。轻量 `@Observable`
/// `@MainActor`——只在主线程读写,满足 Swift 6 严格并发,不引入跨 actor 共享可变引用。
@MainActor
@Observable
final class MainTabSelection {
    var section: MainWindow.MainTab = .activity
}

@main
struct AppidgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: Store
    @State private var ipcReceiver: IPCReceiver
    @State private var profilesModel: ProfilesModel
    /// 主窗口分段选中态,菜单栏「打开入口」与主窗口 Picker 共享同一份(见 MainTabSelection)。
    @State private var tabSelection = MainTabSelection()
    /// 版本握手自愈的去重:已针对哪个运行版本重启过会话(避免重启后版本仍旧时反复重启)。
    /// nil = 还没自愈过;`extensionNeedsRebind` 为真时 runningExtensionVersion 必非 nil。
    @State private var healedForRunningVersion: String?
    // 界面语言不在这里做 locale 环境覆盖了——改由 `LanguageBootstrap` 在启动早期对齐 AppleLanguages
    // + 切换时重启生效(见 AppDelegate.applicationWillFinishLaunching / SettingsView 的语言 Picker)。
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
        WindowGroup(id: "main") {
            Group {
                if store.state.hasCompletedOnboarding {
                    MainWindow(store: store, profiles: profilesModel, tabSelection: tabSelection)
                } else {
                    OnboardingView(store: store)
                }
            }
            .task {
                // 退出强制存盘钩子:捕获 store,同步落地最新配置(见 AppTermination / applicationWillTerminate)。
                AppTermination.persist = { [store] in
                    FilePersistenceStore().saveSynchronously(PersistedConfiguration(from: store.state))
                }
                // 扩展激活状态经 activator 的 delegate 回调回灌 store（状态栏据此如实显示）。
                SystemExtensionActivator.shared.onStateChange = { activation in
                    store.dispatch(.extensionActivationChanged(activation))
                    // 扩展获批(.active)后,必须由 app 侧启动透明代理会话,系统才会把流量交给 provider。
                    if case .active = activation {
                        Task { await TransparentProxyController.start() }
                    }
                }
                SystemExtensionActivator.shared.diagnose() // 启动即打印 app 看到的扩展目录(排查 not-found)
                // 读包内嵌扩展的期望版本,供"会话是否绑在旧 provider 上"的版本握手比对(见下面
                // extensionVersionReported 的处理)。启用即触发一次自愈判定。
                if let bundled = Self.bundledExtensionVersion() {
                    store.dispatch(.bundledExtensionVersionSet(bundled))
                }
                await ipcReceiver.start()
                await restorePersistedConfiguration()
                await restoreRecentConnectionLog()
                await profilesModel.loadLibrary()
                // 进入即探测代理环境(系统代理 + 环境变量 + 额外 TUN),UI 据此解释能管哪一层。
                await detectProxyEnvironment()
                // 接线放在两次 restore 之后：restore 本身就是靠重放 processDiscovered/assignRule/
                // addMatchRule 等"值得存盘"的 action 来灌回状态的,提前接线只会导致启动时又把刚读出来
                // 的东西原样存回去一次——浪费一次磁盘 I/O,不是错误,但没必要。
                store.onAction = { action in
                    // 扩展 XPC 连上回报版本时,若与包内版本不一致 = 会话绑在旧 provider 上(反复热
                    // 升级的僵尸态)→ 自动重启会话重绑最新扩展,一次为限(见 maybeHealStaleBinding)。
                    if case .extensionVersionReported = action { maybeHealStaleBinding() }
                    guard Self.isPersistenceRelevant(action) else { return }
                    // 立即同步落盘(去掉 400ms 防抖):每次改动一发生就在磁盘上,crash / 强杀也不丢。
                    // 规则调序是离散按钮点击(非连续拖拽流),JSON 又小,每次同步原子写代价可忽略。
                    persistCurrentConfiguration()
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
            if newPhase == .active {
                // 回到前台重探一次代理环境:用户可能刚在系统设置里改了系统代理 / 开关了 yunti。
                Task { await detectProxyEnvironment() }
            } else {
                // 简单的持久化触发点：场景失焦/进后台时落盘一次（覆盖"规则/目录被改过、
                // app 被关闭或切到后台"的常见路径）。
                persistCurrentConfiguration()
            }
        }

        Settings {
            SettingsView(store: store)
        }

        // 菜单栏用 SF Symbol 鸟形字形:菜单栏图标必须是单色模板,完整彩色鸽子图标(app/程序坞用)
        // 当模板会被填成实心方块。彩色鸽子仍是 AppIcon;这里用干净的 bird.fill 剪影,随明暗自适应。
        MenuBarExtra("appidge", systemImage: "bird.fill") {
            MenuBarView(store: store, tabSelection: tabSelection)
        }
        // .window 而非默认 .menu：内容是「仪表盘」(状态行 + Top-5 列表 + 开关),
        // 需要完整 SwiftUI 排版(语义色 / caption / 对齐),菜单渲染器会把这些收着。
        .menuBarExtraStyle(.window)
    }

    /// 探测代理环境并回灌 store(reducer 有差分守卫,未变化不产生多余通知)。
    @MainActor
    private func detectProxyEnvironment() async {
        let environment = await SystemProxyEnvironmentProbe().probe()
        store.dispatch(.proxyEnvironmentDetected(environment))
    }

    /// 读 app 包内嵌扩展(`Contents/Library/SystemExtensions/*.systemextension`)的 `CFBundleVersion`
    /// ——期望运行的最新版本。读不到返回 nil(不做版本握手,退回旧行为)。
    private static func bundledExtensionVersion() -> String? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              let ext = items.first(where: { $0.pathExtension == "systemextension" }) else { return nil }
        let info = ext.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String)
    }

    /// 版本握手发现会话绑在旧扩展上(`extensionNeedsRebind`)→ 重启会话重绑最新 provider。
    /// **一次为限**:记住已针对哪个运行版本自愈过——若重启后扩展仍回报同一个旧版本(说明系统
    /// 那边还没真正换实例,可能要重启电脑),不再反复重启会话空耗,而是留给 UI 提示用户。
    @MainActor
    private func maybeHealStaleBinding() {
        guard store.state.extensionNeedsRebind, let running = store.state.runningExtensionVersion else { return }
        guard healedForRunningVersion != running else { return }
        healedForRunningVersion = running
        Task { await TransparentProxyController.restart() }
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
        // 配置 JSON **同步立即**落盘——改动一发生就在磁盘上,crash / 强杀不丢(退出钩子同一条路径)。
        FilePersistenceStore().saveSynchronously(PersistedConfiguration(from: store.state))
        // 密码进 Keychain:只有代理增改才变化,异步保存不拖住 JSON 的即时落地。
        let servers = Array(store.state.proxyServers.values)
        let credentialStore = credentialStore
        Task { await PersistedConfiguration.saveCredentials(from: servers, to: credentialStore) }
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
