import Testing
import Foundation
import Core
@testable import AppFeature

@Suite("PersistenceStore — FilePersistenceStore round-trip, MockPersistenceStore, AppState conversion")
struct PersistenceStoreTests {

    /// 每个测试自己的临时目录，绝不碰真实的 Application Support 路径；测试结束清理。
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config.json")
    }

    @Test("save then load with a fresh FilePersistenceStore instance round-trips an equal configuration")
    func fileStoreRoundTrip() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = ProcessID("com.example.app")
        let config = PersistedConfiguration(
            processes: [
                id: MonitoredProcess(
                    id: id, displayName: "Example", executablePath: "/Applications/Example.app", rule: .proxied
                )
            ],
            catalog: [
                id: DirectoryEntry(
                    id: id, displayName: "Example", executablePath: "/Applications/Example.app", industryTag: .technology
                )
            ],
            hasCompletedOnboarding: true
        )

        let writer = FilePersistenceStore(fileURL: url)
        await writer.save(config)

        // Fresh instance — proves persistence survives across store instances (i.e. relaunches),
        // not just an in-memory cache pretending to be a file store.
        let reader = FilePersistenceStore(fileURL: url)
        let loaded = await reader.load()

        #expect(loaded == config)
    }

    @Test("save then load round-trips matchRules, including a disabled rule and closed port range")
    func fileStoreRoundTripPreservesMatchRules() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = PersistedConfiguration(matchRules: [
            ProxyMatchRule(
                id: RuleID("r1"), appPattern: "a.out", hostPattern: "36.235.144.193",
                portRange: 48407...48407, action: .direct
            ),
            ProxyMatchRule(
                id: RuleID("r2"), appPattern: "*", hostPattern: "*.example.com",
                portRange: nil, action: .block, isEnabled: false
            )
        ])

        let writer = FilePersistenceStore(fileURL: url)
        await writer.save(config)
        let loaded = await FilePersistenceStore(fileURL: url).load()

        #expect(loaded == config)
        #expect(loaded?.matchRules.map(\.id) == [RuleID("r1"), RuleID("r2")])
        #expect(loaded?.matchRules.last?.isEnabled == false)
    }

    @Test("load on a pre-existing config.json that predates the matchRules field decodes fine with an empty rule list")
    func fileStoreDecodesLegacyFileMissingMatchRulesKey() async throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Hand-written JSON with no "matchRules" key at all — simulates a config.json
        // written by a build that predates this field, the exact shape found on a real
        // machine that had never persisted match rules. Dictionaries keyed by a non-
        // String/Int Codable type (ProcessID) encode as a flat array of alternating
        // key/value elements, not a JSON object — matches the real on-disk shape.
        let legacyJSON = """
        {
            "processes": [], "catalog": [], "proxyServers": [],
            "activeProxyServerID": null, "proxyRoutingMode": {"single": {}},
            "hasCompletedOnboarding": true
        }
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = await FilePersistenceStore(fileURL: url).load()

        #expect(loaded != nil)
        #expect(loaded?.matchRules == [])
        #expect(loaded?.hasCompletedOnboarding == true)
    }

    @Test("save then load round-trips loopAutoExclusions — 环自愈学到的硬旁路跨重启不丢")
    func fileStoreRoundTripPreservesLoopAutoExclusions() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = PersistedConfiguration(loopAutoExclusions: OriginExclusionDiscovery(
            identifiers: ["com.example.yunti"],
            executablePaths: ["/Users/admin/.yunti/xray-core/xray"]
        ))
        await FilePersistenceStore(fileURL: url).save(config)
        let loaded = await FilePersistenceStore(fileURL: url).load()

        #expect(loaded == config)
        #expect(loaded?.loopAutoExclusions.executablePaths == ["/Users/admin/.yunti/xray-core/xray"])
    }

    @Test("load on a config.json that predates the loopAutoExclusions field decodes fine with an empty set")
    func fileStoreDecodesLegacyFileMissingLoopAutoExclusionsKey() async throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // matchRules 在、loopAutoExclusions 不在——模拟上一个版本写盘的 config.json。
        let legacyJSON = """
        {
            "processes": [], "catalog": [], "proxyServers": [],
            "activeProxyServerID": null, "proxyRoutingMode": {"single": {}},
            "hasCompletedOnboarding": true, "matchRules": []
        }
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = await FilePersistenceStore(fileURL: url).load()

        #expect(loaded != nil)
        #expect(loaded?.loopAutoExclusions == OriginExclusionDiscovery())
        #expect(loaded?.hasCompletedOnboarding == true)
    }

    @Test("load returns nil gracefully when the file doesn't exist yet (first launch)")
    func fileStoreMissingFileReturnsNil() async {
        let url = makeTempFileURL()
        let store = FilePersistenceStore(fileURL: url)
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test("load doesn't crash on a corrupt/unreadable file, returns nil")
    func fileStoreCorruptFileReturnsNil() async throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FilePersistenceStore(fileURL: url)
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test("save creates intermediate directories that don't exist yet")
    func fileStoreCreatesMissingDirectory() async {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        let store = FilePersistenceStore(fileURL: url)
        await store.save(PersistedConfiguration(hasCompletedOnboarding: true))

        #expect(FileManager.default.fileExists(atPath: url.path) == true)
    }

    @Test("MockPersistenceStore records save and returns it from load")
    func mockStoreRoundTrip() async {
        let mock = MockPersistenceStore()
        let config = PersistedConfiguration(hasCompletedOnboarding: true)
        await mock.save(config)
        let loaded = await mock.load()
        #expect(loaded == config)
    }

    @Test("MockPersistenceStore can be preseeded with an initial configuration")
    func mockStoreInitialSeed() async {
        let config = PersistedConfiguration(hasCompletedOnboarding: true)
        let mock = MockPersistenceStore(initial: config)
        let loaded = await mock.load()
        #expect(loaded == config)
    }

    @Test("MockPersistenceStore.load returns nil when never seeded or saved")
    func mockStoreDefaultsToNil() async {
        let mock = MockPersistenceStore()
        let loaded = await mock.load()
        #expect(loaded == nil)
    }

    @Test("PersistedConfiguration(from:) extracts only configuration, not runtime/ephemeral state")
    func conversionFromAppStateExtractsConfigurationOnly() {
        let id = ProcessID("x")
        var state = AppState()
        state.isEngineHealthy = false
        state.processes[id] = MonitoredProcess(id: id, displayName: "X", executablePath: "/x", rule: .proxied)
        state.catalog[id] = DirectoryEntry(id: id, displayName: "X", executablePath: "/x")
        state.diagnostics[id] = [.ruleHit: DiagnosticOutcome(passed: true, detail: "ok")]
        state.hasCompletedOnboarding = true
        state.rules = [ProxyMatchRule(
            id: RuleID("r1"), appPattern: "x", hostPattern: "*", portRange: nil, action: .block
        )]
        state.loopAutoExclusions = OriginExclusionDiscovery(executablePaths: ["/opt/xray"])

        let config = PersistedConfiguration(from: state)

        #expect(config.processes == state.processes)
        #expect(config.catalog == state.catalog)
        #expect(config.hasCompletedOnboarding == true)
        #expect(config.matchRules == state.rules)
        // 环自愈学到的硬旁路是「学到的配置」而非瞬时状态——切语言重启靠它不丢(dynamicOriginExclusion
        // 则仍是运行时状态:启动后端口发现会重查,不持久化)。
        #expect(config.loopAutoExclusions == state.loopAutoExclusions)
        // isEngineHealthy / diagnostics deliberately have no
        // counterpart on PersistedConfiguration — the type system, not a runtime
        // assertion, is the proof they're excluded.
    }
}
