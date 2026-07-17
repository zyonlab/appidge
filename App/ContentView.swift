import SwiftUI
import Core
import AppFeature

/// 主界面已改为 Console 风的 `MainWindow`(见 MainWindow.swift):单窗口连接监视 + 底部流量 + 状态栏,
/// 配置弹 sheet、全局设置进 `Settings` 场景。这里只保留仍被复用的两个小件:菜单栏内容 + 环告警条。
/// (旧的七 tab —— 目录/规则/规则表/活动监视器/连接 —— 的职责已合进主窗口 + sheets + Settings。)

/// 菜单栏下拉:一眼看状态的迷你仪表盘(对齐 iStat Menus / Little Snitch 的状态菜单)——
/// 引擎/扩展健康 · 全局吞吐 · 活动连接数 · 流量占用 Top 5 · 全局开关 · 设置/退出。
/// 只读 `store.state`、只 `dispatch(action)`,不持任何本地状态(对齐单向数据流)。
struct MenuBarView: View {
    var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 状态行的呈现要素:SF Symbol + 语义色 + 文案(+ 可选 tooltip)。永不只靠颜色——
    /// 符号与文案同时表意,色盲/高对比场景也读得懂。
    private struct StatusPresentation {
        let symbol: String
        let tint: Color
        let text: String
        let help: String?
    }

    /// 先看扩展装没装(未接入/待批准/安装中/未安装都得先说清,否则"引擎正常"会误导),
    /// 装上了(`.active`)再看引擎健康度。与底部状态栏(`StatusBar`)同一套判定,换成菜单里
    /// 更直观的符号呈现。绿=已接管,橙=待批准/安装中,红=未安装/异常,次要灰=未接入。
    private var status: StatusPresentation {
        switch store.state.extensionActivation {
        case .active:
            return store.state.isEngineHealthy
                ? StatusPresentation(symbol: "checkmark.shield.fill", tint: .green,
                                     text: "已接管", help: nil)
                : StatusPresentation(symbol: "exclamationmark.triangle.fill", tint: .red,
                                     text: "引擎异常 · 已回退直连", help: nil)
        case .inactive:
            return StatusPresentation(symbol: "bolt.horizontal.circle", tint: .secondary,
                                      text: "扩展未接入",
                                      help: "系统扩展还没装上/批准——去设置里点「启用」并在系统设置里允许后,才会接管流量。")
        case .activating:
            return StatusPresentation(symbol: "arrow.triangle.2.circlepath", tint: .orange,
                                      text: "扩展安装中…", help: nil)
        case .needsApproval:
            return StatusPresentation(symbol: "exclamationmark.circle.fill", tint: .orange,
                                      text: "待批准 · 系统设置里点允许",
                                      help: "打开「系统设置 → 隐私与安全性」,点「允许」加载 appidge 的系统扩展。")
        case .disabled:
            return StatusPresentation(symbol: "bolt.slash.circle", tint: .orange,
                                      text: "扩展已停用 · 系统设置里开启",
                                      help: "「系统设置 → 通用 → 登录项与扩展」里重新打开 appidge 的网络扩展,最多 30 秒自动恢复接管。")
        case .failed(let reason):
            return StatusPresentation(symbol: "xmark.octagon.fill", tint: .red,
                                      text: "扩展未安装", help: reason)
        }
    }

    /// 全局累计上/下行,复用纯计算 `TrafficStatsAggregator`。
    private var totals: (up: Int64, down: Int64) {
        TrafficStatsAggregator.totals(Array(store.state.processes.values))
    }

    /// 活动连接 = 连接日志里仍处于 `.opened` 的条数(与 `StatusBar` 同口径)。
    private var activeConnectionCount: Int {
        store.state.connectionLog.reduce(into: 0) { if $1.phase == .opened { $0 += 1 } }
    }

    /// 吞吐(上+下)最高的前 5 个进程,复用纯计算 `TrafficStatsAggregator.topByThroughput`。
    private var topProcesses: [MonitoredProcess] {
        TrafficStatsAggregator.topByThroughput(Array(store.state.processes.values), limit: 5)
    }

    private func upDown(_ up: Int64, _ down: Int64) -> String {
        "↑ \(TrafficFormat.bytes(up))  ↓ \(TrafficFormat.bytes(down))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 状态:符号 + 语义色 + 文案三者齐备,不只靠颜色。
            // ⚠️ 不做 `.repeat(.continuous)` 符号动画——真机上常驻连续动画让 app 100%+ CPU,
            // 见 StatusBar 的同一条注释(sample 实锤)。
            Label(status.text, systemImage: status.symbol)
                .foregroundStyle(status.tint)
                .font(.body.weight(.medium))
                .help(status.help ?? "")

            Divider()

            // 1b. 接管层短状态:一眼看清"我们在管哪一层"(详解在设置里)。
            let coverage = ProxyCoverage.shortStatus(store.state.proxyEnvironment)
            Label(coverage.text, systemImage: coverage.symbol)
                .font(.caption)
                .foregroundStyle(coverage.tint)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // 2 + 3. 全局吞吐总量 + 活动连接数(标签左、值右对齐)。
            statRow("总流量", upDown(totals.up, totals.down))
            statRow("活动连接", "\(activeConnectionCount)")

            Divider()

            // 4. 流量占用 Top 5(无流量时给一条克制的占位)。
            Text("流量占用 Top 5")
                .font(.caption)
                .foregroundStyle(.secondary)
            if topProcesses.isEmpty {
                Text("暂无流量")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topProcesses) { process in
                    HStack {
                        Text(process.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(upDown(process.stats.bytesUp, process.stats.bytesDown))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()

            // 5. 紧急恢复:浏览器等断网时的一键出口(停止会话 + 移除代理配置,全部应用立即恢复
            //    原生直连,无需重启电脑)。放菜单栏是因为主窗口此时可能根本打不开/没人想找设置。
            Button {
                Task { await TransparentProxyController.reset() }
            } label: {
                Label("紧急恢复直连（重置接管）", systemImage: "exclamationmark.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .help("停止接管并移除系统里的代理配置——浏览器等应用断网时的恢复出口，无需重启电脑。重启 app 可重新开启接管。")

            Divider()

            // 6. 页脚:设置 + 退出。
            HStack {
                SettingsLink { Label("设置…", systemImage: "gearshape") }
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 280)
    }

    /// 一行「标签左 · 值右」统计,值用等宽数字。
    @ViewBuilder private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: value)
        }
        .font(.callout)
    }
}

/// 扩展待批准/被停用时的顶部引导条:一句话 + 直达系统设置按钮。橙色(需要用户行动,非错误)。
struct ExtensionApprovalBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).font(.callout)
            Spacer()
            Button("打开系统设置") { SystemSettingsOpener.openExtensionsPane() }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.orange)
    }
}

/// 主动环检测告警条:贴在主窗口顶部。`internal` 供 MainWindow 引用。
struct LoopWarningBanner: View {
    let signature: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("检测到疑似转发环：\(signature) 被反复捕获，已自动将来源进程旁路直连（见 设置 → 内置规则）。若仍反复出现，请检查上游 / 规则是否形成回路。")
                .font(.callout)
            Spacer()
            Button("忽略", action: onDismiss)
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red)
    }
}
