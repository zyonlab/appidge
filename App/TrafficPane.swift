import SwiftUI
import Core
import AppFeature

/// 主窗口底部面板:流量(全局累计 + 实时速率 + 最活跃)/ 统计(每进程 Table)。对齐 Proxifier 底部的
/// Traffic / Statistics 标签页。速率不用定时器——每当流量批量到达就用两次快照的真实间隔算一次。
struct TrafficPane: View {
    var store: Store
    @State private var tab: Tab = .traffic

    enum Tab: String, CaseIterable, Identifiable { case traffic = "流量", apps = "应用"; var id: String { rawValue } }

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
            case .apps: AppRoutingTable(store: store)
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

/// 「应用」表:目录扫描到的应用,**右键设每进程规则**(走代理 / 直连 / 拦截)——这是「让某个 app
/// 走代理」的入口。右键实际派生一条「进程 × * × *」规则置顶进规则表(见 Reducer.assignRule)。
/// 「规则」列**从规则表推导**(EffectiveAppRule,与扩展路由同一真相):在「规则」页删掉/停用
/// 对应规则,这里立刻回落显示下一条命中(或默认直连)——两页永不失联。有流量的排前面,其余按名字。
private struct AppRoutingTable: View {
    var store: Store
    @State private var selection: Set<MonitoredProcess.ID> = []

    /// 进程在当前规则表下的 app 维度有效动作;nil = 没有任何 host-agnostic 规则命中 → 默认直连。
    private func effectiveAction(_ p: MonitoredProcess) -> ProxyRule {
        EffectiveAppRule.action(forProcess: p.id, rules: store.state.rules) ?? .direct
    }

    private var processes: [MonitoredProcess] {
        store.state.processes.values.sorted {
            let a = $0.stats.bytesUp &+ $0.stats.bytesDown
            let b = $1.stats.bytesUp &+ $1.stats.bytesDown
            return a != b ? a > b : $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        if processes.isEmpty {
            ContentUnavailableView(
                "还没有扫描到应用",
                systemImage: "app.badge",
                description: Text("启动时会扫描已安装的应用；右键某个应用可设它走代理 / 直连 / 拦截。")
            )
        } else {
            Table(processes, selection: $selection) {
                TableColumn("应用") { p in AppLabel(name: p.displayName, path: p.executablePath) }
                TableColumn("规则") { p in
                    // 应用级规则用规则表同款文案(「代理/直连/拦截/观测」)——RouteText.label 是
                    // 连接行专用的,proxyKind 为 nil 时会显示成「代理(回落直连)」,放这里是误导。
                    let action = effectiveAction(p)
                    Text(RuleActionStyle.label(action)).foregroundStyle(RuleActionStyle.color(action))
                }.width(64)
                // 实时速率(本批瞬时,上+下合计):当前在吃带宽的应用一眼可见——活跃(>0)高亮,空闲变灰。
                // 悬停看上/下分向。答「现在谁在吃带宽」,是 Activity Monitor 只给累计所答不了的。
                TableColumn("速率") { p in
                    let total = p.rateDownPerSec + p.rateUpPerSec
                    Text(TrafficFormat.rate(total))
                        .monospacedDigit()
                        .foregroundStyle(total > 0 ? .primary : .secondary)
                        .help("↓ \(TrafficFormat.rate(p.rateDownPerSec))   ↑ \(TrafficFormat.rate(p.rateUpPerSec))")
                }.width(92)
                TableColumn("累计 ↑") { p in Text(TrafficFormat.bytes(p.stats.bytesUp)).monospacedDigit() }.width(80)
                TableColumn("累计 ↓") { p in Text(TrafficFormat.bytes(p.stats.bytesDown)).monospacedDigit() }.width(80)
            }
            .contextMenu(forSelectionType: MonitoredProcess.ID.self) { ids in
                if !ids.isEmpty {
                    Section("此应用（\(ids.count) 个）") {
                        Button("走代理") { assign(ids, .proxied) }
                        Button("直连") { assign(ids, .direct) }
                        Button("拦截", role: .destructive) { assign(ids, .block) }
                    }
                }
            }
        }
    }

    private func assign(_ ids: Set<MonitoredProcess.ID>, _ rule: ProxyRule) {
        for id in ids { store.dispatch(.assignRule(processID: id, rule: rule)) }
    }
}
