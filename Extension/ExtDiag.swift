import Foundation

/// 扩展侧**文件日志**。排查"会话 connected 但流量不进 provider"时,os_log 在 appidge 身上被系统
/// 当作 `<private>` 隐藏、系统拉起的扩展进程 stderr 又抓不到——唯一能被 app 侧(以及开发者从终端)
/// 读到的诊断通道,是往 App Group 容器写一个纯文本文件。只用于定位 handleNewFlow 是否触发、
/// startProxy / setTunnelNetworkSettings 是否成功。容器路径对 sandbox 扩展与非 sandbox app 都解析到
/// `~/Library/Group Containers/group.com.appidge/`(用 containerURL,不用 UserDefaults 那套)。
enum ExtDiag {
    private static let lock = NSLock()
    private static let url: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.appidge")?
        .appendingPathComponent("ext-diag.log")

    static func log(_ message: String) {
        guard let url else { return }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
