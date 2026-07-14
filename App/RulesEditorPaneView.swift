import SwiftUI
import Core
import AppFeature

/// 「规则表」:细粒度规则(进程 × 主机 × 端口),从上到下、首个命中生效。UI 只读 store.state、
/// 只 dispatch(Action)。故意做得朴素(用户说 UI 先简单),拖动排序 + 删除 + 一个添加表单。
struct RulesEditorPaneView: View {
    var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("规则表(从上到下,首个命中生效;都不命中回落到「规则」页的每进程设置)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.state.rules.isEmpty {
                Text("还没有规则。用下面的表单加一条,比如「主机 *.google.com → 代理」。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List {
                    ForEach(store.state.rules) { rule in
                        MatchRuleRow(rule: rule, onRemove: { store.dispatch(.removeMatchRule(rule.id)) })
                    }
                    .onMove { indices, newOffset in
                        var order = store.state.rules
                        order.move(fromOffsets: indices, toOffset: newOffset)
                        store.dispatch(.reorderMatchRules(order.map(\.id)))
                    }
                }
            }

            Divider()
            AddMatchRuleForm(store: store)
        }
        .padding()
    }
}

/// 一条规则一行:进程 / 主机 / 端口 / 动作,右侧删除。
private struct MatchRuleRow: View {
    let rule: ProxyMatchRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rule.appPattern)  ·  \(rule.hostPattern)\(Self.portSuffix(rule.portRange))")
                    .monospaced()
                    .font(.callout)
                Text(rule.action == .proxied ? "代理" : "直连")
                    .font(.caption)
                    .foregroundStyle(rule.action == .proxied ? Color.accentColor : Color.secondary)
            }
            Spacer()
            Button("删除", role: .destructive, action: onRemove)
        }
    }

    private static func portSuffix(_ range: ClosedRange<UInt16>?) -> String {
        guard let range else { return "" }
        return range.lowerBound == range.upperBound ? " :\(range.lowerBound)" : " :\(range.lowerBound)-\(range.upperBound)"
    }
}

/// 「添加规则」表单。端口留空 = 任意;可填单个「443」或区间「80-443」。
private struct AddMatchRuleForm: View {
    var store: Store

    @State private var appPattern = "*"
    @State private var hostPattern = "*"
    @State private var portText = ""
    @State private var action: ProxyRule = .proxied

    private var parsedPort: ClosedRange<UInt16>?? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) } // 任意端口
        let parts = trimmed.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let p = UInt16(parts[0]) { return .some(p...p) }
        if parts.count == 2, let lo = UInt16(parts[0]), let hi = UInt16(parts[1]), lo <= hi { return .some(lo...hi) }
        return nil // 非法输入
    }

    private var canAdd: Bool {
        !appPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("添加规则").font(.subheadline)
            HStack {
                TextField("进程 glob,如 com.google.*", text: $appPattern)
                TextField("主机 glob,如 *.google.com", text: $hostPattern)
                TextField("端口(空=任意)", text: $portText).frame(width: 120)
            }
            Picker("动作", selection: $action) {
                Text("代理").tag(ProxyRule.proxied)
                Text("直连").tag(ProxyRule.direct)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            Button("添加", action: add).disabled(!canAdd)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func add() {
        guard case .some(let range) = parsedPort else { return }
        let rule = ProxyMatchRule(
            id: RuleID(UUID().uuidString),
            appPattern: appPattern.trimmingCharacters(in: .whitespaces),
            hostPattern: hostPattern.trimmingCharacters(in: .whitespaces),
            portRange: range,
            action: action
        )
        store.dispatch(.addMatchRule(rule))
        appPattern = "*"
        hostPattern = "*"
        portText = ""
        action = .proxied
    }
}
