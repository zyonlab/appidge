import SwiftUI
import Core
import AppFeature

/// 主窗口 —— 苹果原生三栏结构(侧栏 · 内容 · Inspector),对齐 HIG 对 Mac 工具类应用的建议,
/// 也贴近 Little Snitch 的组织方式。侧栏切换顶层区域(活动 / 规则 / 代理 / 档案);「活动」里是
/// 连接监视表 + 底部流量,选中某条连接时右侧 Inspector 显示它的详情、并可就地据此建规则。
/// 窗底 `.safeAreaInset` 常驻状态栏,顶栏出现回环告警;全局设置进 `Settings` 场景(⌘,)。
///
/// 改自旧的 `VSplitView` + 三个配置 sheet:配置(代理 / 规则 / 档案)从「弹窗」升级为侧栏常驻目的地,
/// 符合 HIG「侧栏放顶层目的地、Inspector 看选中项详情」的分工。
struct MainWindow: View {
    var store: Store
    var profiles: ProfilesModel

    @State private var section: SidebarSection? = .activity
    @State private var filter = ""
    @State private var selection: Set<ConnectionLogEntry.ID> = []
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $section) {
                    ForEach(SidebarSection.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
                .navigationTitle("appidge")
            } detail: {
                detail
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let warning = store.state.loopWarning {
                    LoopWarningBanner(signature: warning) { store.dispatch(.dismissLoopWarning) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(
                        get: { store.state.isGlobalProxyEnabled },
                        set: { store.dispatch(.setGlobalProxyEnabled($0)) }
                    )) {
                        Label("全局代理", systemImage: "network")
                    }
                    .toggleStyle(.switch)
                    .help("总开关：关掉时全部直连")
                }
            }
            // 状态栏作为 VStack 同级子视图(而非 NavigationSplitView 的 .safeAreaInset)。用 bottom
            // safeAreaInset 时,detail 列内容会伸进被 inset 的区域,把面板底部工具栏(如「规则」的 ＋)
            // 盖在状态栏底下——高的 inset(如「代理」含路由模式)能露头、矮的(「规则」只一行工具栏)
            // 全被盖住。作为同级子视图它真正占位,detail 内容排在其上方,工具栏恒可见。
            StatusBar(store: store)
        }
        .frame(minWidth: 900, minHeight: 520)
    }

    /// 侧栏选中区域 → 对应内容。配置面板从旧的 sheet 平移到这里托管,各自挂一个窗口标题。
    @ViewBuilder private var detail: some View {
        switch section ?? .activity {
        case .activity: activity
        case .rules: RulesEditorPaneView(store: store).navigationTitle("规则")
        case .proxies: ProxyServersPaneView(store: store).navigationTitle("代理服务器")
        case .profiles: ProfilesPaneView(model: profiles).navigationTitle("配置档案")
        }
    }

    /// 「活动」:连接表(主) + 底部流量(次),右侧 Inspector 看选中连接详情。搜索、Inspector 开关挂在这一层的工具栏,
    /// 所以只在「活动」出现;全局代理开关挂在外层,任何区域都可见。
    private var activity: some View {
        VSplitView {
            ConnectionsTable(store: store, filter: filter, selection: $selection)
                .frame(minHeight: 220)
            TrafficPane(store: store)
                .frame(minHeight: 130, idealHeight: 170, maxHeight: 320)
        }
        .navigationTitle("活动")
        .searchable(text: $filter, placement: .toolbar, prompt: "过滤连接（进程 / 主机）")
        .inspector(isPresented: $showInspector) {
            ConnectionDetail(store: store, entry: selectedConnection)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
                .help("显示 / 隐藏连接详情")
            }
        }
    }

    /// 恰好选中一条时给出该连接;多选或空选时为 nil(Inspector 显示空态)。
    private var selectedConnection: ConnectionLogEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.state.connectionLog.first { $0.id == id }
    }

    /// 侧栏顶层目的地。旧版是工具栏三个按钮弹 sheet,现在是常驻的侧栏区域。
    enum SidebarSection: String, Identifiable, CaseIterable {
        case activity, rules, proxies, profiles
        var id: String { rawValue }
        var title: String {
            switch self {
            case .activity: "活动"
            case .rules: "规则"
            case .proxies: "代理"
            case .profiles: "档案"
            }
        }
        var symbol: String {
            switch self {
            case .activity: "point.3.filled.connected.trianglepath.dotted"
            case .rules: "list.bullet.rectangle"
            case .proxies: "server.rack"
            case .profiles: "square.stack.3d.up"
            }
        }
    }
}

/// 「活动」右侧 Inspector：选中连接的详情(进程 / 目标 / 路由 / 流量),并可就地据此建一条精确规则。
/// 路由呈现复用连接表的 ``RouteChip``,保持一致。签名 / 父进程链 / 字节时间线等取证信息属于后续(P2)。
private struct ConnectionDetail: View {
    var store: Store
    let entry: ConnectionLogEntry?

    var body: some View {
        if let e = entry {
            Form {
                Section("进程") {
                    LabeledContent("应用", value: appName(e))
                    LabeledContent("标识") {
                        Text(e.processID.value).monospaced().textSelection(.enabled).lineLimit(1)
                    }
                }
                Section("目标") {
                    LabeledContent("主机") {
                        Text(e.host).monospaced().textSelection(.enabled).lineLimit(1)
                    }
                    LabeledContent("端口", value: String(e.port))
                }
                Section("路由") {
                    LabeledContent("决策") { RouteChip(rule: e.rule, kind: e.proxyKind) }
                    LabeledContent("状态") { statusLabel(e.phase) }
                }
                Section("流量") {
                    LabeledContent("↑", value: TrafficFormat.bytes(e.bytesUp))
                    LabeledContent("↓", value: TrafficFormat.bytes(e.bytesDown))
                    LabeledContent("建立", value: e.openedAt.formatted(date: .abbreviated, time: .standard))
                }
                Section {
                    Menu {
                        Button("走代理") { makeRule(e, .proxied) }
                        Button("直连") { makeRule(e, .direct) }
                        Button("拦截", role: .destructive) { makeRule(e, .block) }
                    } label: {
                        Label("为这条连接建规则", systemImage: "plus.rectangle.on.folder")
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "未选择连接",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text("在连接表里选一行，这里显示它的进程、目标、路由与流量，并可就地建规则。")
            )
        }
    }

    /// 优先级同 `ConnectionsTable.appName`:目录扫描名 > 扩展解出的可读进程名 > 原始 processID。
    private func appName(_ entry: ConnectionLogEntry) -> String {
        store.state.catalog[entry.processID]?.displayName ?? entry.processDisplayName ?? entry.processID.value
    }

    @ViewBuilder private func statusLabel(_ phase: ConnectionPhase) -> some View {
        switch phase {
        case .opened: Label("活动", systemImage: "circle.fill").foregroundStyle(.green)
        case .closed: Label("已关闭", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Label("失败", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }

    private func makeRule(_ e: ConnectionLogEntry, _ action: ProxyRule) {
        store.dispatch(.addMatchRule(ProxyMatchRule(
            id: RuleID(UUID().uuidString),
            appPattern: e.processID.value,
            hostPattern: e.host,
            portRange: e.port...e.port,
            action: action
        )))
    }
}
