import SwiftUI
import Core
import AppFeature

/// 「应用」页(主窗口顶层分段之一)。目录扫描到的应用逐进程列出,**右键设每进程走法**
/// (走代理 / 直连 / 拦截)——这是「让某个 app 走代理」的入口。右键实际派生一条
/// 「进程 × * × *」规则置顶进规则表(见 Reducer.assignRule)。
/// 「规则」列**从规则表 + 自动旁路层推导**(EffectiveAppRule 完整推导,与扩展路由同一真相):
/// 被自动旁路的进程(回环自愈 / 本地代理发现,如 xray/yunti)显示「放行」——与活动页一致,
/// 绝不显示「代理」(它们在扩展判定里排在规则表之前,catch-all 对它们不生效);其余进程在
/// 「规则」页删掉 / 停用对应规则后,这里立刻回落显示下一条命中(或默认直连)——两页永不失联。
/// 有流量的排前面,其余按名字。
///
/// 由旧 `TrafficPane` 底部的「应用」子分段提升为顶层 tab(避免与「活动」底部重复)。
struct AppsPaneView: View {
    var store: Store
    @State private var selection: Set<MonitoredProcess.ID> = []

    /// 进程的 app 维度有效动作(含自动旁路层:被旁路 → .observe「放行」,同活动页);
    /// nil = 没有任何 host-agnostic 规则命中 → 默认直连。
    private func effectiveAction(_ p: MonitoredProcess) -> ProxyRule {
        EffectiveAppRule.action(
            forProcess: p.id, executablePath: p.executablePath,
            rules: store.state.rules,
            loopAutoExclusions: store.state.loopAutoExclusions,
            dynamicOriginExclusion: store.state.dynamicOriginExclusion
        ) ?? .direct
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
                TableColumn("走法") { p in
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
                        // 有多个代理时「走代理」展开成子菜单选具体上游;只有 0/1 个代理时直接走默认。
                        if servers.isEmpty {
                            Button("走代理") { assign(ids, .proxied) }
                        } else {
                            Menu("走代理") {
                                Button("默认（跟随活动）") { assign(ids, .proxied) }
                                Divider()
                                ForEach(servers) { server in
                                    Button("\(server.host):\(server.port)") {
                                        assign(ids, .proxied, proxyServerID: server.id)
                                    }
                                }
                            }
                        }
                        Button("直连") { assign(ids, .direct) }
                        Button("拦截", role: .destructive) { assign(ids, .block) }
                    }
                }
            }
            // 表格内容字号与其它 tab 的表 + 底部日志统一(caption ≈ 11pt)。
            .font(.caption)
        }
    }

    /// 代理服务器,按主机名排序,供「走代理」子菜单列出。
    private var servers: [ProxyServer] {
        store.state.proxyServers.values.sorted { $0.host.localizedCompare($1.host) == .orderedAscending }
    }

    private func assign(_ ids: Set<MonitoredProcess.ID>, _ rule: ProxyRule, proxyServerID: ProxyServerID? = nil) {
        for id in ids { store.dispatch(.assignRule(processID: id, rule: rule, proxyServerID: proxyServerID)) }
    }
}
