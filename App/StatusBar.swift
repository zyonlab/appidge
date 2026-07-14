import SwiftUI
import Core
import AppFeature

/// 主窗口底部状态栏(对齐 Proxifier 底部那条):引擎健康 · 活动连接数 · 全局累计上下行。
/// 用 `.bar` 材质,贴在 `.safeAreaInset(edge:.bottom)`。
struct StatusBar: View {
    var store: Store

    private var activeCount: Int {
        store.state.connectionLog.reduce(into: 0) { if $1.phase == .opened { $0 += 1 } }
    }
    private var totals: (up: Int64, down: Int64) {
        TrafficStatsAggregator.totals(Array(store.state.processes.values))
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(store.state.isEngineHealthy ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(store.state.isEngineHealthy ? "引擎正常" : "引擎异常 · 已回退直连")
                    .foregroundStyle(store.state.isEngineHealthy ? Color.primary : Color.red)
            }
            Divider().frame(height: 11)
            Text("活动连接 \(activeCount)")
            Spacer()
            Text("↑ \(TrafficFormat.bytes(totals.up))   ↓ \(TrafficFormat.bytes(totals.down))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
