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

    /// 状态栏那一格的呈现要素。`emphasized` = 是否给文字上色(否则用 primary)。
    private struct StatusInfo {
        let color: Color
        let text: String
        let emphasized: Bool
        let tooltip: String?
    }

    /// 状态先看扩展装没装(没装/待批准/失败都得先说清,否则"引擎正常"会误导);装上了再看引擎健康度。
    private var status: StatusInfo {
        switch store.state.extensionActivation {
        case .active:
            return store.state.isEngineHealthy
                ? StatusInfo(color: .green, text: "引擎正常", emphasized: false, tooltip: nil)
                : StatusInfo(color: .red, text: "引擎异常 · 已回退直连", emphasized: true, tooltip: nil)
        case .inactive:
            return StatusInfo(color: .secondary, text: "扩展未接入", emphasized: true,
                              tooltip: "系统扩展还没装上/批准——去设置里点「启用」并在系统设置里允许后,才会接管流量。")
        case .activating:
            return StatusInfo(color: .orange, text: "扩展安装中…", emphasized: false, tooltip: nil)
        case .needsApproval:
            return StatusInfo(color: .orange, text: "扩展待批准 · 系统设置里点允许", emphasized: true,
                              tooltip: "打开「系统设置 → 隐私与安全性」,点「允许」加载 appidge 的系统扩展。")
        case .failed(let reason):
            return StatusInfo(color: .red, text: "扩展未安装", emphasized: true, tooltip: reason)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.text)
                    .foregroundStyle(status.emphasized ? status.color : Color.primary)
            }
            .help(status.tooltip ?? "")
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
