import SwiftUI

/// 品牌图标视图。**直接取运行中 app 的真实图标**（`NSApplication.applicationIconImage`），
/// 而不是引用某个单独的图片资源。
///
/// 为什么这么做：品牌图标换过一次（`c9f452b` 把 `AppIcon.appiconset` 整套换成新版橙底白鸽），
/// 但当时留了一份旧的 `PigeonLogo.imageset`（`8502168` 的蓝紫渐变鸽子）没动，于是「关于」「设置」
/// 「试用弹窗」「引导」四处窗口一直显示旧图标，和 Dock/Finder 里的新图标对不上。
/// 只要这里读的是 app 图标本身，以后再换图标就只需换 `AppIcon.appiconset`，UI 不可能再漂移。
struct BrandIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
