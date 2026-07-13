import SwiftUI
import Core
import AppFeature

@main
struct AppidgeApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.state.hasCompletedOnboarding {
                    ContentView(store: store)
                        .onAppear { SystemExtensionActivator.shared.activate() }
                } else {
                    OnboardingView(store: store)
                }
            }
            .task {
                await restorePersistedConfiguration()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 简单的持久化触发点：场景失焦/进后台时落盘一次（覆盖“规则/目录被改过、
            // app 被关闭或切到后台”的常见路径）。onboarding 完成那一下已经在
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
