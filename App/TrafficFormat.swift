import Foundation

/// 流量数字的展示格式化,菜单栏和活动监视器共用一处。用系统 `ByteCountFormatter`(binary
/// 风格,KB/MB/…),速率在其后缀 `/s`。纯展示,无状态。
enum TrafficFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .binary)
    }

    /// 每秒字节数格式化成「1.2 MB/s」。负值(理论不该出现)夹到 0。
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }

    /// 存活时长格式化成 Proxifier 风格的 `01:34` / `1:02:33`(小时只在需要时出现)。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
