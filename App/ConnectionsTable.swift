import SwiftUI
import Core
import AppFeature

/// 连接监视表 —— 主窗口的主体,对齐 Proxifier 的 Connections 表 / 苹果 Console.app 的日志表。
/// 原生 `Table`:应用 | 目标 | 状态 | 规则·代理 | ↑ | ↓。右键某行 → 从这条连接现拼一条精确规则
/// (进程 × 主机 × 端口 → 走代理/直连/拦截),对齐 Proxifier 的 Manual Proxification。
struct ConnectionsTable: View {
    var store: Store
    let filter: String
    @Binding var selection: Set<ConnectionLogEntry.ID>

    /// 最新在前 + 按过滤词(进程名/主机)筛。
    private var rows: [ConnectionLogEntry] {
        let all = Array(store.state.connectionLog.reversed())
        let key = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return all }
        return all.filter { appName($0.processID).lowercased().contains(key) || $0.host.lowercased().contains(key) }
    }

    var body: some View {
        Group {
            if store.state.connectionLog.isEmpty {
                ContentUnavailableView(
                    "还没有连接",
                    systemImage: "point.3.filled.connected.trianglepath.dotted",
                    description: Text("扩展被批准并有流量后，每条连接会实时出现在这里。")
                )
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("应用") { e in
                Label(appName(e.processID), systemImage: "app.dashed").lineLimit(1)
            }.width(min: 140, ideal: 200)

            TableColumn("目标") { e in
                Text("\(e.host):\(e.port)").monospaced().lineLimit(1)
            }.width(min: 160, ideal: 240)

            TableColumn("状态") { e in statusCell(e.phase) }.width(80)

            TableColumn("规则 · 代理") { e in
                Text(RouteText.label(rule: e.rule, kind: e.proxyKind))
                    .foregroundStyle(RouteText.color(e.rule))
                    .lineLimit(1)
            }.width(min: 120, ideal: 170)

            TableColumn("↑") { e in Text(TrafficFormat.bytes(e.bytesUp)).monospacedDigit() }.width(70)
            TableColumn("↓") { e in Text(TrafficFormat.bytes(e.bytesDown)).monospacedDigit() }.width(70)
        }
        .contextMenu(forSelectionType: ConnectionLogEntry.ID.self) { ids in
            let targets = rows.filter { ids.contains($0.id) }
            if let first = targets.first {
                Section("为 \(first.host):\(first.port) 建规则") {
                    Button("走代理") { makeRules(targets, .proxied) }
                    Button("直连") { makeRules(targets, .direct) }
                    Button("拦截", role: .destructive) { makeRules(targets, .block) }
                }
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ phase: ConnectionPhase) -> some View {
        switch phase {
        case .opened:
            Label("活动", systemImage: "circle.fill").foregroundStyle(.green).labelStyle(.iconOnly)
                .help("活动")
        case .closed:
            Label("已关闭", systemImage: "circle").foregroundStyle(.secondary).labelStyle(.iconOnly)
                .help("已关闭")
        case .failed:
            Label("失败", systemImage: "xmark.circle.fill").foregroundStyle(.red).labelStyle(.iconOnly)
                .help("失败 / 被拦截")
        }
    }

    private func appName(_ id: ProcessID) -> String {
        store.state.catalog[id]?.displayName ?? id.value
    }

    private func makeRules(_ entries: [ConnectionLogEntry], _ action: ProxyRule) {
        for e in entries {
            store.dispatch(.addMatchRule(ProxyMatchRule(
                id: RuleID(UUID().uuidString),
                appPattern: e.processID.value,
                hostPattern: e.host,
                portRange: e.port...e.port,
                action: action
            )))
        }
    }
}

/// 「规则·代理」列的文案与颜色,单处共用(直连/拦截/代理·协议)。
enum RouteText {
    static func label(rule: ProxyRule, kind: ProxyKind?) -> String {
        switch (rule, kind) {
        case (.direct, _): "直连"
        case (.block, _): "拦截"
        case (.proxied, .some(.socks5)): "代理 · SOCKS5"
        case (.proxied, .some(.httpConnect)): "代理 · HTTP"
        case (.proxied, .none): "代理（回落直连）"
        }
    }

    static func color(_ rule: ProxyRule) -> Color {
        switch rule {
        case .proxied: .accentColor
        case .block: .red
        case .direct: .secondary
        }
    }
}
