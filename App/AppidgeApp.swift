import SwiftUI
import Core
import IPCContract
import AppFeature

@main
struct AppidgeApp: App {
    @State private var store: Store
    @State private var ipcReceiver: IPCReceiver
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let transport = AppGroupAppSideTransport(appGroup: "group.com.appidge")
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
            }
        })
        _store = State(initialValue: store)
        _ipcReceiver = State(initialValue: IPCReceiver(store: store, transport: transport))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.state.hasCompletedOnboarding {
                    ContentView(store: store)
                } else {
                    OnboardingView(store: store)
                }
            }
            .task {
                await ipcReceiver.start()
                await restorePersistedConfiguration()
                store.dispatch(.appLaunched)
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
        for action in configuration.restorationActions() {
            store.dispatch(action)
        }
    }

    @MainActor
    private func persistCurrentConfiguration() {
        let configuration = PersistedConfiguration(from: store.state)
        Task {
            await FilePersistenceStore().save(configuration)
        }
    }
}
