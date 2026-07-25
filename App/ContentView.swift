import SwiftUI
import Core
import AppFeature
import Sparkle

/// 主界面已改为 Console 风的 `MainWindow`(见 MainWindow.swift):单窗口连接监视 + 底部流量 + 状态栏,
/// 配置弹 sheet、全局设置进 `Settings` 场景。这里只保留仍被复用的两个小件:菜单栏内容 + 环告警条。
/// (旧的七 tab —— 目录/规则/规则表/活动监视器/连接 —— 的职责已合进主窗口 + sheets + Settings。)

/// 菜单栏下拉:一眼看状态的迷你仪表盘(对齐 iStat Menus / Little Snitch 的状态菜单)——
/// 引擎/扩展健康 · 全局吞吐 · 活动连接数 · 流量占用 Top 5 · 全局开关 · 设置/退出。
/// 只读 `store.state`、只 `dispatch(action)`,不持任何本地状态(对齐单向数据流)。
struct MenuBarView: View {
    var store: Store
    /// 与主窗口共享的分段选中态:点「打开入口」即改它,主窗口(新开或已在)据此切到对应 tab。
    var tabSelection: MainTabSelection
    /// Sparkle 自动升级器:由 App 持有 `SPUStandardUpdaterController` 并把其 `updater` 传进来,
    /// 「检查更新…」菜单项据此手动触发一次检查(自动检查由 controller 后台按计划进行)。
    var updater: SPUUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    /// 状态行的呈现要素:SF Symbol + 语义色 + 文案(+ 可选 tooltip)。永不只靠颜色——
    /// 符号与文案同时表意,色盲/高对比场景也读得懂。
    private struct StatusPresentation {
        let symbol: String
        let tint: Color
        let text: LocalizedStringKey
        let help: LocalizedStringKey?
    }

    /// 先看扩展装没装(未接入/待批准/安装中/未安装都得先说清,否则"引擎正常"会误导),
    /// 装上了(`.active`)再看引擎健康度。与底部状态栏(`StatusBar`)同一套判定,换成菜单里
    /// 更直观的符号呈现。绿=已接管,橙=待批准/安装中,红=未安装/异常,次要灰=未接入。
    private var status: StatusPresentation {
        guard store.state.isLicenseActive else {
            return StatusPresentation(
                symbol: "lock.fill",
                tint: .orange,
                text: "未授权 · 接管已停止",
                help: "激活许可证后才会启动网络接管与开放规则编辑。"
            )
        }
        switch store.state.extensionActivation {
        case .activePendingReboot:
            return StatusPresentation(symbol: "arrow.clockwise.circle.fill", tint: .orange,
                                      text: "新版本待重启生效", help: "当前仍由旧版本扩展接管，功能不受影响。")
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
                                      text: "扩展未安装", help: "\(reason)")
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

            // 5. 打开入口:直达主窗口四个分段(活动 ⌘1 / 应用 ⌘2 / 规则 ⌘3 / 代理 ⌘4)。
            //    点一下=设置共享分段 + 打开/前置主窗口(见 open(_:));菜单里就能把主窗口切到目标页。
            Text("打开")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(MainWindow.MainTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    open(tab)
                } label: {
                    Label(tab.title, systemImage: Self.tabSymbol(tab))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .font(.callout)
            }

            Divider()

            // 6. 紧急恢复:浏览器等断网时的一键出口(停止会话 + 移除代理配置,全部应用立即恢复
            //    原生直连,无需重启电脑)。放菜单栏是因为主窗口此时可能根本打不开/没人想找设置。
            Button {
                TransparentProxyController.reset()
            } label: {
                Label("紧急恢复直连（重置接管）", systemImage: "exclamationmark.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .help("停止接管并移除系统里的代理配置——浏览器等应用断网时的恢复出口，无需重启电脑。重启 app 可重新开启接管。")

            Divider()

            // 6b. 检查更新:手动触发一次 Sparkle 检查(后台自动检查由 SPUStandardUpdaterController 负责)。
            //     升级下载后会退出重装,新扩展经 app 侧版本握手重绑会话(见 AppidgeApp.maybeHealStaleBinding)。
            Button {
                updater.checkForUpdates()
            } label: {
                Label("检查更新…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .font(.callout)

            Divider()

            // 7. 页脚:设置 + 退出。
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

    /// 「打开入口」点击:先把共享分段切到目标 tab(主窗口若已开着会立刻跟着切),再打开/前置主窗口。
    /// `openWindow(id:)` 对已存在的 "main" 窗口是前置、不存在则新建;`NSApp.activate` 保证 app 抢到前台
    /// (菜单栏 app 常不在前台,只 openWindow 可能只在后台恢复窗口)。顺序:先设状态,后展示窗口。
    private func open(_ tab: MainWindow.MainTab) {
        tabSelection.section = tab
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 分段对应的 SF Symbol:菜单入口里符号 + 文案同时表意,不只靠文字。
    private static func tabSymbol(_ tab: MainWindow.MainTab) -> String {
        switch tab {
        case .activity: "dot.radiowaves.left.and.right"
        case .apps: "app.badge"
        case .rules: "list.bullet.rectangle"
        case .proxies: "server.rack"
        }
    }

    /// 一行「标签左 · 值右」统计,值用等宽数字。
    @ViewBuilder private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
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
    let text: LocalizedStringKey

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
