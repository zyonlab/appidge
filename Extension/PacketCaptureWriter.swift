import Foundation

/// 逐连接抓包写入器:把一条连接的上下行原始字节追加进一个 `.dmp` 文件(写进 App Group 容器的
/// `captures/`,app 可读)。默认不启用(见抓包开关)。格式:每块 `[方向 1B: 0=出站,1=入站]`
/// `[长度 4B 大端][原始字节]`——够离线重放/分析,不追求兼容 Proxifier 的私有 .dmp 格式。
///
/// pump 回调从不同队列并发写,用锁保护;`@unchecked Sendable` 显式担这份线程安全。
final class PacketCaptureWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    /// 打开(创建)`directory/fileName` 供写入。目录不存在会创建;创建/打开失败返回 nil
    /// (抓包是可选诊断,失败就当没开,绝不影响转发)。
    init?(directory: URL, fileName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    func write(outbound: Bool, _ data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data([outbound ? 0 : 1])
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
        chunk.append(data)
        lock.withLock { try? handle.write(contentsOf: chunk) }
    }

    /// 关闭文件句柄。可安全多次调用(第二次 close 抛错被 try? 吞掉)。
    func close() {
        lock.withLock { try? handle.close() }
    }

    /// 从进程标识 + 目标 + 时间戳拼一个清洗过的 `.dmp` 文件名(非字母数字换成下划线)。
    static func fileName(processID: String, host: String, port: UInt16, at timestamp: Double) -> String {
        let raw = "\(processID)_\(host)_\(port)_\(Int(timestamp))"
        let safe = String(raw.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" })
        return safe + ".dmp"
    }

    /// 为一条连接在 App Group 容器的 `captures/` 下建一个 `.dmp` 写入器;拿不到容器则 nil。
    static func forConnection(
        appGroup: String, processID: String, host: String, port: UInt16, at timestamp: Double
    ) -> PacketCaptureWriter? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        return PacketCaptureWriter(
            directory: container.appendingPathComponent("captures", isDirectory: true),
            fileName: fileName(processID: processID, host: host, port: port, at: timestamp)
        )
    }
}
