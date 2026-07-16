import Darwin
import Foundation

/// 从 `NEFlowMetaData.sourceAppAuditToken` 解出真实 PID,再用 `proc_pidpath` 查它的可执行文件
/// 路径——`sourceAppSigningIdentifier`(签名标识)之外的第二个来源身份信号。
///
/// 为什么需要它:未签名/ad-hoc 签名的本地代理软件(如 xray/yunti)常常不止一个进程,
/// `sourceAppSigningIdentifier` 对同一个软件的不同进程可能不一致(真机验证实测:监听配置端口的
/// 那个报 `com.example.yunti`,它另一个做实际出站连接的进程却报成 `a.out`)——单靠签名标识
/// 排除只精确匹配了其中一个,见 PROGRESS.md 记录的那次真实回归。可执行文件路径更稳:同一个软件
/// 安装的多个进程通常共享同一个(或高度相关的)可执行文件。这个技巧照抄自开源的 Proxifier 替代品
/// ProxyBridge(github.com/InterceptSuite/ProxyBridge,`AppProxyProvider.swift`)。
///
/// 带 PID→路径的小缓存(同 flow 的多次读写不会重复触发系统调用);缓存满了整体清空重建
/// (进程量级不大,懒得做 LRU)。
enum ProcessPathResolver {
    private static let lock = NSLock()
    // `nonisolated(unsafe)`:这个全局可变字典完全由上面那把 NSLock 保护(每次读写都在
    // lock/unlock 之间),我们自己担起这份线程安全——同 `NEFlowTransport`/`ProxyExtensionProvider`
    // 里其它 `@unchecked Sendable`/锁保护全局态的既有先例,不是绕过检查。
    private static nonisolated(unsafe) var cache: [pid_t: String] = [:]
    private static let cacheMaxSize = 512

    /// `auditToken` 是 `NEFlowMetaData.sourceAppAuditToken`(`Data?`,macOS 10.15+)。
    /// 解不出 PID、或 `proc_pidpath` 查不到(进程已退出的竞态、权限不足)一律返回 nil。
    static func executablePath(from auditToken: Data?) -> String? {
        guard let auditToken, let pid = pid(fromAuditToken: auditToken), pid > 0 else { return nil }

        lock.lock()
        if let cached = cache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var buffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return nil }
        // `String(cString:)` on `[Int8]` is deprecated；手动截到 NUL 再按 UTF8 解码。
        // 本仓库自定义 lint 规则要 `String(bytes:encoding:)` 而非 `String(decoding:as:)`。
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }

        lock.lock()
        if cache.count >= cacheMaxSize { cache.removeAll(keepingCapacity: true) }
        cache[pid] = path
        lock.unlock()
        return path
    }

    /// 从可执行文件路径取最后一段路径分量,作为人类可读的进程名——比如
    /// `/Users/admin/.yunti/xray-core/xray` → `xray`,比未签名进程的 `sourceAppSigningIdentifier`
    /// (常是无意义的 `a.out`)可读得多。路径为空/解不出最后一段时返回 nil。
    static func displayName(fromExecutablePath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// `audit_token_t` 是 8 个 `UInt32`;PID 按 Darwin 惯例在下标 5(ProxyBridge 与多个开源
    /// 实现一致的读法,不是我们自己猜的)。长度不对就是意外形态,不强行解析。
    private static func pid(fromAuditToken data: Data) -> pid_t? {
        guard data.count == MemoryLayout<audit_token_t>.size else { return nil }
        return data.withUnsafeBytes { ptr -> pid_t in
            guard let base = ptr.baseAddress else { return 0 }
            let token = base.assumingMemoryBound(to: UInt32.self)
            return pid_t(token[5])
        }
    }
}
