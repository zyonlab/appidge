import SwiftUI
import Core
import AppFeature

/// 「代理环境接管」的呈现:把探测到的 `ProxyEnvironment` 翻成用户能懂的"我们能管哪一层"。
/// 三处复用同一套判定(菜单栏短徽标 / 设置详解 / 首次引导),文案集中在这里,口径一致。
enum ProxyCoverage {
    struct ShortStatus {
        let text: LocalizedStringKey
        let tint: Color
        let symbol: String
    }

    /// 菜单栏短状态:一句话 + 语义色。无绕过层 = 绿(全接管);有 = 橙(部分应用不经 appidge)。
    static func shortStatus(_ env: ProxyEnvironment) -> ShortStatus {
        if env.hasBypassLayer {
            return ShortStatus(
                text: "部分应用走系统代理/环境变量，不经 appidge",
                tint: .orange, symbol: "arrow.triangle.branch"
            )
        }
        return ShortStatus(text: "所有直连出站都由 appidge 按进程接管", tint: .green, symbol: "checkmark.circle")
    }

    /// 系统代理那一行的可读值。
    static func systemProxyText(_ system: ProxyEnvironment.SystemProxy) -> LocalizedStringKey {
        switch system {
        case .none: "未设置（认系统代理的应用会直连 → appidge 接管）"
        case .manual(let summary): "\(summary)"
        case .pac(let url): "PAC 脚本 · \(url)"
        }
    }
}

/// 设置页 / 首次引导共用的详解区块:我们管哪一层 + 探测到什么 + 盲区解释 + 诊断指引。
struct ProxyEnvironmentSection: View {
    let env: ProxyEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            layerExplainer
            Divider()
            detected
            if env.hasBypassLayer {
                Divider()
                bypassAdvice
            }
            Divider()
            diagnosticGuide
        }
        .font(.callout)
    }

    /// 我们能管哪一层——铁律讲清楚。
    private var layerExplainer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("appidge 接管的是「直连出站」流量", systemImage: "arrow.up.forward.circle.fill")
                .font(.callout.weight(.medium))
            Text("应用直接连远程服务器时，appidge 按进程接管、按你的规则转发到配置的上游（如 yunti 的本地端口）。这正是「设了全局代理却不生效」的开发 / AI / 科研工具能被接管的原因——它们本就无视代理配置、直连出网。")
                .foregroundStyle(.secondary)
            Text("appidge 看不到的：应用主动连本地代理端口（127.0.0.1）的流量——认系统代理或读环境变量的应用走这条路，属于回环，系统不会交给 appidge（平台限制）。这类应用其实已被本地代理处理，appidge 无需介入。")
                .foregroundStyle(.secondary)
        }
    }

    /// 探测到的三层。
    private var detected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本机探测").font(.caption).foregroundStyle(.secondary)
            row("系统代理", ProxyCoverage.systemProxyText(env.systemProxy),
                warn: env.systemProxy != .none)
            row("环境变量", env.environmentVariables.isEmpty
                ? "未在 appidge 进程中发现（终端里可能仍有，见下方诊断）"
                : "\(env.environmentVariables.joined(separator: ", "))",
                warn: !env.environmentVariables.isEmpty)
            if !env.extraTunnelInterfaces.isEmpty {
                row("额外网络接口",
                    "\(env.extraTunnelInterfaces.joined(separator: ", "))（可能是其它 VPN/TUN 型代理在 IP 层抢流量）",
                    warn: true)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: LocalizedStringKey, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(warn ? .orange : .green)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).foregroundStyle(.secondary).font(.caption)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 有绕过层时的建议:关掉系统级规则代理,让 appidge 统一接管、消除盲区。
    private var bypassAdvice: some View {
        Label {
            Text("检测到会绕过 appidge 的代理层。若希望**所有**应用都由 appidge 按进程接管、在活动栏可见：把 yunti / Clash 等的「系统规则模式」关掉，只保留它的本地代理端口作为 appidge 的上游。这样每个应用都直连出站 → appidge 接管转发，没有回环盲区。")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
        }
    }

    /// 「某个应用没走 appidge / 看不到」怎么自查。
    private var diagnosticGuide: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("某个应用没走 appidge / 看不到？").font(.callout.weight(.medium))
            bullet("它可能认了系统代理或读了环境变量，直接连本地端口（回环）——appidge 看不到这类流量。终端里测：`env | grep -i proxy` 查有没有 HTTP_PROXY；有就 `unset HTTP_PROXY HTTPS_PROXY ALL_PROXY` 后再跑，appidge 就能接管并显示它。")
            bullet("它的流量可能已被 yunti 等聚合——活动栏里显示成 xray（本地代理出站），而不是原始应用名。关掉上游的系统规则模式即可让应用以自己的身份出现。")
            bullet("它可能走 QUIC/UDP（HTTP/3）——appidge 默认拦截代理进程的 UDP 逼其回落 TCP；个别工具异常时可在「UDP / QUIC」里改「直连放行」。")
            bullet("确认扩展在跑：状态栏是「引擎正常」、系统扩展「已接管」。")
        }
        .foregroundStyle(.secondary)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
