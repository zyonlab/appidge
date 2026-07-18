import SwiftUI
import Core
import AppFeature

/// 首次启动引导：说清 app 干什么、能管哪一层，一个按钮触发系统扩展激活并把引导标成已完成。
/// 跟其它面板一样，UI 只读 store.state、只 dispatch(Action)。
///
/// 排版按 Apple HIG：一句承诺 → 能管/管不到两张平白卡 → 技术细节收进可展开的「详情」，
/// 不再是一屏术语墙。只用系统默认控件，跟 App/ContentView.swift 的朴素风格保持一致。
struct OnboardingView: View {
    var store: Store

    var body: some View {
        VStack(spacing: 20) {
            header
            capabilityCards
            details
            startButton
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }

    /// 图标 + 标题 + 一句平白说明。
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("appidge · 按进程代理")
                .font(.title2)
                .bold()

            Text("为每个应用单独指定走代理或直连。代理异常时自动回退直连。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }

    /// 两张平白能力卡：能接管 / 管不到。绿勾 = 能管，橙 info = 盲区。
    private var capabilityCards: some View {
        VStack(spacing: 8) {
            capabilityCard(
                symbol: "checkmark.circle.fill", tint: .green,
                title: "能接管：直连出网的应用",
                detail: "多数 App、命令行、开发工具，包括无视全局代理的那些。"
            )
            capabilityCard(
                symbol: "info.circle.fill", tint: .orange,
                title: "管不到：连本地代理端口的应用",
                detail: "少数应用自己连 127.0.0.1，那部分已由别的代理处理。"
            )
        }
        .frame(maxWidth: 420)
    }

    private func capabilityCard(symbol: String, tint: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 技术细节降一层：本机环境探测 + 诊断要点，各收进一个可折叠 DisclosureGroup。
    private var details: some View {
        let env = store.state.proxyEnvironment
        return VStack(spacing: 8) {
            DisclosureGroup(env.hasBypassLayer ? "环境检查：部分应用不经 appidge" : "环境检查通过") {
                environmentDetail(env)
                    .padding(.top, 6)
            }
            DisclosureGroup("有应用没走 appidge？") {
                DiagnosticGuideView()
                    .padding(.top, 6)
            }
        }
        .font(.callout)
        .frame(maxWidth: 420)
    }

    /// 本机探测：复用 ProxyEnvironmentSection 的 row 口径，精简为「系统代理 / 环境变量 / 额外接口」。
    private func environmentDetail(_ env: ProxyEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("系统代理", ProxyCoverage.systemProxyText(env.systemProxy),
                      warn: env.systemProxy != .none)
            detailRow("环境变量", env.environmentVariables.isEmpty
                      ? "未在 appidge 进程中发现（终端里可能仍有，见诊断）"
                      : "\(env.environmentVariables.joined(separator: ", "))",
                      warn: !env.environmentVariables.isEmpty)
            if !env.extraTunnelInterfaces.isEmpty {
                detailRow("额外网络接口",
                          "\(env.extraTunnelInterfaces.joined(separator: ", "))（可能是其它 VPN/TUN 型代理在 IP 层抢流量）",
                          warn: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: LocalizedStringKey, warn: Bool) -> some View {
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

    /// 「开始使用」——动作与现状完全一致：激活系统扩展 + 标记引导完成 + 持久化。
    private var startButton: some View {
        Button("开始使用") {
            SystemExtensionActivator.shared.activate()
            store.dispatch(.onboardingCompleted)
            Task {
                await FilePersistenceStore().save(PersistedConfiguration(from: store.state))
            }
        }
        .buttonStyle(.borderedProminent)
    }
}

/// 诊断要点：「某个应用没走 appidge / 看不到」怎么自查。从 ProxyEnvironmentSection 的
/// diagnosticGuide 抽出同口径的条目，供首次引导的可折叠区复用。
private struct DiagnosticGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bullet("它可能认了系统代理或读了环境变量，直接连本地端口（回环）——appidge 看不到这类流量。终端里测：`env | grep -i proxy` 查有没有 HTTP_PROXY；有就 `unset HTTP_PROXY HTTPS_PROXY ALL_PROXY` 后再跑，appidge 就能接管并显示它。")
            bullet("它的流量可能已被 yunti 等聚合——活动栏里显示成 xray（本地代理出站），而不是原始应用名。关掉上游的系统规则模式即可让应用以自己的身份出现。")
            bullet("它可能走 QUIC/UDP（HTTP/3）——appidge 默认拦截代理进程的 UDP 逼其回落 TCP；个别工具异常时可在「UDP / QUIC」里改「直连放行」。")
            bullet("确认扩展在跑：状态栏是「引擎正常」、系统扩展「已接管」。")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
