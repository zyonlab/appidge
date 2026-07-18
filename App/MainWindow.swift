import SwiftUI
import Core
import AppFeature

/// 主窗口 —— 菜单栏优先的小工具主界面。顶层区域用**工具栏分段 tab**切换(活动 · 应用 · 规则 · 代理),
/// 取代旧的侧栏(对齐 HIG「小工具用 segmented control 切视图,不用侧栏」)。「活动」里是连接监视表 +
/// 底部流量,选中某条连接时右侧 Inspector 显示详情、并可就地建规则。「档案」降级为工具栏按钮弹 sheet。
/// 窗底 `.safeAreaInset` 常驻状态栏,顶栏出现回环告警;全局设置进 `Settings` 场景(⌘,)。
struct MainWindow: View {
    var store: Store
    var profiles: ProfilesModel
    /// 选中的顶层分段提升为跨窗口共享状态(见 MainTabSelection):菜单栏「打开入口」也改它,
    /// 所以主窗口在(可能已开着的)时也会跟着切 tab。`@Bindable` 让 Picker 能双向绑定其属性。
    @Bindable var tabSelection: MainTabSelection

    @State private var filter = ""
    @State private var selection: Set<ConnectionLogEntry.ID> = []
    @State private var showInspector = true
    @State private var showingClearConfirmation = false
    @State private var showingProfiles = false
    /// 连接表只看活动连接(对齐 Proxifier:上表活跃、历史沉底)。默认关(全部可见)。
    @State private var showActiveOnly = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                detail
                    .toolbar {
                        // 顶层区域切换从侧栏改为工具栏分段(对齐 HIG「小工具用 segmented control 切视图」)。
                        ToolbarItem(placement: .principal) {
                            Picker("区域", selection: $tabSelection.section) {
                                ForEach(MainTab.allCases) { tab in
                                    Text(tab.title).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        // 「档案」从侧栏顶层降级为工具栏按钮弹出的 sheet:4 个分段不含它,但功能保留。
                        ToolbarItem(placement: .automatic) {
                            Button { showingProfiles = true } label: {
                                Label("配置档案", systemImage: "square.stack.3d.up")
                            }
                            .help("把当前代理 / 规则 / 目录配置存成命名档案,随时载入切换")
                        }
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let warning = store.state.loopWarning {
                    LoopWarningBanner(signature: warning) { store.dispatch(.dismissLoopWarning) }
                } else if let prompt = approvalPrompt {
                    ExtensionApprovalBanner(text: prompt)
                }
            }
            // 状态栏作为 VStack 同级子视图(而非 detail 的 .safeAreaInset)。用 bottom safeAreaInset 时,
            // detail 内容会伸进被 inset 的区域,把面板底部工具栏(如「规则」的 ＋)盖在状态栏底下。
            // 作为同级子视图它真正占位,detail 内容排在其上方,工具栏恒可见。
            StatusBar(store: store)
        }
        .frame(minWidth: 900, minHeight: 520)
        .sheet(isPresented: $showingProfiles) { profilesSheet }
    }

    /// 分段选中区域 → 对应内容。各自挂一个窗口标题。
    @ViewBuilder private var detail: some View {
        switch tabSelection.section {
        case .activity: activity
        case .apps: AppsPaneView(store: store).navigationTitle("应用")
        case .rules: RulesEditorPaneView(store: store).navigationTitle("规则")
        case .proxies: ProxyServersPaneView(store: store).navigationTitle("代理服务器")
        }
    }

    /// 「档案」sheet:标题栏 + 完成按钮 + ProfilesPaneView。
    private var profilesSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配置档案").font(.headline)
                Spacer()
                Button("完成") { showingProfiles = false }
            }
            .padding()
            Divider()
            ProfilesPaneView(model: profiles)
        }
        .frame(width: 460, height: 420)
    }

    /// 「活动」:连接表(主) + 底部流量(次),右侧 Inspector 看选中连接详情。搜索、Inspector 开关挂在这一层的工具栏,
    /// 所以只在「活动」出现;全局代理开关挂在外层,任何区域都可见。
    private var activity: some View {
        VSplitView {
            ConnectionsTable(store: store, filter: filter, showActiveOnly: showActiveOnly, selection: $selection)
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
                Toggle(isOn: $showActiveOnly) {
                    Label("仅活动", systemImage: "circle.fill")
                }
                .help("只显示仍在活动的连接(隐藏已关闭 / 失败的历史记录)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { showingClearConfirmation = true } label: {
                    Label("清除记录", systemImage: "trash")
                }
                .disabled(store.state.connectionLog.isEmpty)
                .help("清空当前显示的连接记录（不影响已生效的规则/流量统计）")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
                .help("显示 / 隐藏连接详情")
            }
        }
        .confirmationDialog(
            "清除全部连接记录？", isPresented: $showingClearConfirmation, titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { store.dispatch(.clearConnectionLog) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空「活动」页显示的连接记录，不影响已生效的规则或累计流量统计。")
        }
    }

    /// 扩展没在跑且需要用户去系统设置操作时,顶部给一条带直达按钮的横幅(对齐 Proxifier 的
    /// 引导顺滑度:批准是 Apple 强制的一次性步骤,能做的是把人直接带到那个面板)。
    private var approvalPrompt: LocalizedStringKey? {
        switch store.state.extensionActivation {
        case .needsApproval:
            "系统扩展等待批准——在「登录项与扩展 → 网络扩展」里允许 appidge 后即开始接管。"
        case .disabled:
            "网络扩展已被停用——在「登录项与扩展 → 网络扩展」里重新打开后自动恢复接管。"
        case .active, .inactive, .activating, .failed:
            nil
        }
    }

    /// 恰好选中一条时给出该连接;多选或空选时为 nil(Inspector 显示空态)。
    private var selectedConnection: ConnectionLogEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.state.connectionLog.first { $0.id == id }
    }

    /// 主窗口顶层分段 tab(旧版是侧栏)。顺序:活动 · 应用 · 规则 · 代理。
    enum MainTab: String, Identifiable, CaseIterable {
        case activity, apps, rules, proxies
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .activity: "活动"
            case .apps: "应用"
            case .rules: "规则"
            case .proxies: "代理"
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
                    LabeledContent("状态") {
                        if e.rule == .observe {
                            // 同连接表:观测行不跟踪生命周期,显示「已放行」而非「已关闭」。
                            Label("已放行", systemImage: "eye").foregroundStyle(.orange)
                        } else {
                            statusLabel(e.phase)
                        }
                    }
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
                        Button("观测") { makeRule(e, .observe) }
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
        case .opened: Label("活跃", systemImage: "circle.fill").foregroundStyle(.green)
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
