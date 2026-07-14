import SwiftUI
import Core
import AppFeature

/// 主界面已改为 Console 风的 `MainWindow`(见 MainWindow.swift):单窗口连接监视 + 底部流量 + 状态栏,
/// 配置弹 sheet、全局设置进 `Settings` 场景。这里只保留仍被复用的两个小件:菜单栏内容 + 环告警条。
/// (旧的七 tab —— 目录/规则/规则表/活动监视器/连接 —— 的职责已合进主窗口 + sheets + Settings。)

/// 菜单栏下拉:一眼看流量总量 + 全局开关 + 退出。
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

/// 主动环检测告警条:贴在主窗口顶部。`internal` 供 MainWindow 引用。
struct LoopWarningBanner: View {
    let signature: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("检测到疑似转发环：\(signature) 被反复捕获。请检查上游 / 规则是否形成回路。")
                .font(.callout)
            Spacer()
            Button("忽略", action: onDismiss)
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red)
    }
}
