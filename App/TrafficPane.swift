import SwiftUI
import Core
import AppFeature

/// 主窗口「活动」底部面板:带宽曲线(主) + 底部一行累计总量。实时速率看曲线本身。
/// 旧的「流量 / 应用」子分段已拆分:「应用」提升为顶层 tab(见 `AppsPaneView`),这里只留流量。
struct TrafficPane: View {
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
        .background(.background)
    }
}
