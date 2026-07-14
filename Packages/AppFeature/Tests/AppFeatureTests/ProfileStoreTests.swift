import Testing
import Foundation
import Core
@testable import AppFeature

@Suite("ProfileStore — ProfileCollection 纯变换 + 磁盘持久化 + Mock 注入")
struct ProfileStoreTests {

    /// 造一个可区分的 PersistedConfiguration：用 activeProxyServerID 当标记，方便断言
    /// 哪份配置落在哪个 profile 上（不同 marker → 不同值 → Equatable 能分辨）。
    private func config(_ marker: String) -> PersistedConfiguration {
        PersistedConfiguration(activeProxyServerID: marker)
    }

    /// 每个测试自己的临时文件，绝不碰真实 Application Support 路径；测试结束清理父目录。
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    // MARK: - NamedProfile

    @Test("NamedProfile 的 id 就是 name")
    func namedProfileIdentityIsName() {
        let profile = NamedProfile(name: "Work", configuration: config("w"))
        #expect(profile.id == "Work")
        #expect(profile.id == profile.name)
    }

    // MARK: - add

    @Test("add：首个加入的 profile 自动成为 active")
    func addFirstBecomesActive() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        #expect(collection.profiles.map(\.name) == ["A"])
        #expect(collection.activeName == "A")
    }

    @Test("add：后续加入不改变已有的 active，且保持插入顺序")
    func addSubsequentKeepsActiveAndOrder() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.add(name: "C", configuration: config("c"))
        #expect(collection.profiles.map(\.name) == ["A", "B", "C"])
        #expect(collection.activeName == "A")
    }

    @Test("add：名字冲突则不加（no-op），既不新增也不覆盖原有配置、不动 active")
    func addDuplicateNameIsNoOp() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("original"))
        collection.add(name: "B", configuration: config("b"))
        collection.setActive(name: "B")

        collection.add(name: "A", configuration: config("overwrite-attempt"))

        #expect(collection.profiles.map(\.name) == ["A", "B"])
        #expect(collection.activeName == "B")
        // 原配置未被覆盖
        #expect(collection.profiles.first { $0.name == "A" }?.configuration == config("original"))
    }

    @Test("add：删空后再加，新的一个重新成为 active")
    func addAfterEmptyingBecomesActiveAgain() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.remove(name: "A")
        #expect(collection.activeName == nil)

        collection.add(name: "B", configuration: config("b"))
        #expect(collection.activeName == "B")
    }

    // MARK: - remove

    @Test("remove：删掉 active，active 落到剩下的第一个")
    func removeActiveReassignsToFirstRemaining() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.add(name: "C", configuration: config("c"))
        collection.setActive(name: "C") // active 不是第一个

        collection.remove(name: "C")

        #expect(collection.profiles.map(\.name) == ["A", "B"])
        #expect(collection.activeName == "A") // 落到剩下的第一个
    }

    @Test("remove：删掉非 active 的 profile，active 不变")
    func removeNonActiveKeepsActive() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.add(name: "C", configuration: config("c"))
        // active 默认是 A

        collection.remove(name: "B")

        #expect(collection.profiles.map(\.name) == ["A", "C"])
        #expect(collection.activeName == "A")
    }

    @Test("remove：删掉最后一个，active 变 nil")
    func removeLastMakesActiveNil() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))

        collection.remove(name: "A")

        #expect(collection.profiles.isEmpty)
        #expect(collection.activeName == nil)
    }

    @Test("remove：未知名字是 no-op")
    func removeUnknownIsNoOp() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))

        collection.remove(name: "does-not-exist")

        #expect(collection.profiles.map(\.name) == ["A"])
        #expect(collection.activeName == "A")
    }

    // MARK: - rename

    @Test("rename：改名成功，active 指向同步跟随，位置与配置保持不变")
    func renameFollowsActiveAndPreservesPositionAndConfig() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.add(name: "C", configuration: config("c"))
        collection.setActive(name: "B")

        collection.rename(from: "B", to: "Z")

        #expect(collection.profiles.map(\.name) == ["A", "Z", "C"]) // 位置不变
        #expect(collection.activeName == "Z") // active 跟随
        #expect(collection.profiles.first { $0.name == "Z" }?.configuration == config("b")) // 配置保留
    }

    @Test("rename：目标名已存在则不改（no-op）")
    func renameToExistingNameIsNoOp() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))

        collection.rename(from: "A", to: "B")

        #expect(collection.profiles.map(\.name) == ["A", "B"])
        #expect(collection.profiles.first { $0.name == "A" }?.configuration == config("a"))
        #expect(collection.profiles.first { $0.name == "B" }?.configuration == config("b"))
    }

    @Test("rename：源名不存在则不改（no-op）")
    func renameUnknownFromIsNoOp() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))

        collection.rename(from: "does-not-exist", to: "Z")

        #expect(collection.profiles.map(\.name) == ["A"])
        #expect(collection.activeName == "A")
    }

    // MARK: - setActive

    @Test("setActive：目标存在才切")
    func setActiveKnownSwitches() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))

        collection.setActive(name: "B")

        #expect(collection.activeName == "B")
    }

    @Test("setActive：未知名字被忽略")
    func setActiveUnknownIsIgnored() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.setActive(name: "B")

        collection.setActive(name: "does-not-exist")

        #expect(collection.activeName == "B") // 未变
    }

    // MARK: - activeConfiguration

    @Test("activeConfiguration：返回当前 active 的配置")
    func activeConfigurationReturnsActive() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.setActive(name: "B")

        #expect(collection.activeConfiguration == config("b"))
    }

    @Test("activeConfiguration：没有 active 时返回 nil")
    func activeConfigurationNilWhenNoActive() {
        let collection = ProfileCollection()
        #expect(collection.activeConfiguration == nil)
    }

    // MARK: - Codable

    @Test("ProfileCollection Codable 往返相等")
    func collectionCodableRoundTrip() throws {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        collection.add(name: "B", configuration: config("b"))
        collection.setActive(name: "B")

        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(ProfileCollection.self, from: data)

        #expect(decoded == collection)
    }

    // MARK: - ProfileStore（磁盘）

    @Test("ProfileStore：save 后用全新实例 load 往返相等（跨实例即模拟重启）")
    func fileStoreRoundTrip() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var collection = ProfileCollection()
        collection.add(name: "Work", configuration: config("work"))
        collection.add(name: "Home", configuration: config("home"))
        collection.setActive(name: "Home")

        let writer = ProfileStore(fileURL: url)
        await writer.save(collection)

        let reader = ProfileStore(fileURL: url)
        let loaded = await reader.load()

        #expect(loaded == collection)
    }

    @Test("ProfileStore：文件不存在（首次启动）返回空的默认集合")
    func fileStoreMissingFileReturnsEmpty() async {
        let url = makeTempFileURL()
        let store = ProfileStore(fileURL: url)
        let loaded = await store.load()
        #expect(loaded == ProfileCollection())
        #expect(loaded.profiles.isEmpty)
        #expect(loaded.activeName == nil)
    }

    @Test("ProfileStore：文件损坏不崩溃，返回空的默认集合")
    func fileStoreCorruptFileReturnsEmpty() async throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProfileStore(fileURL: url)
        let loaded = await store.load()
        #expect(loaded == ProfileCollection())
    }

    @Test("ProfileStore：save 会创建不存在的中间目录")
    func fileStoreCreatesMissingDirectory() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        let store = ProfileStore(fileURL: url)
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        await store.save(collection)

        #expect(FileManager.default.fileExists(atPath: url.path) == true)
    }

    @Test("ProfileStore 默认文件路径是 profiles.json（不同于 config.json）")
    func fileStoreDefaultPathIsProfilesJSON() {
        #expect(ProfileStore.defaultFileURL.lastPathComponent == "profiles.json")
        #expect(ProfileStore.defaultFileURL.lastPathComponent != FilePersistenceStore.defaultFileURL.lastPathComponent)
    }

    // MARK: - MockProfileStore（内存）

    @Test("MockProfileStore：save 后 load 拿回同一份")
    func mockStoreRoundTrip() async {
        let mock = MockProfileStore()
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        await mock.save(collection)
        let loaded = await mock.load()
        #expect(loaded == collection)
    }

    @Test("MockProfileStore：可预置初始集合")
    func mockStoreInitialSeed() async {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))
        let mock = MockProfileStore(initial: collection)
        let loaded = await mock.load()
        #expect(loaded == collection)
    }

    @Test("MockProfileStore：从未 seed/save 时 load 返回空默认集合")
    func mockStoreDefaultsToEmpty() async {
        let mock = MockProfileStore()
        let loaded = await mock.load()
        #expect(loaded == ProfileCollection())
    }

    // MARK: - 协议注入

    @Test("ProfileStore 与 MockProfileStore 都满足 ProfileStoring，可被协调者注入")
    func bothConformToProfileStoring() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var collection = ProfileCollection()
        collection.add(name: "A", configuration: config("a"))

        let stores: [any ProfileStoring] = [ProfileStore(fileURL: url), MockProfileStore()]
        for store in stores {
            await store.save(collection)
            let loaded = await store.load()
            #expect(loaded == collection)
        }
    }
}
