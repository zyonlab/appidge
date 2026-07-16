import Foundation

/// 扩展侧**诊断日志**。排查"会话 connected 但流量不进 provider"/"配置没生效还是没拦截到"时,
/// os_log 在 appidge 身上被系统当作 `<private>` 隐藏、系统拉起的扩展进程 stderr 又抓不到——
/// 唯一能被开发者从终端读到的诊断通道。
///
/// **v2:改用 App Group `UserDefaults`(同 `AppGroupAppSideTransport` 那套已验证能跨
/// app↔扩展工作的机制),不再用 `containerURL` 写文件**——旧版一直写不出东西
/// (`containerURL(forSecurityApplicationGroupIdentifier:)` 在这台机器的沙盒扩展里返回 nil 或
/// 写入静默失败,`ext-diag.log` 从未真正出现过)。
///
/// **v3:内存缓冲 + 节流落盘**。v2 的 `log()` 每次调用都 read-modify-write 整个 2000 行数组
/// 进 UserDefaults(每次一份完整 plist 序列化 + 跨进程同步)——而 `handleNewTCPFlow`/
/// `blockOrAllowUDPFlow` **每条 flow** 都要记一笔,Chrome 一类应用每秒上百条新连接时,这个
/// 热路径开销本身就足以把扩展拖垮(catch-all 接管下扩展一垮 = 全系统断网)。现在 `log()` 只
/// append 内存缓冲(纳秒级),每 `flushInterval` 秒合并落盘一次;代价是扩展进程崩溃时最多丢
/// 最后 1 秒的日志——诊断日志可以接受。
///
/// 滚动缓冲(超过 `maxLines` 丢最旧),避免无限增长。终端读取:
/// `defaults read group.com.appidge ExtDiag.log`
enum ExtDiag {
    private static let lock = NSLock()
    private static let appGroup = "group.com.appidge"
    private static let key = "ExtDiag.log"
    private static let maxLines = 2000
    private static let flushInterval: TimeInterval = 1.0

    // 全部经 `lock` 访问(见 log/drainForFlush),`nonisolated(unsafe)` 显式承担这份线程安全
    // ——同 `ProxyExtensionProvider.configLock` 一贯的"锁 + 手动担保"写法。
    nonisolated(unsafe) private static var buffer: [String] = []
    nonisolated(unsafe) private static var flushScheduled = false
    private static let flushQueue = DispatchQueue(label: "com.appidge.extdiag.flush", qos: .utility)

    static func log(_ message: String) {
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)"
        let shouldSchedule: Bool = lock.withLock {
            buffer.append(line)
            if buffer.count > maxLines {
                buffer.removeFirst(buffer.count - maxLines)
            }
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
        if shouldSchedule {
            flushQueue.asyncAfter(deadline: .now() + flushInterval) { flush() }
        }
    }

    private static func flush() {
        let pending: [String] = lock.withLock {
            flushScheduled = false
            let lines = buffer
            buffer.removeAll(keepingCapacity: true)
            return lines
        }
        guard !pending.isEmpty, let defaults = UserDefaults(suiteName: appGroup) else { return }
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append(contentsOf: pending)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        defaults.set(lines, forKey: key)
    }
}
