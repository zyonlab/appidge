import SwiftUI
import Core
import AppFeature

/// 试用相位的 UI 适配层——**唯一**集中匹配 Core 的 `.trial(daysLeft:)` / `.trialExpired`
/// 的地方（跨 agent 硬契约见任务说明）。其它视图一律消费本枚举，避免到处重复 pattern-match，
/// 也让「待 Core 落地」的集成点收敛成这一个 `from(_:)`。
///
/// 契约：Core 的 `isLicenseActive` 在 `.trial` 期为 true（可用全功能）、`.trialExpired` 为 false
/// （落 LicenseGateView）。据此：`.trial` → 主窗口顶部细横幅 + 启动弹窗（可继续）；
/// `.trialExpired` → 启动弹窗（无继续）+ 授权门。
enum TrialState: Equatable {
    case trial(daysLeft: Int)
    case expired
    case notInTrial

    /// 从 Core 相位映射。**此处引用 `.trial` / `.trialExpired`，本 worktree 内待 Core 落地后编译。**
    static func from(_ phase: LicensePhase) -> TrialState {
        switch phase {
        case .trial(let daysLeft): return .trial(daysLeft: daysLeft)
        case .trialExpired: return .expired
        default: return .notInTrial
        }
    }
}

/// 主窗口顶部**细横幅**：试用中显示「剩 N 天 · 购买」，点按打开「管理许可证」窗口。
/// 克制、单行；菜单栏（MenuBarExtra）不加倒计时（见任务约束）。已授权时调用方不构建它。
struct TrialBanner: View {
    let daysLeft: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                Text("剩 \(daysLeft) 天 · 购买")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点按管理许可证或购买。")
        .accessibilityLabel(Text("剩 \(daysLeft) 天 · 购买"))
    }
}

/// 未购买时的**每次启动弹窗**（对齐 Proxifier 每次启动提示，不做「今天不再提示」）。
/// 试用中：Buy / Enter License / Continue（继续显眼、按 Return 即继续，降低打扰）。
/// 已到期：Buy / Enter License（无继续）。授权/试用 UI 故障绝不阻塞诊断与帮助——
/// 本视图只 dispatch 购买、或开管理窗口，不发网络、不改共享状态。
struct TrialPromptView: View {
    var store: Store
    let trial: TrialState
    /// 「继续试用」回调（关闭弹窗，交回主窗口）。
    let onContinue: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image("PigeonLogo")
                .resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            switch trial {
            case .trial(let days):
                Text("试用中 — 剩 \(days) 天").font(.title2).bold()
                Text("购买后可解除试用限制并支持后续更新。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(showContinue: true)
            case .expired:
                Text("试用已结束").font(.title2).bold()
                Text("试用期已结束。购买许可证后可继续使用全部功能。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(showContinue: false)
            case .notInTrial:
                // 已购买/吊销等——不应到达（调用方按相位决定是否弹）；给一个安全出口。
                Button("继续") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    @ViewBuilder
    private func buttons(showContinue: Bool) -> some View {
        VStack(spacing: 10) {
            if !LicenseBuildConfig.checkoutURL.isEmpty {
                Button("购买许可证") {
                    store.dispatch(.licensePurchaseRequested(checkoutURL: LicenseBuildConfig.checkoutURL))
                }
                .buttonStyle(.borderedProminent)
            }
            Button("输入许可证…") {
                openWindow(id: AppWindowID.manageLicense)
                close()
            }
            if showContinue {
                // 继续显眼且是默认动作：按 Return 直接继续，尽量少打扰。
                Button("继续试用") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func close() {
        onContinue()
        dismiss()
    }
}
