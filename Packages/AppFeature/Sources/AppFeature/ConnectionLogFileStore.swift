import Foundation
import Core

/// 连接日志的磁盘持久化存储——**滚动 JSONL**(每行一条 `Core.ConnectionLogEntry` 的紧凑 JSON)。
///
/// 背景:每条 TCP 连接的日志目前只活在内存里(`AppState` 的 500 条环形缓冲),重启即丢。
/// 这个 store 把最近的连接落到磁盘,让它跨重启存活,同时兼当一份 Verbose 式的磁盘日志。
///
/// 设计与 `FilePersistenceStore` 同源:一个 `actor` 串行化磁盘读写,默认落在
/// `~/Library/Application Support/appidge/connections.log.jsonl`,可注入自定义 URL 供测试。
/// **一切磁盘错误都静默吞掉**——这是缓存,不是权威数据源,读不到就当空,绝不做崩溃来源。
///
/// 为什么是 JSONL 而不是一个大 JSON 数组:追加一条日志只需 `seekToEnd + write` 一行,
/// 不必读回整个数组再整体重写;解析时逐行独立解码,坏一行只丢一行,不会带崩整份文件。
public actor ConnectionLogFileStore {
    private let fileURL: URL
    /// 文件行数上限。追加后一旦越过就重写,只保留最后这么多行,防止无界增长。
    private let maxLines: Int

    /// 默认落盘位置:`~/Library/Application Support/appidge/connections.log.jsonl`。
    /// 与 `FilePersistenceStore.defaultFileURL` 同目录,仅文件名不同。
    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("appidge", isDirectory: true)
            .appendingPathComponent("connections.log.jsonl")
    }

    /// - Parameters:
    ///   - fileURL: 日志文件路径,默认生产路径;测试传入临时文件。
    ///   - maxLines: 文件保留的最大行数,越过即滚动丢最旧的行。至少为 1。
    public init(fileURL: URL = ConnectionLogFileStore.defaultFileURL, maxLines: Int = 2000) {
        self.fileURL = fileURL
        self.maxLines = max(1, maxLines)
    }

    /// 追加一条日志:编码成一行紧凑 JSON + 换行,`seekToEnd` 续写到文件尾。
    /// 默认 `JSONEncoder` 输出无内部换行,天然满足「一条 entry 恰好一行」的 JSONL 约束。
    /// 追加后检查行数,越过 `maxLines` 就滚动。全程错误静默,永不抛。
    public func append(_ entry: Core.ConnectionLogEntry) async {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var payload = data
        payload.append(0x0A)   // '\n'

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: fileURL, options: .atomic)
        }

        rotateIfNeeded()
    }

    /// 读取最后 `limit` 条日志,按 oldest→newest 返回。
    /// 文件缺失 → `[]`;坏行逐行跳过(解不动就丢),绝不因一行脏数据崩掉整次读取。
    public func loadRecent(limit: Int) async -> [Core.ConnectionLogEntry] {
        guard limit > 0 else { return [] }
        let decoder = JSONDecoder()
        return readLines().suffix(limit).compactMap { line in
            try? decoder.decode(Core.ConnectionLogEntry.self, from: Data(line.utf8))
        }
    }

    // MARK: - 私有

    /// 读回文件并按换行切成行。缺文件或非 UTF-8 → 空。空行(含尾随换行产生的空段)一并略去。
    /// 注意:用 `String(bytes:encoding:)` 而非 `String(decoding:as:)`(仓库自定义 lint 规则)。
    private func readLines() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(bytes: data, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 行数越过上限时,只保留最后 `maxLines` 行,原子重写整份文件。滚动按「行」进行、
    /// 不看内容是否合法——坏行也照常参与保留/淘汰,读取端负责跳过它们。
    private func rotateIfNeeded() {
        let lines = readLines()
        guard lines.count > maxLines else { return }
        let kept = lines.suffix(maxLines)
        let joined = kept.joined(separator: "\n") + "\n"
        try? Data(joined.utf8).write(to: fileURL, options: .atomic)
    }
}
