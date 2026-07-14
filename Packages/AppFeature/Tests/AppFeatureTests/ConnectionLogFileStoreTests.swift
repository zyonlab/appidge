import Testing
import Foundation
import Core
@testable import AppFeature

@Suite("ConnectionLogFileStore — rolling JSONL 连接日志的磁盘持久化")
struct ConnectionLogFileStoreTests {

    /// 每个测试自己的临时文件,绝不碰真实的 Application Support 路径;测试结束清理父目录。
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("connections.log.jsonl")
    }

    /// 造一条连接日志。id 决定顺序,host/bytes 用来验证字段被完整保存。
    private func makeEntry(
        id: String, host: String = "example.com", up: Int64 = 0, down: Int64 = 0
    ) -> ConnectionLogEntry {
        ConnectionLogEntry(
            id: id,
            processID: ProcessID("com.example.app"),
            host: host,
            port: 443,
            rule: .proxied,
            proxyKind: .socks5,
            phase: .opened,
            bytesUp: up,
            bytesDown: down
        )
    }

    @Test("append 后 loadRecent 按 oldest→newest 原样往返,字段(host/bytes)完整保留")
    func appendThenLoadRecentRoundTrips() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let e1 = makeEntry(id: "1", host: "a.com", up: 10, down: 20)
        let e2 = makeEntry(id: "2", host: "b.com", up: 30, down: 40)
        let e3 = makeEntry(id: "3", host: "c.com", up: 50, down: 60)

        let store = ConnectionLogFileStore(fileURL: url)
        await store.append(e1)
        await store.append(e2)
        await store.append(e3)

        let loaded = await store.loadRecent(limit: 10)
        #expect(loaded == [e1, e2, e3])
        // 抽验字段确实落盘还原,不是空壳。
        #expect(loaded.first?.host == "a.com")
        #expect(loaded.last?.bytesDown == 60)
    }

    @Test("loadRecent(limit:) 只返回最后 N 条,仍是 oldest→newest")
    func loadRecentReturnsOnlyLastN() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entries = (1...5).map { makeEntry(id: "\($0)") }
        let store = ConnectionLogFileStore(fileURL: url)
        for entry in entries { await store.append(entry) }

        let loaded = await store.loadRecent(limit: 3)
        #expect(loaded == Array(entries.suffix(3)))
        #expect(loaded.map(\.id) == ["3", "4", "5"])
    }

    @Test("超过 maxLines 后触发滚动,丢掉最旧的行,只保留最后 maxLines 条")
    func capRotationDropsOldestLines() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entries = (1...5).map { makeEntry(id: "\($0)") }
        let store = ConnectionLogFileStore(fileURL: url, maxLines: 3)
        for entry in entries { await store.append(entry) }

        // 只剩最后 3 条。
        let loaded = await store.loadRecent(limit: 100)
        #expect(loaded == Array(entries.suffix(3)))
        #expect(loaded.map(\.id) == ["3", "4", "5"])

        // 物理上文件也确实被截到 3 行,不是靠读取时裁剪。
        let data = try #require(try? Data(contentsOf: url))
        let content = try #require(String(bytes: data, encoding: .utf8))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
    }

    @Test("文件不存在(首次启动)时 loadRecent 返回空数组,不崩溃")
    func missingFileReturnsEmpty() async {
        let url = makeTempFileURL()   // 父目录都不存在
        let store = ConnectionLogFileStore(fileURL: url)
        let loaded = await store.loadRecent(limit: 10)
        #expect(loaded.isEmpty)
    }

    @Test("文件里夹了一行坏 JSON,loadRecent 跳过它,仍返回其余有效行")
    func malformedLineSkipped() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let e1 = makeEntry(id: "1")
        let e2 = makeEntry(id: "2")

        let store = ConnectionLogFileStore(fileURL: url)
        await store.append(e1)
        // 直接往文件里插一行损坏内容,模拟磁盘上的脏行。
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-valid-json\n".utf8))
        try handle.close()
        await store.append(e2)

        let loaded = await store.loadRecent(limit: 100)
        #expect(loaded == [e1, e2])
    }

    @Test("落盘格式是 line-delimited JSON:一条 entry 恰好一行,每行独立可解码")
    func fileIsLineDelimitedJSON() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entries = (1...3).map { makeEntry(id: "\($0)") }
        let store = ConnectionLogFileStore(fileURL: url)
        for entry in entries { await store.append(entry) }

        let data = try #require(try? Data(contentsOf: url))
        let content = try #require(String(bytes: data, encoding: .utf8))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        #expect(lines.count == entries.count)
        let decoder = JSONDecoder()
        for line in lines {
            #expect((try? decoder.decode(ConnectionLogEntry.self, from: Data(line.utf8))) != nil)
        }
    }

    @Test("defaultFileURL 落在 Application Support/appidge 下,文件名是 connections.log.jsonl")
    func defaultFileURLShape() {
        let url = ConnectionLogFileStore.defaultFileURL
        #expect(url.lastPathComponent == "connections.log.jsonl")
        #expect(url.deletingLastPathComponent().lastPathComponent == "appidge")
    }
}
