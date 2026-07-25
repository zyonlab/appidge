import SwiftUI
import Core
import AppFeature

/// 主窗口底部状态栏(对齐 Proxifier 底部那条):引擎健康 · 活动连接数 · 全局累计上下行。
/// 用 `.bar` 材质,贴在 `.safeAreaInset(edge:.bottom)`。
/// 动效(§08「动事件不动数值」):累计上下行用 `.numericText()` 数字滚动(事件驱动,只在值变时动)。
/// ⚠️ 状态灯**不做**常驻动画:曾经的 `.symbolEffect(.breathe/.pulse, .repeat(.continuous))`
/// 在真机上让 app 本体常驻 100%+ CPU——ProMotion 下 SF Symbol 的连续动画每帧插值重绘
/// (RenderBox RBInterpolatedDisplayListContents),状态栏又常驻可见,等于永不停歇的全帧率
/// 渲染循环(sample 实锤:主线程大头全在 UpdateCycle/CA::Transaction::commit/CGDrawingLayer.draw)。
/// 状态语义靠颜色 + 文案表达,不靠动画。
struct StatusBar: View {
    var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    private var activeCount: Int {
        store.state.connectionLog.reduce(into: 0) { if $1.phase == .opened { $0 += 1 } }
    }
    private var totals: (up: Int64, down: Int64) {
        TrafficStatsAggregator.totals(Array(store.state.processes.values))
    }

    /// 状态栏那一格的呈现要素。`emphasized` = 是否给文字上色(否则用 primary)。
    private struct StatusInfo {
        let color: Color
        let text: LocalizedStringKey
        let emphasized: Bool
        let tooltip: LocalizedStringKey?
    }

    /// 状态先看扩展装没装(没装/待批准/失败都得先说清,否则"引擎正常"会误导);装上了再看引擎健康度。
    private var status: StatusInfo {
        switch store.state.extensionActivation {
        case .activePendingReboot:
            // 如实告知：接管在跑，但跑的是旧版本扩展，新版本要重启电脑才生效。
            return StatusInfo(color: .orange, text: "新版本待重启生效 · 仍在接管", emphasized: true,
                              tooltip: "已装新版本，但系统要重启电脑后才会换到它；当前仍由旧版本扩展接管流量，功能不受影响。")
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
        case .disabled:
            return StatusInfo(color: .orange, text: "扩展已停用 · 系统设置里开启", emphasized: true,
                              tooltip: "appidge 的网络扩展在「系统设置 → 通用 → 登录项与扩展」里被停用了,重新打开后即恢复接管(最多 30 秒自动重连,无需重启 app)。")
        case .failed(let reason):
            return StatusInfo(color: .red, text: "扩展未安装", emphasized: true, tooltip: "\(reason)")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(status.color)
                Text(status.text)
                    .foregroundStyle(status.emphasized ? status.color : Color.primary)
            }
            .help(status.tooltip ?? "")
            Divider().frame(height: 11)
            Text("活动连接 \(activeCount)")
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: activeCount)
            Spacer()
            // 试用倒计时 + 醒目购买入口（原主窗口顶部整条横幅收到这里）。已授权/到期不显示：
            // 到期时 isLicenseActive 为假、主窗口走授权门，本状态栏不构建。
            if case .trial(let days) = TrialState.from(store.state.licensePhase) {
                TrialStatusItem(store: store, daysLeft: days) {
                    openWindow(id: AppWindowID.manageLicense)
                }
                Divider().frame(height: 11)
            }
            Text("↑ \(TrafficFormat.bytes(totals.up))   ↓ \(TrafficFormat.bytes(totals.down))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: totals.up &+ totals.down)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
