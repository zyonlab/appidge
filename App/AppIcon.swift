import SwiftUI
import AppKit

/// 应用真实图标的内存缓存:从可执行/bundle 路径用 `NSWorkspace` 取一次、缓存复用。
/// 只在主 actor 访问(表格行 body 都在主 actor),缓存是 `@MainActor` 隔离的普通字典——
/// 不共享跨线程可变状态,不触发 Swift 6 并发告警,也不必上 `NSCache`。
/// 应用数量有界(扫描到的已安装应用,几十到数百),字典不做淘汰。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let hit = cache[path] { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

/// 表格一行里的「图标 + 应用名」。图标取真实 app 图标(16pt),取不到(路径缺失/不存在)
/// 回落到通用 `app.dashed`。连接表与「应用」表共用,呈现一致。
struct AppLabel: View {
    let name: String
    let path: String?

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 16, height: 16)
            Text(name).lineLimit(1)
        }
    }

    @ViewBuilder private var icon: some View {
        if let path, let image = AppIconCache.image(path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}
