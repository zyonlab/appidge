import Foundation

/// 扩展侧**诊断日志**。排查"会话 connected 但流量不进 provider"/"配置没生效还是没拦截到"时,
/// os_log 在 appidge 身上被系统当作 `<private>` 隐藏、系统拉起的扩展进程 stderr 又抓不到——
/// 唯一能被开发者从终端读到的诊断通道。
///
/// **v2:改用 App Group `UserDefaults`(同 `NEFlowTransport.deliver`/`AppGroupAppSideTransport`
/// 那套已验证能跨 app↔扩展工作的机制),不再用 `containerURL` 写文件**——旧版一直写不出东西
/// (`containerURL(forSecurityApplicationGroupIdentifier:)` 在这台机器的沙盒扩展里返回 nil 或
/// 写入静默失败,`ext-diag.log` 从未真正出现过),而 `UserDefaults(suiteName:)` 已经是 IPC
/// 消息传递本身依赖的通道,已经反复验证过真的能跨进程读写。
///
/// 滚动缓冲(超过 `maxLines` 丢最旧),避免无限增长。终端读取:
/// `defaults read group.com.appidge ExtDiag.log`
enum ExtDiag {
    private static let lock = NSLock()
    private static let appGroup = "group.com.appidge"
    private static let key = "ExtDiag.log"
    private static let maxLines = 2000

    static func log(_ message: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)"
        lock.withLock {
            var lines = defaults.stringArray(forKey: key) ?? []
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            defaults.set(lines, forKey: key)
        }
    }
}
