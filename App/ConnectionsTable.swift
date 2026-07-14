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
    @State private var sortOrder: [KeyPathComparator<ConnectionLogEntry>] = [
        KeyPathComparator(\.openedAt, order: .reverse)
    ]

    /// 过滤(进程名/主机)后按当前列排序;默认按时间倒序(最新在前),点列头切换排序。
    private var rows: [ConnectionLogEntry] {
        let key = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = key.isEmpty
            ? store.state.connectionLog
            : store.state.connectionLog.filter {
                appName($0.processID).lowercased().contains(key) || $0.host.lowercased().contains(key)
            }
        return filtered.sorted(using: sortOrder)
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
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("应用", value: \.processID.value) { e in
                Label(appName(e.processID), systemImage: "app.dashed").lineLimit(1)
            }.width(min: 130, ideal: 190)

            TableColumn("目标", value: \.host) { e in
                Text("\(e.host):\(e.port)").monospaced().lineLimit(1)
            }.width(min: 150, ideal: 230)

            TableColumn("状态") { e in statusCell(e.phase) }.width(min: 68, ideal: 90)

            TableColumn("规则 · 代理") { e in
                RouteChip(rule: e.rule, kind: e.proxyKind)
            }.width(min: 110, ideal: 160)

            TableColumn("时间", value: \.openedAt) { e in
                Text(e.openedAt.formatted(date: .omitted, time: .standard))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.width(92)

            TableColumn("↑", value: \.bytesUp) { e in Text(TrafficFormat.bytes(e.bytesUp)).monospacedDigit() }.width(64)
            TableColumn("↓", value: \.bytesDown) { e in Text(TrafficFormat.bytes(e.bytesDown)).monospacedDigit() }.width(64)
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

    /// 状态列:SF Symbol + 语义色 + 文案一起呈现(不靠颜色单独区分,便于无障碍)。
    /// 活动→绿实心圈、已关闭→灰对勾、失败→红八角叉。
    @ViewBuilder
    private func statusCell(_ phase: ConnectionPhase) -> some View {
        switch phase {
        case .opened:
            Label("活动", systemImage: "circle.fill")
                .foregroundStyle(.green).help("活动")
        case .closed:
            Label("已关闭", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary).help("已关闭")
        case .failed:
            Label("失败", systemImage: "xmark.octagon")
                .foregroundStyle(.red).help("失败 / 被拦截")
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

/// 「规则·代理」列的语义胶囊:底色 + 描边 + SF Symbol + 文案。颜色随规则(复用 `RouteText.color`),
/// 形状也编码语义 —— 直连→直行箭头、代理→分支、拦截→禁止手势,不只靠颜色区分,
/// 对齐 Little Snitch / Proxifier 的一眼可读。保持紧凑以适配表格行高。
/// 非 private:连接表与右侧 Inspector 详情共用同一枚胶囊,保证路由呈现一致。
struct RouteChip: View {
    let rule: ProxyRule
    let kind: ProxyKind?

    private var tint: Color { RouteText.color(rule) }

    private var symbol: String {
        switch rule {
        case .direct: "arrow.right"
        case .proxied: "arrow.triangle.branch"
        case .block: "hand.raised"
        }
    }

    var body: some View {
        Label(RouteText.label(rule: rule, kind: kind), systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
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

    /// 路由语义色「词汇表」——连接表 chip 与「应用」表(TrafficPane)共用同一处,保证一致:
    /// 直连=绿(放行 / 健康) · 代理=蓝(accent,经上游) · 拦截=红。与设计提案的语义色对齐。
    static func color(_ rule: ProxyRule) -> Color {
        switch rule {
        case .direct: .green
        case .proxied: .accentColor
        case .block: .red
        }
    }
}
