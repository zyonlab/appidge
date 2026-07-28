import SwiftUI
import Core
import IPCContract
import AppFeature
import Sparkle

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
        // 第一步先停笔:静默 XPC 通道,濒死实例不再推送任何配置(防「前任迟到覆盖继任」的分叉)。
        AppTermination.quiesceTransport?()
        // 再强制同步存盘(退出前把最新配置落地,防 400ms 防抖没触发就退出丢改动),再按路径处置会话。
        AppTermination.persist?()
        switch RelaunchHandoff.terminationPolicy(isHandingOff: AppTermination.isHandingOffToSuccessor) {
        case .stopAllSessions:
            // 普通退出 / Sparkle 升级重启：UI 不在，接管就不该在。升级时扩展二进制会被整个替换，
            // 把老会话跨着 provider 替换带过去正是「绑死旧 provider」的黑洞成因——必须停。
            TransparentProxyController.stopCachedSessionForTermination()
        case .keepSessionForSuccessor:
            // 语言切换交接：扩展没变，接班实例已确认启动并持有同一份全局 NE 配置。
            // 这里若照停，停掉的正是接班者刚起的那个会话（切完语言活动列表就空了的成因）。
            // 万一交接窗口出意外，接班者启动后的会话监督会把会话拉回来（sessionSupervisionDecision）。
            break
        }
    }
}

/// 退出时的同步存盘钩子。`applicationWillTerminate` 在 AppDelegate 里、拿不到 `store`;由 App 的
/// `.task` 在窗口出现时注入一个捕获了 store 的同步存盘闭包(规则/代理只能在主窗口里改,窗口没开过
/// 就没有需要抢救的改动,所以在 `.task` 注入已足够)。只在主线程读写,满足 Swift 6 严格并发。
@MainActor
enum AppTermination {
    static var persist: (() -> Void)?
    /// 退出第一步:同步静默 XPC 通道(invalidate 连接、停掉重连),让濒死实例从此刻起不可能再向
    /// 扩展推送任何配置——双实例窗口(语言切换交接/快速重开)里「前任迟到的推送覆盖继任的全量
    /// 推送」正是配置分叉的成因之一。App init 时注入(捕获 transport)。
    static var quiesceTransport: (() -> Void)?
    /// 本次退出是不是「语言切换交接给接班实例」。只有 `LanguageBootstrap.relaunch()` 在**确认**
    /// 接班实例已启动后才置真；置真时退出不停接管会话（见 `applicationWillTerminate`）。
    /// 默认 false —— 任何其它退出路径（普通退出、Sparkle 升级重启）都照常停光会话。
    static var isHandingOffToSuccessor = false
}

/// 主窗口选中的顶层分段(活动/应用/规则/代理)提升为**跨窗口共享状态**:主窗口的分段 Picker 与
/// 菜单栏的「打开入口」都绑到同一份,菜单栏点某个入口就能把主窗口切到对应 tab。轻量 `@Observable`
/// `@MainActor`——只在主线程读写,满足 Swift 6 严格并发,不引入跨 actor 共享可变引用。
@MainActor
@Observable
final class MainTabSelection {
    var section: MainWindow.MainTab = .activity
}

/// 主窗口根内容三档切换：已激活（licensed/grace/试用中）→ 主界面或引导；未激活**且相位已
/// 落定** → 授权门；相位未落定（启动最初几百毫秒，Keychain 授权记录/试用锚点还在读）→ 占位页。
/// 落定前不渲染授权门——初始 `.unlicensed` 只是「还没读」，不是「真没授权」，直接渲染会让
/// 试用期用户每次启动都闪一下"输入许可证"锁屏。落定必然发生（`.trialResolved` 是本地读锚点、
/// 读失败也回灌空数组），不会卡在占位页（见 ``Core/AppState/isLicensePhaseResolved``）。
private struct RootContentView: View {
    var store: Store
    var profiles: ProfilesModel
    var tabSelection: MainTabSelection

    var body: some View {
        if store.state.isLicenseActive {
            if store.state.hasCompletedOnboarding {
                MainWindow(store: store, profiles: profiles, tabSelection: tabSelection)
            } else {
                OnboardingView(store: store)
            }
        } else if store.state.isLicensePhaseResolved {
            LicenseGateView(store: store)
        } else {
            LicensePhaseResolvingView()
        }
    }
}

@main
struct AppidgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: Store
    @State private var ipcReceiver: IPCReceiver
    @State private var profilesModel: ProfilesModel
    /// 主窗口分段选中态,菜单栏「打开入口」与主窗口 Picker 共享同一份(见 MainTabSelection)。
    @State private var tabSelection = MainTabSelection()
    /// 升级后陈旧绑定自愈的一次性记忆(强制重启/重绑各最多一次)。判定逻辑是 Core 里的纯函数
    /// ``Core/AppState/staleBindingHealDecision(memo:)``,本层只负责在若干时机重新评估并执行副作用。
    @State private var staleBindingHealMemo = StaleBindingHealMemo.initial
    /// 未购买（试用中/已到期）时的启动弹窗是否正在展示（Proxifier 式每次启动提示）。
    @State private var showTrialPrompt = false
    /// 本次启动是否已评估过启动弹窗（一次为限：相位一旦落到试用/到期就弹一次，不反复打扰）。
    @State private var trialPromptEvaluated = false
    // 界面语言不在这里做 locale 环境覆盖了——改由 `LanguageBootstrap` 在启动早期对齐 AppleLanguages
    // + 切换时重启生效(见 AppDelegate.applicationWillFinishLaunching / SettingsView 的语言 Picker)。
    @Environment(\.scenePhase) private var scenePhase

    // Sparkle 自动升级:startingUpdater=true 一构造即启动后台自动检查;菜单栏「检查更新…」用其
    // `updater` 手动触发。feed URL / EdDSA 公钥读自 App/Info.plist(SUFeedURL / SUPublicEDKey)。
    // Developer ID 非沙盒 app 用标准配置即可,无需 XPC 服务分离。
    // updaterDelegate 负责在安装/重启前停掉接管会话，释放旧扩展占用，让系统扩展替换能当场完成
    // 而不是落进「重启电脑后生效」（见 UpdaterSessionRelease）。
    private static let updaterSessionRelease = UpdaterSessionRelease()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: AppidgeApp.updaterSessionRelease, userDriverDelegate: nil
    )
    // 代理密码存 Keychain，不落 JSON（见 PersistedProxyServer 结构上无 password 字段）。
    private let credentialStore: any CredentialStore = KeychainCredentialStore()
    // 连接日志落盘：每条连接事件顺带写 rolling JSONL，启动时 loadRecent 回灌（重启不丢历史）。
    private let connectionLogFileStore: ConnectionLogFileStore

    init() {
        // XPC 连接候选:内嵌扩展 plist 里的版本化 mach service 名优先(升级黑洞名字占用的
        // 根治——新旧扩展各用各的名字),legacy 名兜底(升级窗口里系统可能还在跑旧扩展)。
        let transport = XPCAppSideTransport(
            serviceNameCandidates: XPCTransportConfig.connectionCandidates(
                preferred: Self.bundledExtensionMachServiceName()
            )
        )
        // 退出第一步的「停笔」钩子(见 applicationWillTerminate):同步静默 XPC,濒死实例不再
        // 向扩展推送任何配置——双实例窗口(语言交接/快速重开)「前任迟到覆盖继任」的分叉防线。
        AppTermination.quiesceTransport = { transport.quiesceForTermination() }
        let connectionLogFileStore = ConnectionLogFileStore()
        self.connectionLogFileStore = connectionLogFileStore
        // 本地代理进程(如 xray/yunti)签名标识查询：libproc 查监听端口 + SecCode 取签名标识，
        // 用于转发环硬化的「来源进程自动排除」第二正交维度（见 LocalProxyOriginDiscovery）。
        let processIdentityResolver: any LocalProcessIdentityResolving = LibprocSecCodeProcessIdentityResolver()
        // 授权 effect 处理器：注入真实 API 客户端 / Keychain / 时钟（协议边界，测试用 mock）。
        // 与转发/路由完全独立——授权 effect 只经这里，绝不触碰网络接管路径。openCheckout 打开
        // 稳定购买入口（Release 默认官网定价页，由官网再跳真实支付商结账页）。
        let licenseHandler = LicenseEffectHandler.makeProduction(openCheckout: { url in
            guard let checkoutURL = URL(string: url) else { return }
            Task { @MainActor in NSWorkspace.shared.open(checkoutURL) }
        })
        // 试用时长由构建期注入（Info.plist `TrialDurationDays`，staging 可调小便于调试；缺失回落 7）。
        let store = Store(
            initialState: Core.AppState(
                trialConfig: TrialConfig(durationDays: AppLinks.trialDurationDays)
            ),
            effectHandler: { effect in
                await Self.handleEffect(
                    effect, transport: transport, connectionLogFileStore: connectionLogFileStore,
                    processIdentityResolver: processIdentityResolver, licenseHandler: licenseHandler
                )
            }
        )
        // XPC(重)连上扩展时全量重推当前配置。扩展升级/重启/掉线重连后是空规则起步的,不补推
        // 就一直空转(每条 flow 回落默认直连、什么都不接管)。[weak store] 断开 store→transport→
        // store 的保留环;dispatch 必须回到主 actor。
        transport.setOnConnect { [weak store] in
            Task { @MainActor in
                // 留痕 resync 触发源(考古用):onConnect 的 resync 在恢复门开前是纯 no-op。
                NSLog("appidge: XPC connected — dispatching resyncExtension (gated on replay-complete)")
                store?.dispatch(.resyncExtension)
            }
        }
        // XPC 通道可达性翻转沿回灌 store(连续掉线过阈值 → 不可达;收到扩展消息 → 恢复)。
        // 不可达 = 扩展监听器很可能注册失败(升级换血竞态,bootstrap "No such process")——
        // UI 据此显式警告(活动页/设置),自愈在 onAction 里有界重启接管一次(见 maybeHealStaleBinding)。
        transport.setOnReachabilityChange { [weak store] reachable in
            Task { @MainActor in store?.dispatch(.xpcChannelReachabilityChanged(reachable)) }
        }
        _store = State(initialValue: store)
        _ipcReceiver = State(initialValue: IPCReceiver(
            store: store, transport: transport, connectionLogFileStore: connectionLogFileStore,
            // 期望指纹必须与 effectHandler 下发排除名单时的 hostAppBundlePath **同一表达式**
            // (见 signalMessage 的 applyProcessOriginExclusions 分支),否则对账恒失配。
            hostAppBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        ))
        _profilesModel = State(initialValue: ProfilesModel(
            store: store, profileStore: ProfileStore(), credentialStore: KeychainCredentialStore()
        ))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootContentView(store: store, profiles: profilesModel, tabSelection: tabSelection)
            .task {
                // 退出强制存盘钩子:捕获 store,同步落地最新配置(见 AppTermination / applicationWillTerminate)。
                AppTermination.persist = { [store] in
                    FilePersistenceStore().saveSynchronously(PersistedConfiguration(from: store.state))
                }
                // 扩展激活状态经 activator 的 delegate 回调回灌 store（状态栏据此如实显示）。
                SystemExtensionActivator.shared.onStateChange = { activation in
                    store.dispatch(.extensionActivationChanged(activation))
                    // 扩展获批(.active)后,必须由 app 侧启动透明代理会话,系统才会把流量交给 provider。
                    // 起会话绑到当前 active 的 provider;升级窗口里若绑到旧的,靠版本握手在新 provider
                    // 确认接管后重绑一次(见 maybeHealStaleBinding)。
                    if case .active = activation,
                       store.state.isLicenseActive,
                       store.state.hasCompletedOnboarding {
                        TransparentProxyController.start()
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
                    // XPC 通道被判不可达(扩展监听器注册失败的竞态)时同样补一次自愈评估——
                    // 注册失败时版本握手根本到不了,只有这个信号能触发恢复(有界重启接管一次)。
                    if case .xpcChannelReachabilityChanged(false) = action { maybeHealStaleBinding() }
                    // 授权记录从 Keychain 恢复落地后：若已到每日校验间隔，联网做一次新鲜度校验
                    // （离线只会进宽限，不锁）。授权与持久化无关，故放在下面的 guard 之前。
                    if case .licenseRestored = action {
                        let now = Date()
                        if store.state.isValidateDue(now: now) {
                            store.dispatch(.licenseValidateRequested(now: now))
                        }
                    }
                    if Self.shouldSynchronizeLicenseCapability(
                        for: action, isActive: store.state.isLicenseActive
                    ) {
                        synchronizeLicenseCapability()
                    }
                    guard Self.isPersistenceRelevant(action) else { return }
                    // 立即同步落盘(去掉 400ms 防抖):每次改动一发生就在磁盘上,crash / 强杀也不丢。
                    // 规则调序是离散按钮点击(非连续拖拽流),JSON 又小,每次同步原子写代价可忽略。
                    persistCurrentConfiguration()
                }
                // 补一次自愈评估：扩展的版本回报（XPC 一连上就发）很可能早于上面 onAction 的接线，
                // 那次回报不会触发任何观察者，而 action 去重又让它不会再报一次——只有在这里读
                // 当前 state 主动评估，「升级后那一次启动」才不会被永久错过。判定幂等。
                maybeHealStaleBinding()
                store.dispatch(.appLaunched)
                // 启动恢复完成:先开「恢复门」再全量重推。onConnect 的 resync 可能发生在恢复
                // 之前——门关着时它是纯 no-op(不再把空 state 当期望态推给扩展,分叉毒药已拔);
                // 这里开门后的这次 resync 才是第一笔全量,内容必然是恢复后的完整配置。
                store.dispatch(.configurationReplayCompleted)
                store.dispatch(.resyncExtension)
                // 授权：从 Keychain 恢复上次的授权记录（onAction 里据此决定是否需要联网校验）。
                // 授权服务不可用绝不影响上面的网络接管——两条路径完全独立。
                store.dispatch(.licenseLoadRequested)
                // 试用：读本地双锚点（Keychain + Application Support 文件）。reducer 仅在 license==nil
                // 且相位 .unlicensed 时才据此进入 .trial/.trialExpired，故排在授权恢复之后。
                store.dispatch(.trialLoadRequested)
                // 会话监督：确认接管会话真的连上了，没有就拉起来。**不假设交接一定成功**——
                // 语言切换时前任可能刚好把接班者起的会话停掉（NE 配置按 app 全局一份），
                // 交接标记只是让这件事不再发生，这里才是兜底。判定是 Core 纯函数、可反复评估。
                superviseSession()
                // 周期性时钟推进：本地判定宽限耗尽/订阅到期（防时钟回拨），到期则每日联网校验一次。
                Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 小时
                        let now = Date()
                        store.dispatch(.licenseClockTick(now: now))
                        if store.state.isValidateDue(now: now) {
                            store.dispatch(.licenseValidateRequested(now: now))
                        }
                    }
                }
                // **先查真实状态,再决定要不要激活/起会话**(propertiesRequest 只查询、零 UI):
                // 扩展被用户在系统设置里**停用**时,activate() 只会打扰、startVPNTunnel 必然失败,
                // XPC 也无人监听——这种状态下什么都不做,状态栏如实显示「已停用」,把人指向系统
                // 设置(真机实锤:0.2.20 前 app 曾在此状态下因 XPC 重连风暴空转 100%+ CPU)。
                // **activate 与授权相位解耦**(2026-07-27 真机实锤的升级悬挂):替换请求只认
                // 「已引导 + 未停用」。试用相位要等 trialResolved **异步**落定才 isLicenseActive,
                // 此回调到达时相位常还是 unlicensed——旧写法把 activate 也门在授权上,试用用户
                // 升级后激活请求永远不提交,系统永不替换旧扩展,而新 app 只连**新版本号**的
                // mach 名 → 通道永久中断。activate 幂等且不看授权;会话 start 才看授权。
                SystemExtensionActivator.shared.checkStatus { state in
                    if case .disabled = state { return }
                    guard store.state.hasCompletedOnboarding else { return }
                    SystemExtensionActivator.shared.activate()
                    if store.state.isLicenseActive {
                        TransparentProxyController.start()
                    }
                }
                // 相位若在装配时已落到试用/到期（快速恢复），此处评估一次；否则靠下面的 onChange。
                maybePresentTrialPrompt(TrialState.from(store.state.licensePhase))
            }
            // 未购买（试用中/已到期）时的每次启动弹窗。相位由 Core 在授权恢复后异步落定，故用
            // onChange 捕获；已授权/吊销则收起。授权 UI 故障绝不阻塞主窗口——弹窗可继续或输入凭证。
            .sheet(isPresented: $showTrialPrompt) {
                TrialPromptView(
                    store: store,
                    trial: TrialState.from(store.state.licensePhase),
                    onContinue: { showTrialPrompt = false }
                )
            }
            .onChange(of: TrialState.from(store.state.licensePhase)) { _, newValue in
                maybePresentTrialPrompt(newValue)
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
        .commands {
            // App 菜单：关于 / 管理许可证（主动授权入口）+ 帮助菜单法务链接（见 AppMenuCommands）。
            AppMenuCommands(store: store)
        }

        // 「关于 Appidge」窗口：版本 + 构建号 + 检查更新 + 四条法务链接 + 购买。
        Window("关于 Appidge", id: AppWindowID.about) {
            AboutView(store: store, updater: updaterController.updater)
        }
        .windowResizability(.contentSize)

        // 「管理许可证」窗口：用户主动打开的授权入口（试用态展示 + 凭证激活 + 购买，复用设置面板逻辑）。
        Window("管理许可证", id: AppWindowID.manageLicense) {
            ManageLicenseView(store: store)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(store: store)
        }

        // 菜单栏用 SF Symbol 鸟形字形:菜单栏图标必须是单色模板,完整彩色鸽子图标(app/程序坞用)
        // 当模板会被填成实心方块。彩色鸽子仍是 AppIcon;这里用干净的 bird.fill 剪影,随明暗自适应。
        MenuBarExtra("appidge", systemImage: "bird.fill") {
            MenuBarView(store: store, tabSelection: tabSelection, updater: updaterController.updater)
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
        bundledExtensionInfoValue { $0["CFBundleVersion"] as? String }
    }

    /// 读内嵌扩展声明的版本化 `NEMachServiceName`(名字唯一真相源是扩展 Info.plist,
    /// 见 XPCTransportConfig 注释)。读不到返回 nil → 候选表退回 legacy 单候选。
    private static func bundledExtensionMachServiceName() -> String? {
        bundledExtensionInfoValue {
            ($0["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String
        }
    }

    private static func bundledExtensionInfoValue<T>(_ read: ([String: Any]) -> T?) -> T? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              let ext = items.first(where: { $0.pathExtension == "systemextension" }) else { return nil }
        let info = ext.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { return nil }
        return read(dict)
    }

    /// 启动后确认接管会话真的在跑；不在就拉起来。判定是 Core 纯函数
    /// ``Core/AppState/sessionSupervisionDecision(isSessionConnected:)``，本方法只查状态 + 执行副作用。
    ///
    /// 为什么需要：会话可能在 app 不知情的情况下被停掉——最典型是切换界面语言，老实例退出时
    /// 会停掉**全部**已知会话，而 NE 配置按 app 全局只有一份，于是接班者刚起的会话被前任停掉
    /// （症状：切完语言活动列表就空了）。交接标记让这条路径不再发生，但监督是不依赖交接成功的兜底。
    ///
    /// 会话状态要等 NE 真正连上才稳定，故给一个短暂的宽限窗口再判，避免刚起就误判成「没连上」。
    @MainActor
    private func superviseSession() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let connected = await TransparentProxyController.isRunning()
            guard store.state.sessionSupervisionDecision(isSessionConnected: connected) == .startSession
            else { return }
            TransparentProxyController.start()
        }
    }

    /// 版本握手自愈「升级后会话绑死旧 provider=黑洞」。判定全部在 Core 的纯函数里（可测），
    /// 本方法只执行副作用。
    ///
    /// **必须允许反复调用**：自愈原先只挂在 `.extensionVersionReported` 这一个 action 边沿上，
    /// 而扩展 XPC 一连上就发版本，往往早于下面 `store.onAction` 的接线（中间隔着 ipcReceiver.start
    /// 之后的数个 await）；加上该 action 本身有去重，扩展再报同一版本也不会重新触发——
    /// 于是「升级后那一次启动」这个唯一需要自愈的场景被永久错过，表现为打开应用没有活动连接。
    /// 现在改为读当前 state 做判定，幂等由 `staleBindingHealMemo` 保证，可在任意时机安全补评估。
    @MainActor
    private func maybeHealStaleBinding() {
        let decision = store.state.staleBindingHealDecision(memo: staleBindingHealMemo)
        staleBindingHealMemo.recordDecision(decision)
        switch decision {
        case .none:
            return
        case .rebindNow:
            TransparentProxyController.restart()
        case .restartForUnreachableChannel:
            // 扩展在跑但 XPC 通道不可达(监听器注册失败):重启接管一次。stop→start 的 sessionless
            // 窗口让扩展侧自检判死的坏进程退出、launchd 重生新进程重新注册 mach service(闭环见
            // Extension/ProxyExtensionProviderXPCHealth.swift)。一次为限,防重生后仍失败的无限环;
            // 之后由活动页/设置的显式警告引导用户手动「重启接管」。
            // 顺带重提交激活(幂等):「通道不可达」的另一个已实锤成因是**替换悬挂**——升级包的
            // 激活请求从未提交,旧扩展还在监听旧版本号的 mach 名。只重启会话修不了它,而版本
            // 握手自愈又依赖这条死了的通道上报版本(catch-22),这里是唯一能兜住的自动路径。
            SystemExtensionActivator.shared.activate()
            TransparentProxyController.restart()
        case .reactivateExtension:
            // 系统已明说新版本要重启电脑才生效：重启隧道是徒劳的（改不了系统注册哪个版本）。
            // 先停会话释放旧 provider 的占用，再重新提交 activation——给替换一次「不必重启电脑
            // 就完成」的机会；完成后会话由 onStateChange/会话监督重新起来。
            // 仍不行则维持旧版本接管（功能完整，停掉反而断网），由 UI 如实告知需要重启电脑。
            Task { @MainActor in
                TransparentProxyController.stop()
                try? await Task.sleep(for: .seconds(2))
                SystemExtensionActivator.shared.activate()
                try? await Task.sleep(for: .seconds(3))
                TransparentProxyController.start()
            }
        case .scheduleForcedRestart:
            // 延迟一小段再动手：给 NE 自己完成 provider 切换的机会，避免和系统的重绑打架。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                // 期间可能已自行恢复（版本追平）——那就不必强制重启，交给 .rebindNow 那条路径。
                guard store.state.extensionNeedsRebind,
                      store.state.isLicenseActive,
                      store.state.hasCompletedOnboarding else { return }
                TransparentProxyController.restart()
            }
        }
    }

    /// 未购买时的启动弹窗调度：相位落到试用/到期就弹一次（一次为限，Proxifier 式每次启动提示）；
    /// 落到「非试用」（已购买/吊销/未激活门）则收起弹窗。相位由 Core 在授权恢复后异步落定，
    /// 故此方法既在装配尾部评估一次、又挂在 `onChange` 上捕获后续落定。授权 UI 绝不阻塞主功能。
    @MainActor
    private func maybePresentTrialPrompt(_ state: TrialState) {
        guard !trialPromptEvaluated else {
            // 已评估过：若已离开试用（激活/吊销等），收起可能仍开着的弹窗。
            if state == .notInTrial { showTrialPrompt = false }
            return
        }
        switch state {
        case .trial, .expired:
            trialPromptEvaluated = true
            showTrialPrompt = true
        case .notInTrial:
            break // 尚未落定（或本就已购买）——等 onChange 再评估。
        }
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
    /// 代理服务器/路由模式/引导完成态/环自愈排除)——这些改动只挂在 `scenePhase` 切后台才存盘的话,应用在
    /// 切后台之前被重装/崩溃/强制重启,改动就静默丢了(这正是 WeChat 规则被重启打回"直连"、
    /// 手动加的 a.out 精确规则重启就消失的根因)。其余 action(流量统计、诊断结果、连接日志等)
    /// 都是运行时状态,`PersistedConfiguration` 里本来就没有对应字段，不用触发存盘。
    private static func isPersistenceRelevant(_ action: Core.Action) -> Bool {
        switch action {
        case .assignRule, .addMatchRule, .removeMatchRule, .reorderMatchRules, .setMatchRuleEnabled,
             .directoryScanned, .addProxyServer, .updateProxyServer, .removeProxyServer,
             .setActiveProxyServer, .setProxyRoutingMode, .onboardingCompleted,
             // 环自愈学到新排除也立即落盘:切语言是重启生效的,不落盘等于每次切语言都把
             // 学到的硬旁路清零、xray 类本地代理落回「走代理」真环重开。
             .loopWarningRaised:
            return true
        default:
            return false
        }
    }

    /// 授权相位变化后，把真实透明代理会话同步到 capability gate。有效/宽限授权且已走完引导
    /// 才允许安装并启动；未激活、吊销、过期或停用成功都立即停止会话，保留设置/诊断恢复出口。
    private static func shouldSynchronizeLicenseCapability(
        for action: Core.Action, isActive: Bool
    ) -> Bool {
        switch action {
        case .licenseActivateSucceeded, .licenseActivateFailed,
             .licenseValidateSucceeded, .licenseValidateFailed,
             .licenseDeactivateSucceeded, .licenseRestored,
             // 试用相位落定同样要同步能力:试用有效 → activate+start(升级替换请求也靠这条
             // 补偿路径兜底);试用过期 → stop。以前列表只有 license 类 action,试用用户升级
             // 后没有任何路径会再提交激活请求(悬挂根因之二)。
             .trialResolved:
            return true
        case .licenseClockTick:
            // 每小时 tick 只在它刚关闭 capability 时停会话；有效授权不重复 activate/start。
            return !isActive
        default:
            return false
        }
    }

    @MainActor
    private func synchronizeLicenseCapability() {
        guard store.state.isLicenseActive, store.state.hasCompletedOnboarding else {
            TransparentProxyController.stop()
            return
        }
        SystemExtensionActivator.shared.checkStatus { state in
            guard store.state.isLicenseActive, store.state.hasCompletedOnboarding else {
                TransparentProxyController.stop()
                return
            }
            if case .disabled = state { return }
            SystemExtensionActivator.shared.activate()
            TransparentProxyController.start()
            // 相位（授权/试用）是异步从 Keychain 恢复后才落定的，落定前 isLicenseActive 为假、
            // 自愈判定一律 .none。这里在能力开放后再评估一次，避免「相位晚落定」把升级自愈吃掉。
            maybeHealStaleBinding()
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

    /// `Store` 的 effectHandler 本体。授权 effect 委托给注入了协议的 ``LicenseEffectHandler``
    /// （网络/Keychain/打开链接，与转发路径完全独立）；四类「纯下发信号」合并成一个分支经
    /// `signalMessage` 映射后下发（压 cyclomatic_complexity）。逻辑与拆分前逐一映射一致。
    private static func handleEffect(
        _ effect: Core.Effect, transport: XPCAppSideTransport, connectionLogFileStore: ConnectionLogFileStore,
        processIdentityResolver: any LocalProcessIdentityResolving, licenseHandler: LicenseEffectHandler
    ) async -> Core.Action? {
        switch effect {
        case .activateLicense, .validateLicense, .deactivateLicense,
             .persistLicense, .clearPersistedLicense, .loadPersistedLicense, .openCheckout,
             .loadTrialAnchors, .persistTrialAnchors:
            // 授权与试用锚点 effect 一并委托给注入了协议的 handler（网络/Keychain/文件锚点，
            // 与转发路径完全独立）。
            return await licenseHandler.handle(effect)
        case .log:
            return nil
        case .scanDirectory:
            let entries = await FileSystemDirectoryScanner().scan()
            return .directoryScanned(entries)
        case .runDiagnostic(let processID, let kinds):
            await transport.send(ExtensionMessageHandling.diagnosticRequestMessage(processID: processID, kinds: kinds))
            return nil // 结果异步经 IPCReceiver -> diagnosticResultReceived 回灌
        case .applyProxyConfig(let servers, let activeID):
            await transport.send(ProxyConfigMapping.proxyConfigMessage(servers: servers, activeID: activeID))
            return await Self.resolveProcessOriginExclusions(
                servers: servers, activeID: activeID, using: processIdentityResolver
            )
        case .applyRuleSet(let assignments, let matchRules):
            await transport.send(RuleSetMapping.ruleSetMessage(assignments: assignments, matchRules: matchRules))
            return nil // 纯下发，扩展据此更新每进程规则 + 细粒度规则表
        case .applyRoutingMode, .applyPacketCapture, .applyUDPPolicy, .applyProcessOriginExclusions:
            if let message = Self.signalMessage(for: effect) { await transport.send(message) }
            return nil // 纯下发信号：路由模式 / 抓包 / UDP / 来源排除
        case .clearConnectionLogFile:
            await connectionLogFileStore.clear()
            return nil // 内存里的 connectionLog 已经在 reducer 里清空了,这里只清磁盘那份
        }
    }

    /// 把「纯下发信号」类 effect 映射成扩展消息（合并分支后复用，非本组 effect 返回 nil）。
    private static func signalMessage(for effect: Core.Effect) -> IPCContract.AppToExtensionMessage? {
        switch effect {
        case .applyRoutingMode(let mode):
            return ProxyConfigMapping.routingModeMessage(mode)
        case .applyPacketCapture(let enabled):
            return ProxyConfigMapping.packetCaptureMessage(enabled)
        case .applyUDPPolicy(let policy):
            return ProxyConfigMapping.udpPolicyMessage(policy)
        case .applyProcessOriginExclusions(let direct, let hardBypass):
            let hostBundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            return ProxyConfigMapping.processOriginExclusionsMessage(
                direct: direct,
                hardBypass: hardBypass,
                hostAppBundlePath: hostBundle
            )
        default:
            return nil
        }
    }

    /// applyProxyConfig 下发之后顺带查一次:active 上游若指向本机(如用户配的是本地 xray/yunti),
    /// 查出它的签名标识 + 可执行文件路径、包成 `.proxyProcessIdentitiesResolved` 供 store 回灌——
    /// 转发环硬化的「来源进程自动排除」（见 LocalProxyOriginDiscovery）。
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
