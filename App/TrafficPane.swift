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
            case .traffic: TrafficTab(store: store)
            case .stats: PerProcessStats(store: store)
            }
        }
        .background(.background)
    }
}

/// 「流量」标签:带宽曲线(主) + 底部一行累计总量。实时速率看曲线本身。
private struct TrafficTab: View {
    var store: Store
    private var totals: (up: Int64, down: Int64) {
        TrafficStatsAggregator.totals(Array(store.state.processes.values))
    }

    var body: some View {
        VStack(spacing: 4) {
            BandwidthChart(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            HStack(spacing: 20) {
                Text("累计 ↑ \(TrafficFormat.bytes(totals.up))").foregroundStyle(.green)
                Text("累计 ↓ \(TrafficFormat.bytes(totals.down))").foregroundStyle(.blue)
                Spacer()
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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
