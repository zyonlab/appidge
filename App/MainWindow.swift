import SwiftUI
import Core
import AppFeature

/// 主窗口 —— 对齐 Proxifier 的模型、也是苹果 Console.app / 活动监视器的模型:
/// 顶部工具栏(全局开关 + 打开配置 sheet + 过滤),中间 `VSplitView`(连接监视表 + 底部流量/统计),
/// 底部 `.safeAreaInset` 状态栏。配置(代理服务器 / 规则 / 档案)一律弹 sheet,全局设置进 `Settings` 场景(⌘,)。
struct MainWindow: View {
    var store: Store
    var profiles: ProfilesModel

    @State private var activeSheet: ConfigSheet?
    @State private var filter = ""
    @State private var selection: Set<ConnectionLogEntry.ID> = []

    var body: some View {
        VSplitView {
            ConnectionsTable(store: store, filter: filter, selection: $selection)
                .frame(minHeight: 220)
            TrafficPane(store: store)
                .frame(minHeight: 130, idealHeight: 170, maxHeight: 320)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(store: store)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let warning = store.state.loopWarning {
                LoopWarningBanner(signature: warning) { store.dispatch(.dismissLoopWarning) }
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "过滤连接（进程 / 主机）")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: Binding(
                    get: { store.state.isGlobalProxyEnabled },
                    set: { store.dispatch(.setGlobalProxyEnabled($0)) }
                )) {
                    Label("全局代理", systemImage: "network")
                }
                .toggleStyle(.switch)
                .help("总开关：关掉时全部直连")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { activeSheet = .proxyServers } label: {
                    Label("代理服务器", systemImage: "server.rack")
                }
                Button { activeSheet = .rules } label: {
                    Label("规则", systemImage: "list.bullet.rectangle")
                }
                Button { activeSheet = .profiles } label: {
                    Label("档案", systemImage: "square.stack.3d.up")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            ConfigSheetContainer(title: sheet.title) {
                switch sheet {
                case .proxyServers: ProxyServersPaneView(store: store)
                case .rules: RulesEditorPaneView(store: store)
                case .profiles: ProfilesPaneView(model: profiles)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// 主窗口工具栏上三个配置入口对应的 sheet。
enum ConfigSheet: String, Identifiable, CaseIterable {
    case proxyServers, rules, profiles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .proxyServers: "代理服务器"
        case .rules: "规则"
        case .profiles: "配置档案"
        }
    }
}

/// 统一的 sheet 外壳:标题栏 + 内容 + 右上「完成」。给复用进来的配置面板一个一致的 macOS sheet 外观。
private struct ConfigSheetContainer<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}
