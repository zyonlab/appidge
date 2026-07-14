import SwiftUI
import Core
import AppFeature

/// 主窗口底部面板:流量(全局累计 + 实时速率 + 最活跃)/ 统计(每进程 Table)。对齐 Proxifier 底部的
/// Traffic / Statistics 标签页。速率不用定时器——每当流量批量到达就用两次快照的真实间隔算一次。
struct TrafficPane: View {
    var store: Store
    @State private var tab: Tab = .traffic

    enum Tab: String, CaseIterable, Identifiable { case traffic = "流量", stats = "统计"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(6)
            Divider()
            switch tab {
            case .traffic: TrafficReadout(store: store)
            case .stats: PerProcessStats(store: store)
            }
        }
        .background(.background)
    }
}

private struct TrafficReadout: View {
    var store: Store
    @State private var rate = TrafficStatsAggregator.ThroughputRate(bytesUpPerSecond: 0, bytesDownPerSecond: 0)
    @State private var previous: (up: Int64, down: Int64) = (0, 0)
    @State private var previousAt = Date()

    private var processes: [MonitoredProcess] { Array(store.state.processes.values) }
    private var totals: (up: Int64, down: Int64) { TrafficStatsAggregator.totals(processes) }
    private var top: [MonitoredProcess] { TrafficStatsAggregator.topByThroughput(processes, limit: 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 28) {
                metric("累计上行", TrafficFormat.bytes(totals.up), "arrow.up")
                metric("累计下行", TrafficFormat.bytes(totals.down), "arrow.down")
                metric("上行速率", TrafficFormat.rate(rate.bytesUpPerSecond), "arrow.up.circle")
                metric("下行速率", TrafficFormat.rate(rate.bytesDownPerSecond), "arrow.down.circle")
            }
            if !top.contains(where: { $0.stats.bytesUp &+ $0.stats.bytesDown > 0 }) {
                Text("暂无流量").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("最活跃").font(.caption).foregroundStyle(.secondary)
                ForEach(top, id: \.id) { p in
                    if p.stats.bytesUp &+ p.stats.bytesDown > 0 {
                        HStack {
                            Text(p.displayName).lineLimit(1)
                            Spacer()
                            Text("↑\(TrafficFormat.bytes(p.stats.bytesUp))  ↓\(TrafficFormat.bytes(p.stats.bytesDown))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: totals.up &+ totals.down) { _, _ in
            let now = Date()
            rate = TrafficStatsAggregator.rate(
                previous: previous, current: totals, elapsedSeconds: now.timeIntervalSince(previousAt)
            )
            previous = totals
            previousAt = now
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }
}

private struct PerProcessStats: View {
    var store: Store

    private var processes: [MonitoredProcess] {
        store.state.processes.values.sorted { ($0.stats.bytesUp + $0.stats.bytesDown) > ($1.stats.bytesUp + $1.stats.bytesDown) }
    }

    var body: some View {
        Table(processes) {
            TableColumn("进程") { p in Text(p.displayName).lineLimit(1) }
            TableColumn("规则") { p in
                Text(RouteText.label(rule: p.rule, kind: nil)).foregroundStyle(RouteText.color(p.rule))
            }.width(90)
            TableColumn("↑") { p in Text(TrafficFormat.bytes(p.stats.bytesUp)).monospacedDigit() }.width(80)
            TableColumn("↓") { p in Text(TrafficFormat.bytes(p.stats.bytesDown)).monospacedDigit() }.width(80)
        }
    }
}
