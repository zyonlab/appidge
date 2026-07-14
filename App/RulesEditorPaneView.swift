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

    private var rules: [ProxyMatchRule] { store.state.rules }

    var body: some View {
        VStack(spacing: 0) {
            if rules.isEmpty {
                ContentUnavailableView(
                    "还没有规则",
                    systemImage: "list.bullet.rectangle",
                    description: Text("点「＋」加一条，比如「主机 *.google.com → 代理」。规则从上到下、首个命中生效。")
                )
                .frame(maxHeight: .infinity)
            } else {
                rulesTable
            }
            Divider()
            toolbar
        }
        .sheet(isPresented: $showingAdd) {
            AddMatchRuleSheet(store: store)
        }
    }

    private var rulesTable: some View {
        Table(rules, selection: $selection) {
            TableColumn("进程") { r in Text(r.appPattern).monospaced().lineLimit(1) }
            TableColumn("主机") { r in Text(r.hostPattern).monospaced().lineLimit(1) }
            TableColumn("端口") { r in Text(Self.portText(r.portRange)) }.width(90)
            TableColumn("动作") { r in
                Text(RuleActionStyle.label(r.action)).foregroundStyle(RuleActionStyle.color(r.action))
            }.width(70)
        }
        .contextMenu(forSelectionType: ProxyMatchRule.ID.self) { ids in
            if let id = ids.first {
                Button("上移") { move(id, by: -1) }
                Button("下移") { move(id, by: 1) }
                Divider()
                Button("删除", role: .destructive) { store.dispatch(.removeMatchRule(id)) }
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

    private static func portText(_ range: ClosedRange<UInt16>?) -> String {
        guard let range else { return "任意" }
        return range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)-\(range.upperBound)"
    }
}

/// 规则动作在表里的展示样式(标签 + 颜色),三态共用一处,避免二元判断漏掉 block。
enum RuleActionStyle {
    static func label(_ action: ProxyRule) -> String {
        switch action {
        case .proxied: "代理"
        case .direct: "直连"
        case .block: "拦截"
        }
    }

    static func color(_ action: ProxyRule) -> Color {
        switch action {
        case .proxied: .accentColor
        case .direct: .secondary
        case .block: .red
        }
    }
}

/// 「添加规则」sheet:进程 glob × 主机 glob × 端口(空/单/区间)→ 动作。添加后自动关闭。
private struct AddMatchRuleSheet: View {
    var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var appPattern = "*"
    @State private var hostPattern = "*"
    @State private var portText = ""
    @State private var action: ProxyRule = .proxied

    /// 双层可选:外层 nil = 输入非法;内层 nil = 「任意端口」。
    private var parsedPort: ClosedRange<UInt16>?? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        let parts = trimmed.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let p = UInt16(parts[0]) { return .some(p...p) }
        if parts.count == 2, let lo = UInt16(parts[0]), let hi = UInt16(parts[1]), lo <= hi { return .some(lo...hi) }
        return nil
    }

    private var canAdd: Bool {
        !appPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加规则").font(.headline)
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
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("添加", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding()
        }
        .frame(width: 420)
    }

    private func add() {
        guard case .some(let range) = parsedPort else { return }
        store.dispatch(.addMatchRule(ProxyMatchRule(
            id: RuleID(UUID().uuidString),
            appPattern: appPattern.trimmingCharacters(in: .whitespaces),
            hostPattern: hostPattern.trimmingCharacters(in: .whitespaces),
            portRange: range,
            action: action
        )))
        dismiss()
    }
}
