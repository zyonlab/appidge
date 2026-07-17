import SwiftUI
import Core
import AppFeature

/// 连接监视表 —— 主窗口的主体,对齐 Proxifier 的 Connections 表 / 苹果 Console.app 的日志表。
/// 原生 `Table`:应用 | 目标 | 状态 | 规则·代理 | ↑ | ↓。右键某行 → 从这条连接现拼一条精确规则
/// (进程 × 主机 × 端口 → 走代理/直连/拦截),对齐 Proxifier 的 Manual Proxification。
struct ConnectionsTable: View {
    var store: Store
    let filter: String
    /// 只看仍在活动的连接(对齐 Proxifier:上表只有活跃连接,历史沉到日志)。
    let showActiveOnly: Bool
    @Binding var selection: Set<ConnectionLogEntry.ID>
    @State private var sortOrder: [KeyPathComparator<ConnectionLogEntry>] = [
        KeyPathComparator(\.openedAt, order: .reverse)
    ]

    /// 过滤(进程名/主机 + 可选仅活动)后按当前列排序;默认按时间倒序(最新在前),点列头切换排序。
    private var rows: [ConnectionLogEntry] {
        let key = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var filtered = key.isEmpty
            ? store.state.connectionLog
            : store.state.connectionLog.filter {
                appName($0).lowercased().contains(key) || $0.host.lowercased().contains(key)
            }
        if showActiveOnly {
            filtered = filtered.filter { $0.phase == .opened }
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
            // 应用:名字 + 淡显标识,对齐 Proxifier 的 `xray(a.out)`。
            TableColumn("应用", value: \.processID.value) { e in
                AppLabel(
                    name: appName(e),
                    path: store.state.catalog[e.processID]?.executablePath,
                    identifier: e.processID.value
                )
            }.width(min: 150, ideal: 230)

            TableColumn("目标", value: \.host) { e in
                Text("\(e.host):\(e.port)").monospaced().lineLimit(1)
            }.width(min: 150, ideal: 230)

            // 时长/状态(对齐 Proxifier 的 Time/Status):活动 → 存活时长每秒走动;
            // 已关闭/失败 → 状态文案。
            TableColumn("时长 / 状态", value: \.openedAt) { e in
                statusCell(e)
            }.width(min: 84, ideal: 100)

            TableColumn("规则 · 代理") { e in
                RouteChip(rule: e.rule, kind: e.proxyKind)
            }.width(min: 110, ideal: 160)

            TableColumn("发送", value: \.bytesUp) { e in
                Text(TrafficFormat.bytes(e.bytesUp)).monospacedDigit()
            }.width(min: 64, ideal: 76)
            TableColumn("接收", value: \.bytesDown) { e in
                Text(TrafficFormat.bytes(e.bytesDown)).monospacedDigit()
            }.width(min: 64, ideal: 76)
        }
        .contextMenu(forSelectionType: ConnectionLogEntry.ID.self) { ids in
            let targets = rows.filter { ids.contains($0.id) }
            if let first = targets.first {
                Section("为 \(first.host):\(first.port) 建规则") {
                    Button("走代理") { makeRules(targets, .proxied) }
                    Button("直连") { makeRules(targets, .direct) }
                    Button("观测") { makeRules(targets, .observe) }
                    Button("拦截", role: .destructive) { makeRules(targets, .block) }
                }
            }
        }
    }

    /// 时长/状态列:SF Symbol + 语义色 + 文案一起呈现(不靠颜色单独区分,便于无障碍)。
    /// 活动 → 绿实心圈 + **存活时长**(每秒走动,`TimelineView` 只包在活动行的这个格子里,
    /// 可见行数量级,不构成全表刷新);已关闭 → 灰对勾;失败 → 红八角叉。
    @ViewBuilder
    private func statusCell(_ entry: ConnectionLogEntry) -> some View {
        switch entry.phase {
        case .opened:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    TrafficFormat.duration(context.date.timeIntervalSince(entry.openedAt)),
                    systemImage: "circle.fill"
                )
                .monospacedDigit()
                .foregroundStyle(.green)
            }
            .help("活动 · 自 \(entry.openedAt.formatted(date: .omitted, time: .standard)) 建立")
        case .closed:
            Label("已关闭", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .help("已关闭 · \(entry.openedAt.formatted(date: .omitted, time: .standard)) 建立")
        case .failed:
            Label("失败", systemImage: "xmark.octagon")
                .foregroundStyle(.red).help("失败 / 被拦截")
        }
    }

    /// 优先级:目录扫描到的真实 app 名(最权威)> 扩展解出的可读进程名(未签名命令行程序的
    /// 兜底,比如 `a.out` → `xray`)> 原始 processID(最后兜底)。
    private func appName(_ entry: ConnectionLogEntry) -> String {
        store.state.catalog[entry.processID]?.displayName ?? entry.processDisplayName ?? entry.processID.value
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
        case .observe: "eye"
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
        case (.observe, _): "观测"
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
        case .observe: .orange
        }
    }
}
