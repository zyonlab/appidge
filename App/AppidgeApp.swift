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
                return nil // 纯下发，扩展据此更新 active 上游 + 上游排除集合
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
                }
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
}
