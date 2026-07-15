import SwiftUI
import Core
import IPCContract
import AppFeature

@main
struct AppidgeApp: App {
    @State private var store: Store
    @State private var ipcReceiver: IPCReceiver
    @State private var profilesModel: ProfilesModel
    @Environment(\.scenePhase) private var scenePhase

    // 代理密码存 Keychain，不落 JSON（见 PersistedProxyServer 结构上无 password 字段）。
    private let credentialStore: any CredentialStore = KeychainCredentialStore()
    // 连接日志落盘：每条连接事件顺带写 rolling JSONL，启动时 loadRecent 回灌（重启不丢历史）。
    private let connectionLogFileStore: ConnectionLogFileStore

    init() {
        let transport = AppGroupAppSideTransport(appGroup: "group.com.appidge")
        let connectionLogFileStore = ConnectionLogFileStore()
        self.connectionLogFileStore = connectionLogFileStore
        // 本地代理进程(如 xray/yunti)签名标识查询：libproc 查监听端口 + SecCode 取签名标识，
        // 用于转发环硬化的「来源进程自动排除」第二正交维度（见 LocalProxyOriginDiscovery）。
        let processIdentityResolver: any LocalProcessIdentityResolving = LibprocSecCodeProcessIdentityResolver()
        let store = Store(effectHandler: { effect in
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
            case .applyRuleSet(let globalProxyEnabled, let assignments, let matchRules):
                let message = RuleSetMapping.ruleSetMessage(
                    globalProxyEnabled: globalProxyEnabled, assignments: assignments, matchRules: matchRules
                )
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
            case .applyProcessOriginExclusions(let discovery):
                await transport.send(ProxyConfigMapping.processOriginExclusionsMessage(discovery))
                return nil // 纯下发，扩展据此把这些签名标识/可执行文件路径并进「来源进程自动排除」集合
            }
        })
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
                store.dispatch(.appLaunched)
                // 已完成引导 = 之前提交过激活。激活状态不持久化，重新提交一次（幂等）把状态
                // 栏校准到真实情况：已批准立刻回 .active，否则如实回 needsApproval/failed。
                if store.state.hasCompletedOnboarding {
                    SystemExtensionActivator.shared.activate()
                }
                // 扩展获批后,必须由 app 启动透明代理会话,流量才会进 provider。不依赖 activate() 的
                // .completed 回调(旧版本「待重启卸载」时它可能一直不回),启动时直接尝试一次:
                // 幂等——已在跑就跳过,扩展没批准则 startVPNTunnel 失败并记 stderr,不影响别的。
                await TransparentProxyController.start()
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
    @MainActor
    private func restoreRecentConnectionLog() async {
        let recent = await connectionLogFileStore.loadRecent(limit: 200)
        for entry in recent {
            store.dispatch(.connectionEventReceived(entry))
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
