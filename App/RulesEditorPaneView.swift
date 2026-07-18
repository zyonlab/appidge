import SwiftUI
import Core
import AppFeature

/// 「规则」配置(对标 Proxifier 的 Proxification Rules)。原生 `Table`(进程 × 主机 × 端口 → 动作),
/// 从上到下、首个命中生效;底部工具栏 ＋添加 / −删除 / ↑↓ 调序(顺序决定优先级)。UI 只读 state、
/// 只 dispatch。内置的 localhost 直连规则说明放在「设置」里,这里不再重复。
struct RulesEditorPaneView: View {
    var store: Store

    @State private var selection: ProxyMatchRule.ID?
    @State private var showingAdd = false
    /// 正在编辑的规则(双击 / 右键「编辑」/ 工具栏铅笔打开编辑 sheet);nil = 不在编辑。
    @State private var editingRule: ProxyMatchRule?

    private var rules: [ProxyMatchRule] { store.state.rules }

    /// 是否有系统自动维护的旁路(回环自愈 / 端口发现)——有才显示只读的「自动旁路」区。
    private var hasAutoBypass: Bool {
        let d = store.state.dynamicOriginExclusion, l = store.state.loopAutoExclusions
        return !d.identifiers.isEmpty || !d.executablePaths.isEmpty
            || !l.identifiers.isEmpty || !l.executablePaths.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if rules.isEmpty {
                    ContentUnavailableView(
                        "还没有规则",
                        systemImage: "list.bullet.rectangle",
                        description: Text("点「＋」加一条，比如「主机 *.google.com → 代理」。规则从上到下、首个命中生效。")
                    )
                } else {
                    rulesTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 你的规则之外,系统还会自动维护两类旁路(都是强制/完全直连,不占用户规则表):
            // 回环自愈发现的来源进程、端口发现识别的本地代理进程。这里只读列出,标清「来源」。
            if hasAutoBypass {
                Divider()
                AutoBypassSection(
                    direct: store.state.dynamicOriginExclusion,
                    loop: store.state.loopAutoExclusions
                )
            }
        }
        // 工具栏用 safeAreaInset 固定在面板底部,始终可见。之前它是 VStack 的末尾元素,空态的
        // ContentUnavailableView 会把它挤出可视区(叠加窗底状态栏的 safeAreaInset)——「＋」消失、
        // 没法加规则。改为底部 inset 后与状态栏各占一层、永远露出来。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                toolbar
            }
            .background(.bar)
        }
        .sheet(isPresented: $showingAdd) {
            MatchRuleSheet(store: store, editing: nil)
        }
        .sheet(item: $editingRule) { rule in
            MatchRuleSheet(store: store, editing: rule)
        }
    }

    private var rulesTable: some View {
        Table(rules, selection: $selection) {
            TableColumn("启用") { r in enableToggle(for: r) }.width(40)
            TableColumn("进程") { r in editableCell(r) { Text(r.appPattern).monospaced() } }
            TableColumn("主机") { r in editableCell(r) { Text(r.hostPattern).monospaced() } }
            TableColumn("端口") { r in editableCell(r) { Text(Self.portText(r.portRange)) } }.width(90)
            TableColumn("动作") { r in
                editableCell(r) {
                    Text(RuleActionStyle.label(r.action)).foregroundStyle(RuleActionStyle.color(r.action))
                }
            }.width(70)
        }
        .contextMenu(forSelectionType: ProxyMatchRule.ID.self) { ids in
            if let id = ids.first, let rule = rules.first(where: { $0.id == id }) {
                Button("编辑…") { editingRule = rule }
                enableDisableMenuItem(for: id)
                Divider()
                Button("上移") { move(id, by: -1) }
                Button("下移") { move(id, by: 1) }
                Divider()
                Button("删除", role: .destructive) { store.dispatch(.removeMatchRule(id)) }
            }
        }
    }

    /// 单元格内容 + 双击进入编辑 + 停用时半透明。双击手势不吞掉单击选中(simultaneousGesture)。
    private func editableCell<Content: View>(
        _ rule: ProxyMatchRule, @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .lineLimit(1)
            .opacity(rule.isEnabled ? 1 : 0.45)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { editingRule = rule })
    }

    /// 每行前置的启用勾选框:点掉即停用(规则保留、不删除),下发前会被过滤,不再参与匹配。
    private func enableToggle(for rule: ProxyMatchRule) -> some View {
        Toggle("", isOn: Binding(
            get: { rule.isEnabled },
            set: { store.dispatch(.setMatchRuleEnabled(id: rule.id, enabled: $0)) }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help(rule.isEnabled ? "已启用（点掉可停用，规则保留）" : "已停用（保留规则，不参与匹配）")
    }

    /// 右键菜单里的启用/停用项:按当前状态取反,和前置勾选框走同一条 action。
    @ViewBuilder
    private func enableDisableMenuItem(for id: ProxyMatchRule.ID) -> some View {
        if let rule = rules.first(where: { $0.id == id }) {
            Button(rule.isEnabled ? "停用" : "启用") {
                store.dispatch(.setMatchRuleEnabled(id: id, enabled: !rule.isEnabled))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { showingAdd = true } label: { Image(systemName: "plus") }
                .help("添加规则")
            Button { removeSelected() } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("删除选中")
            Button {
                if let id = selection, let rule = rules.first(where: { $0.id == id }) { editingRule = rule }
            } label: { Image(systemName: "pencil") }
                .disabled(selection == nil)
                .help("编辑选中（也可双击某行）")
            Divider().frame(height: 14)
            Button { if let id = selection { move(id, by: -1) } } label: { Image(systemName: "chevron.up") }
                .disabled(selection == nil)
                .help("上移（优先级更高）")
            Button { if let id = selection { move(id, by: 1) } } label: { Image(systemName: "chevron.down") }
                .disabled(selection == nil)
                .help("下移")
            Spacer()
            Text("从上到下，首个命中生效").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.dispatch(.removeMatchRule(id))
        selection = nil
    }

    /// 把选中规则上/下移一格(delta ±1),下发新的整表顺序。
    private func move(_ id: ProxyMatchRule.ID, by delta: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard rules.indices.contains(target) else { return }
        var order = rules
        order.swapAt(index, target)
        store.dispatch(.reorderMatchRules(order.map(\.id)))
    }

    private static func portText(_ range: ClosedRange<UInt16>?) -> LocalizedStringKey {
        guard let range else { return "任意" }
        return range.lowerBound == range.upperBound
            ? LocalizedStringKey("\(range.lowerBound)")
            : LocalizedStringKey("\(range.lowerBound)-\(range.upperBound)")
    }
}

/// 规则动作在表里的展示样式(标签 + 颜色),三态共用一处,避免二元判断漏掉 block。
enum RuleActionStyle {
    static func label(_ action: ProxyRule) -> LocalizedStringKey {
        switch action {
        case .proxied: "代理"
        case .direct: "直连"
        case .block: "拦截"
        case .observe: "观测"
        }
    }

    static func color(_ action: ProxyRule) -> Color {
        switch action {
        case .proxied: .accentColor
        case .direct: .secondary
        case .block: .red
        case .observe: .orange
        }
    }
}

/// 规则 sheet:进程 glob × 主机 glob × 端口(空/单/区间)→ 动作。`editing == nil` = 新增
/// (`addMatchRule`,按三元组去重后置顶);非 nil = 就地编辑那条(`updateMatchRule`,保留位置)。
private struct MatchRuleSheet: View {
    var store: Store
    let editing: ProxyMatchRule?
    @Environment(\.dismiss) private var dismiss

    @State private var appPattern: String
    @State private var hostPattern: String
    @State private var portText: String
    @State private var action: ProxyRule

    init(store: Store, editing: ProxyMatchRule?) {
        self.store = store
        self.editing = editing
        _appPattern = State(initialValue: editing?.appPattern ?? "*")
        _hostPattern = State(initialValue: editing?.hostPattern ?? "*")
        _portText = State(initialValue: editing.map { Self.portField($0.portRange) } ?? "")
        _action = State(initialValue: editing?.action ?? .proxied)
    }

    private var isEditing: Bool { editing != nil }

    /// 双层可选:外层 nil = 输入非法;内层 nil = 「任意端口」。
    private var parsedPort: ClosedRange<UInt16>?? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        let parts = trimmed.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let p = UInt16(parts[0]) { return .some(p...p) }
        if parts.count == 2, let lo = UInt16(parts[0]), let hi = UInt16(parts[1]), lo <= hi { return .some(lo...hi) }
        return nil
    }

    private var canSave: Bool {
        !appPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "编辑规则" : "添加规则").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding()
            Divider()
            Form {
                TextField("进程 glob", text: $appPattern, prompt: Text("com.google.* 或 *"))
                TextField("主机 glob", text: $hostPattern, prompt: Text("*.google.com 或 *"))
                TextField("端口", text: $portText, prompt: Text("空 = 任意，或 443，或 80-443"))
                Picker("动作", selection: $action) {
                    Text("代理").tag(ProxyRule.proxied)
                    Text("直连").tag(ProxyRule.direct)
                    Text("拦截").tag(ProxyRule.block)
                    Text("观测").tag(ProxyRule.observe)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(isEditing ? "保存" : "添加", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 420)
    }

    private func save() {
        guard case .some(let range) = parsedPort else { return }
        let app = appPattern.trimmingCharacters(in: .whitespaces)
        let host = hostPattern.trimmingCharacters(in: .whitespaces)
        if let editing {
            store.dispatch(.updateMatchRule(
                id: editing.id, appPattern: app, hostPattern: host, portRange: range, action: action
            ))
        } else {
            store.dispatch(.addMatchRule(ProxyMatchRule(
                id: RuleID(UUID().uuidString),
                appPattern: app, hostPattern: host, portRange: range, action: action
            )))
        }
        dismiss()
    }

    /// 端口区间 → 编辑框回填文本(与 `RulesEditorPaneView.portText` 的展示口径一致但用于输入)。
    private static func portField(_ range: ClosedRange<UInt16>?) -> String {
        guard let range else { return "" }
        return range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)-\(range.upperBound)"
    }
}

/// 「自动旁路」只读区:系统自动维护的两类强制 / 完全直连,列出并标清**来源**——
/// 「自动 · 回环」= 环检测自愈加入的来源进程(完全旁路);「自动 · 本地代理」= 端口发现识别的
/// 本地代理进程(强制直连)。这些不进用户规则表、不可编辑,是「让代理程序自己的流量不打转」的
/// 安全兜底(与设置「内置规则」同一真相,在规则页也露一份,便于就地对照)。默认折叠。
private struct AutoBypassSection: View {
    let direct: OriginExclusionDiscovery
    let loop: OriginExclusionDiscovery
    @State private var expanded = false

    private var loopEntries: [String] { loop.identifiers.union(loop.executablePaths).sorted() }
    private var directEntries: [String] { direct.identifiers.union(direct.executablePaths).sorted() }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(loopEntries, id: \.self) { row($0, source: "自动 · 回环", tint: .orange) }
                ForEach(directEntries, id: \.self) { row($0, source: "自动 · 本地代理", tint: .accentColor) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } label: {
            HStack(spacing: 8) {
                Label("自动旁路", systemImage: "wand.and.stars").font(.callout.weight(.medium))
                Text("\(loopEntries.count + directEntries.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("系统维护 · 只读").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func row(_ entry: String, source: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(entry)
                .font(.caption).monospaced()
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(source)
                .font(.caption2.weight(.medium)).foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
            Text("直连").font(.caption.weight(.medium))
                .foregroundStyle(RuleActionStyle.color(.direct))
        }
    }
}
