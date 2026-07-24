import SwiftUI
import Core
import AppFeature
import Sparkle

/// 「关于 Appidge」窗口（App 菜单 → 关于）。版本 + 构建号、检查更新、四条法务链接、购买入口。
/// 授权/更新 UI 故障绝不阻塞——本视图只开 URL / 触发 Sparkle / dispatch 购买，不改共享状态、不发业务网络。
struct AboutView: View {
    var store: Store
    /// 由 App 持有的 `SPUStandardUpdaterController.updater` 传入，「检查更新…」据此手动触发一次。
    var updater: SPUUpdater

    var body: some View {
        VStack(spacing: 14) {
            Image("PigeonLogo")
                .resizable().scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            Text("Appidge").font(.title2).bold()
            Text("版本 \(Self.shortVersion)（构建 \(Self.buildVersion)）")
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("按进程接管网络去向的 macOS 透明代理。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("检查更新…") { updater.checkForUpdates() }

            // 四条法务链接（与帮助菜单镜像同一组）。
            HStack(spacing: 14) {
                ForEach(AppLinks.LegalPage.allCases) { page in
                    Button(page.menuTitle) { Self.open(AppLinks.legalURL(page)) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)

            if !LicenseBuildConfig.checkoutURL.isEmpty {
                Button("购买许可证") {
                    store.dispatch(.licensePurchaseRequested(checkoutURL: LicenseBuildConfig.checkoutURL))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 360)
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 「管理许可证」窗口（App 菜单 → 管理许可证…，及启动弹窗「输入许可证…」）。用户**主动**打开的
/// 授权入口。复用设置里的 `LicenseSettingsView`（同一套只读 State + dispatch 逻辑，含试用态展示、
/// 凭证输入激活、购买），避免重复实现。授权服务故障不影响此窗口以外的任何路径。
struct ManageLicenseView: View {
    var store: Store

    var body: some View {
        Form {
            LicenseSettingsView(store: store)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 400)
        .navigationTitle("管理许可证")
    }
}
