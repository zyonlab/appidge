import SwiftUI
import Core
import AppFeature

/// 三区窗口：目录 / 规则 / 活动监视器。UI 只做两件事：读 store.state、dispatch(Action)。
struct ContentView: View {
    var store: Store

    var body: some View {
        TabView {
            DirectoryPaneView(store: store)
                .tabItem { Label("目录", systemImage: "folder") }
            RulesPaneView(store: store)
                .tabItem { Label("规则", systemImage: "list.bullet") }
            RulesEditorPaneView(store: store)
                .tabItem { Label("规则表", systemImage: "list.number") }
            ProxyServersPaneView(store: store)
                .tabItem { Label("代理服务器", systemImage: "server.rack") }
            ActivityMonitorPaneView(store: store)
                .tabItem { Label("活动监视器", systemImage: "waveform.path.ecg") }
            ConnectionLogPaneView(store: store)
                .tabItem { Label("连接", systemImage: "point.3.filled.connected.trianglepath.dotted") }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

struct DirectoryPaneView: View {
    var store: Store

    var body: some View {
        Form {
            Toggle("全局代理", isOn: Binding(
                get: { store.state.isGlobalProxyEnabled },
                set: { store.dispatch(.setGlobalProxyEnabled($0)) }
            ))
            Text(store.state.isEngineHealthy ? "引擎正常" : "引擎异常，已回退直连")
                .foregroundStyle(store.state.isEngineHealthy ? Color.primary : Color.red)
        }
        .padding()
    }
}

struct RulesPaneView: View {
    var store: Store

    private var sortedProcesses: [MonitoredProcess] {
        store.state.processes.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        List(sortedProcesses, id: \.id) { process in
            HStack {
                Text(process.displayName)
                Spacer()
                Picker("规则", selection: Binding(
                    get: { process.rule },
                    set: { store.dispatch(.assignRule(processID: process.id, rule: $0)) }
                )) {
                    Text("直连").tag(ProxyRule.direct)
                    Text("代理").tag(ProxyRule.proxied)
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }
}

struct ActivityMonitorPaneView: View {
    var store: Store

    private var sortedProcesses: [MonitoredProcess] {
        store.state.processes.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlobalTrafficHeader(store: store)
            Divider()
            processList
        }
    }

    private var processList: some View {
        List(sortedProcesses, id: \.id) { process in
            HStack {
                Text(process.displayName)
                Spacer()
                Text("↑\(process.stats.bytesUp)B ↓\(process.stats.bytesDown)B")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Picker("规则", selection: Binding(
                    get: { process.rule },
                    set: { store.dispatch(.assignRule(processID: process.id, rule: $0)) }
                )) {
                    Text("直连").tag(ProxyRule.direct)
                    Text("代理").tag(ProxyRule.proxied)
                }
                .labelsHidden()
                .frame(width: 120)
                Button("诊断") {
                    store.dispatch(.requestDiagnostic(processID: process.id, kinds: Core.DiagnosticKind.allCases))
                }
            }
        }
    }
}

/// 活动监视器顶部的全局流量条:累计上下行 + 实时速率 + 最活跃进程。速率不靠定时器——
/// 每当流量批量到达(store 更新、总量变化)就用两次快照的真实间隔算一次(elapsed 传入
/// `TrafficStatsAggregator.rate`),纯响应式刷新。
private struct GlobalTrafficHeader: View {
    var store: Store
    @State private var rate = TrafficStatsAggregator.ThroughputRate(bytesUpPerSecond: 0, bytesDownPerSecond: 0)
    @State private var previousTotals: (up: Int64, down: Int64) = (0, 0)
    @State private var previousAt = Date()

    private var processes: [MonitoredProcess] { Array(store.state.processes.values) }
    private var totals: (up: Int64, down: Int64) { TrafficStatsAggregator.totals(processes) }
    private var topTalker: MonitoredProcess? {
        TrafficStatsAggregator.topByThroughput(processes, limit: 1).first
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("全局  ↑ \(TrafficFormat.bytes(totals.up))   ↓ \(TrafficFormat.bytes(totals.down))")
                    .monospacedDigit()
                Text("速率  ↑ \(TrafficFormat.rate(rate.bytesUpPerSecond))   ↓ \(TrafficFormat.rate(rate.bytesDownPerSecond))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if let top = topTalker, top.stats.bytesUp &+ top.stats.bytesDown > 0 {
                Text("最活跃：\(top.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onChange(of: totals.up &+ totals.down) { _, _ in
            let now = Date()
            rate = TrafficStatsAggregator.rate(
                previous: previousTotals, current: totals, elapsedSeconds: now.timeIntervalSince(previousAt)
            )
            previousTotals = totals
            previousAt = now
        }
    }
}

struct MenuBarView: View {
    var store: Store

    private var totals: (up: Int64, down: Int64) {
        TrafficStatsAggregator.totals(Array(store.state.processes.values))
    }

    var body: some View {
        Text("↑ \(TrafficFormat.bytes(totals.up))   ↓ \(TrafficFormat.bytes(totals.down))")
        Divider()
        Toggle("全局代理", isOn: Binding(
            get: { store.state.isGlobalProxyEnabled },
            set: { store.dispatch(.setGlobalProxyEnabled($0)) }
        ))
        Divider()
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
