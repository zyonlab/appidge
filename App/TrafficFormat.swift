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
}
