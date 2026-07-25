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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 试用细横幅点按时打开「管理许可证」窗口。
    @Environment(\.openWindow) private var openWindow

    @State private var filter = ""
    @State private var selection: Set<ConnectionLogEntry.ID> = []
    /// 详情抽屉默认收起——它是覆盖式的,盖住表右侧;需要时用工具栏「详情」或选中连接后打开。
    @State private var showInspector = false
    @State private var showingClearConfirmation = false
    @State private var showingProfiles = false
    /// 连接表只看活动连接(对齐 Proxifier:上表活跃、历史沉底)。默认关(全部可见)。
    @State private var showActiveOnly = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                detail
                    // 工具栏结构跨分段**恒定**(见 mainToolbar),不随切换增删,消除切 tab 的 reconcile 抖动。
                    // 「搜索 / 仅活动」是活动专属,已移进活动表自己的头部过滤条(见 activityFilterBar)——只在
                    // 活动出现、其它 tab 干净,也不再把 .searchable 挂在稳定层污染所有 tab 的工具栏。
                    .toolbar { mainToolbar }
                    .confirmationDialog(
                        "清除全部连接记录？", isPresented: $showingClearConfirmation, titleVisibility: .visible
                    ) {
                        Button("清除", role: .destructive) { store.dispatch(.clearConnectionLog) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("只清空「活动」页显示的连接记录，不影响已生效的规则或累计流量统计。")
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // 只留真正需要打断用户的告警（环 / 待批准）。试用倒计时是常驻信息，
                    // 已收进底部状态栏（TrialStatusItem），不再占顶部一整条。
                    if let warning = store.state.loopWarning {
                        LoopWarningBanner(signature: warning) { store.dispatch(.dismissLoopWarning) }
                    } else if let prompt = approvalPrompt {
                        ExtensionApprovalBanner(text: prompt)
                    }
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
        case .activity: activity.navigationTitle("活动")
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

    /// 「活动」:连接表(主)占满,底部日志抽屉,右侧详情覆盖抽屉。
    /// - 详情用**覆盖式抽屉**(盖在表上、不改表宽),取代旧 `.inspector` 列——那个开合会把表挤窄、
    ///   触发整表列重排,正是抖动源。
    /// - 日志是**底部抽屉**,高度由它自己(展开态 + 拖拽)决定,折叠只剩薄头,不再有 VSplitView
    ///   固定分区留下的孤立空白。
    private var activity: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                activityFilterBar
                Divider()
                ConnectionsTable(store: store, filter: filter, showActiveOnly: showActiveOnly, selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                TrafficPane(store: store)
            }

            if showInspector {
                detailDrawer
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                // Esc 关闭抽屉(清空选中即收起)——已去掉顶部「详情」按钮,这是与「点空白行区域」并列的
                // 一条可靠关闭出口;隐藏按钮只借它的 .cancelAction 键位,不占工具栏。
                Button("关闭详情") { selection.removeAll() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.26), value: showInspector)
        // 单击某行即弹出详情抽屉、切换行即换内容;点空白行区域(取消选中)或按 Esc 收起。用选中态驱动、
        // 无双击消抖延迟,不再需要顶部按钮。
        .onChange(of: selection) { _, newSelection in
            showInspector = newSelection.count == 1
        }
    }

    /// 右侧详情抽屉:固定宽度、覆盖在连接表之上,带左侧分隔线与投影,读作「浮在内容上的抽屉」。
    private var detailDrawer: some View {
        HStack(spacing: 0) {
            Divider()
            ConnectionDetail(store: store, entry: selectedConnection)
                .frame(width: 320)
                .background(.windowBackground)
                // 右上角关闭图标:与「点空白行 / Esc」并列的显式关闭出口(清空选中即收起抽屉)。
                .overlay(alignment: .topTrailing) {
                    Button { selection.removeAll() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("关闭详情")
                }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.12), radius: 8, x: -2, y: 0)
    }

    /// 活动表专属的头部过滤条:搜索(按进程/主机过滤)+ 仅活动开关。只在活动分段出现——搜索本来
    /// 就只有活动需要,放进表头既避免把 `.searchable` 挂在稳定层污染所有 tab,也把过滤能力和它作用的
    /// 表格摆到一起。
    private var activityFilterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("过滤连接（进程 / 主机）", text: $filter)
                .textFieldStyle(.plain)
                .font(.caption)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清空过滤")
            }
            Spacer(minLength: 12)
            Toggle(isOn: $showActiveOnly) {
                Label("仅活动", systemImage: "circle.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .font(.caption)
            .help("只显示仍在活动的连接(隐藏已关闭 / 失败的历史记录)")
            // 「清除记录」从顶部工具栏挪到这里,与搜索/仅活动等活动专属控件放一处。
            Button(role: .destructive) { showingClearConfirmation = true } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(store.state.connectionLog.isEmpty)
            .help("清空当前显示的连接记录（不影响已生效的规则/流量统计）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// 顶部区域切换:自定义 plain 按钮组,无系统 hover 高亮。选中态用次强调底色胶囊标示。
    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let selected = tabSelection.section == tab
                Button {
                    tabSelection.section = tab
                } label: {
                    Text(tab.title)
                        .font(.callout)
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 主窗口工具栏:分段切换(自定义无 hover)+ 「档案」+「设置」,跨分段**恒定**(无条件增删)=
    /// 切换时无 reconcile 抖动。活动专属的搜索 / 仅活动 / 清除记录都已移进活动表头过滤条(见 activityFilterBar)。
    @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
        // 顶层区域切换分段。用自定义 plain 按钮组而非原生 `.segmented` Picker——后者有系统 hover
        // 高亮去不掉;plain button 无 hover 背景,选中态用胶囊底色标示,视觉一致但不闪。
        ToolbarItem(placement: .principal) {
            tabPicker
        }
        // 「档案」:弹 sheet,4 个分段不含它但功能保留,任何分段都可见。
        ToolbarItem(placement: .automatic) {
            Button { showingProfiles = true } label: {
                Label("配置档案", systemImage: "square.stack.3d.up")
            }
            .help("把当前代理 / 规则 / 目录配置存成命名档案,随时载入切换")
        }
        // 「设置」:紧挨档案,打开设置窗口(⌘, 场景),与菜单栏的 SettingsLink 同一入口。
        ToolbarItem(placement: .automatic) {
            SettingsLink { Label("设置", systemImage: "gearshape") }
                .help("打开设置")
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
                    // 实际走的上游(本地化前缀 + host:port);直连时不显示。用于验证路由模式。
                    if let up = UpstreamLabelFormat.display(label: e.upstreamLabel, kind: e.upstreamKind) {
                        LabeledContent("上游") {
                            Text(up).monospaced().textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
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
