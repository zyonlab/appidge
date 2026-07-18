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
