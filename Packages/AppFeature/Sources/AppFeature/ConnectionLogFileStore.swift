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
    /// 文件行数上限。越过后裁回,只保留最后这么多行,防止无界增长。
    private let maxLines: Int
    /// 距上次滚动检查的 append 次数,到 `rotationCheckStride` 才真的查一次(摊还,见 `append`)。
    private var appendsSinceRotationCheck = 0
    /// 每多少条 append 查一次滚动。取 `maxLines/4`(至少 1)——文件最多临时涨到 `maxLines * 1.25`,
    /// 换来 append 的均摊成本从 O(n) 降到 O(1)。maxLines 很小时(测试)退化成每次都查,行为不变。
    private var rotationCheckStride: Int { max(1, maxLines / 4) }

    /// 复用的写句柄。原先每条 append 都 `createDirectory` + `fileExists` + 打开 + 关闭一次
    /// FileHandle —— 全量接管下连接事件十几~上百条/秒,等于每秒上百次文件打开,纯属浪费。
    /// 这里只在首次(或文件被替换/删除后)打开一次，之后一直复用。
    ///
    /// **落盘时机完全不变**:仍是每条 append 立刻 write 到已打开的句柄,不做跨调用缓冲——
    /// 缓冲会让 `loadRecent` / 直接读文件看不到刚写的行,那是语义变化(现有测试正是这么用的)。
    /// 这里只消除重复系统调用,不改变可见性。
    private var handle: FileHandle?
    /// 复用的编码器(原先每条 append 新建一个)。`JSONEncoder` 无跨调用状态,可安全复用;
    /// actor 已串行化访问。
    private let encoder = JSONEncoder()

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
        guard let data = try? encoder.encode(entry) else { return }
        var payload = data
        payload.append(0x0A)   // '\n'

        if let handle = writeHandle() {
            try? handle.write(contentsOf: payload)
        } else {
            // 拿不到句柄(首次创建失败等)时退回原子写,保证这条不丢。
            try? payload.write(to: fileURL, options: .atomic)
        }

        // 滚动检查**摊还**执行,不是每次 append 都做:`rotateIfNeeded` 要把整个文件读回来切行
        // (满员时 2000 行 / ~300KB),每条日志都跑一遍就是 O(n) per append。策略 A 默认全量接管后
        // 连接事件从个位数/分钟涨到十几条/秒,这条老路径直接把 app 烧到 100% CPU(真机实测)。
        // 现在每 `rotationCheckStride` 条才查一次:文件最多临时超出上限那么多行,随后一次性裁回。
        appendsSinceRotationCheck += 1
        guard appendsSinceRotationCheck >= rotationCheckStride else { return }
        appendsSinceRotationCheck = 0
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

    /// 用户在「活动」页手动清空连接日志时调:直接删掉磁盘文件(不是清空成 0 字节文件——
    /// `append` 靠 `fileExists` 判断"续写 vs 新建",删文件让下次 append 走"新建"分支,
    /// 逻辑更简单)。文件本来就不存在也不算错误。
    public func clear() async {
        // 先弃掉句柄:文件即将被删除,继续持有就会写进一个已不可达的 inode(数据看似写成功、
        // 实际永远读不到)。下次 append 会重新建文件并打开。
        closeHandle()
        try? FileManager.default.removeItem(at: fileURL)
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
        // 原子写会用新文件**替换**旧的 → 旧 inode 作废。必须先弃句柄,否则之后的 append 全都
        // 写进那个已被替换掉的 inode,表现为「日志突然不再增长」。
        closeHandle()
        try? Data(joined.utf8).write(to: fileURL, options: .atomic)
    }

    /// 取写句柄(必要时建目录、建空文件并打开)。已持有就直接复用,并保证写位置在文件尾。
    private func writeHandle() -> FileHandle? {
        if let handle { return handle }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    /// 关闭并弃掉当前句柄(文件被删除/替换前必须调用)。
    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}
