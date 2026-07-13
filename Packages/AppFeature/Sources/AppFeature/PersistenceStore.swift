import Foundation
import Core

/// 跨启动持久化的「配置」子集：只包含用户设置过的东西（扫描到的目录、分配的规则、
/// 是否已完成引导），不包含运行时/瞬时状态（`isGlobalProxyEnabled`、`isEngineHealthy`、
/// `diagnostics`、以及 `MonitoredProcess.stats` 里的实时流量——那些每次启动都应该重置）。
public struct PersistedConfiguration: Sendable, Equatable, Codable {
    public var processes: [Core.ProcessID: Core.MonitoredProcess]
    public var catalog: [Core.ProcessID: Core.DirectoryEntry]
    public var hasCompletedOnboarding: Bool

    public init(
        processes: [Core.ProcessID: Core.MonitoredProcess] = [:],
        catalog: [Core.ProcessID: Core.DirectoryEntry] = [:],
        hasCompletedOnboarding: Bool = false
    ) {
        self.processes = processes
        self.catalog = catalog
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

public extension PersistedConfiguration {
    /// 从完整的 `Core.AppState` 里只抽取需要跨启动保存的字段，运行时/瞬时字段
    /// （全局开关、引擎健康度、诊断结果）故意不带走。
    init(from state: Core.AppState) {
        self.init(
            processes: state.processes,
            catalog: state.catalog,
            hasCompletedOnboarding: state.hasCompletedOnboarding
        )
    }
}

/// app 启动/关闭之间持久化配置的出口协议。跟 `EngineKit.Transport` /
/// `AppFeature.AppSideTransport` 同一套设计：一个协议、一个测试用 mock、一个真实实现。
public protocol PersistenceStore: Sendable {
    func load() async -> PersistedConfiguration?
    func save(_ configuration: PersistedConfiguration) async
}

/// 生产路径的真实实现：JSONEncoder/JSONDecoder 读写磁盘上一个真实文件
/// （默认 `~/Library/Application Support/appidge/config.json`）。
/// 缺文件（首次启动）或文件损坏都吞掉错误、返回 nil，绝不 crash——这是本地配置缓存，
/// 不是权威数据源，读不到就当作「还没有配置」处理，让上层重新走引导/扫描。
public struct FilePersistenceStore: PersistenceStore {
    private let fileURL: URL

    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("appidge", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public init(fileURL: URL = FilePersistenceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() async -> PersistedConfiguration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedConfiguration.self, from: data)
    }

    public func save(_ configuration: PersistedConfiguration) async {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 测试专用：不碰真实磁盘，只在内存里保存最后一次 `save` 的值；可选预置一个初始值
/// 模拟「上次启动已经保存过配置」的场景。
public actor MockPersistenceStore: PersistenceStore {
    private var stored: PersistedConfiguration?

    public init(initial: PersistedConfiguration? = nil) {
        self.stored = initial
    }

    public func load() async -> PersistedConfiguration? {
        stored
    }

    public func save(_ configuration: PersistedConfiguration) async {
        stored = configuration
    }
}
