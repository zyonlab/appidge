import SwiftUI
import Core
import AppFeature

/// App 菜单命令（对齐 macOS HIG）：
/// - 应用菜单「关于本机」之后追加 `关于 Appidge…` / `管理许可证…`（授权的**主动**入口）。
/// - 帮助菜单替换为四条法务链接 + 购买（与「关于」窗口镜像同一组）。
/// 只开窗 / 开 URL / dispatch 购买，不持业务状态、不发网络。授权服务故障不影响这些入口本身。
struct AppMenuCommands: Commands {
    var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // `replacing:` 而非 `after:`——后者是在系统自带的「关于 appidge」**之后追加**一条，
        // 结果应用菜单里出现两个「关于」。替换掉系统项，只保留我们这个（含版本/更新/法务/购买）。
        CommandGroup(replacing: .appInfo) {
            Button("关于 Appidge…") { openWindow(id: AppWindowID.about) }
            Button("管理许可证…") { openWindow(id: AppWindowID.manageLicense) }
        }

        CommandGroup(replacing: .help) {
            ForEach(AppLinks.LegalPage.allCases) { page in
                Button(page.menuTitle) { open(AppLinks.legalURL(page)) }
            }
            Divider()
            if !LicenseBuildConfig.checkoutURL.isEmpty {
                Button("购买许可证") {
                    store.dispatch(.licensePurchaseRequested(checkoutURL: LicenseBuildConfig.checkoutURL))
                }
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
