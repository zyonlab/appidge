import Foundation
import Core

/// 一份**命名的**持久化配置——就像 Proxifier 的多个 `.ppx` profile。名字既是展示标签，
/// 也是稳定标识（`id == name`），用户在多套配置之间切换时靠它区分。
///
/// `name` 是 `let`：改名不是原地改字段，而是构造一个新的 `NamedProfile`（见
/// `ProfileCollection.rename`），这样"名字即身份"在类型层面成立、不会出现改了 name
/// 却和别处不同步的中间态。`configuration` 是 `var`，允许就地更新某个 profile 的内容。
public struct NamedProfile: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public var configuration: PersistedConfiguration

    public init(name: String, configuration: PersistedConfiguration) {
        self.name = name
        self.configuration = configuration
    }
}

/// 一组命名 profile + 当前选中的是哪个。纯值类型、纯变换——所有增删改都是 `mutating`
/// 的确定性函数，无副作用、可单测，磁盘持久化交给 `ProfileStore`。
///
/// 维持的不变量：`activeName` 要么是 `nil`（当且仅当 `profiles` 为空），要么精确指向
/// `profiles` 里某个存在的 `name`。所有变换都保住这条，UI 不必再自己兜"active 指向了
/// 已删除的 profile"这种脏状态。
public struct ProfileCollection: Sendable, Equatable, Codable {
    /// 保持插入顺序——UI 列表按加入先后展示，删除/改名不打乱其余项的位置。
    public private(set) var profiles: [NamedProfile]
    /// 指向 `profiles` 里某个 `name`；空集合时为 `nil`。
    public private(set) var activeName: String?

    public init(profiles: [NamedProfile] = [], activeName: String? = nil) {
        self.profiles = profiles
        self.activeName = activeName
    }

    /// 当前 active 指向的配置；没有 active 时为 `nil`。便利读，UI/协调者启动时取它。
    public var activeConfiguration: PersistedConfiguration? {
        guard let activeName else { return nil }
        return profiles.first { $0.name == activeName }?.configuration
    }

    /// 加一个新 profile。**名字冲突则整体 no-op**（既不新增也不覆盖原有配置、不动 active）——
    /// 覆盖式语义太容易让用户误删自己另一套配置，宁可让上层先改名/删除再加。
    /// 若加成功且此前没有 active（首个加入、或删空后再加），新 profile 自动成为 active。
    public mutating func add(name: String, configuration: PersistedConfiguration) {
        guard !profiles.contains(where: { $0.name == name }) else { return }
        profiles.append(NamedProfile(name: name, configuration: configuration))
        if activeName == nil {
            activeName = name
        }
    }

    /// 删掉指定 profile。未知名字是 no-op。若删的正是 active，active 落到剩下的第一个
    /// （删空则为 `nil`）；删的是别的则 active 不变。
    public mutating func remove(name: String) {
        guard profiles.contains(where: { $0.name == name }) else { return }
        profiles.removeAll { $0.name == name }
        if activeName == name {
            activeName = profiles.first?.name
        }
    }

    /// 改名，位置与配置保持不变。以下情况都 no-op：源名不存在、目标名已被别的 profile 占用。
    /// 若改的正是 active，`activeName` 同步跟到新名字。
    public mutating func rename(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        guard let index = profiles.firstIndex(where: { $0.name == oldName }) else { return }
        guard !profiles.contains(where: { $0.name == newName }) else { return }
        profiles[index] = NamedProfile(name: newName, configuration: profiles[index].configuration)
        if activeName == oldName {
            activeName = newName
        }
    }

    /// 切换 active。**仅当该 name 真实存在**才切，未知名字被忽略——不允许把 active 指到
    /// 一个不存在的 profile 上，维持不变量。
    public mutating func setActive(name: String) {
        guard profiles.contains(where: { $0.name == name }) else { return }
        activeName = name
    }

    /// 就地替换某个 profile 的配置（位置、名字、active 指向都不变）。未知名字是 no-op。
    /// 「把当前状态存回某个已存在的档案」用它——区别于 `add` 的名字冲突 no-op 语义。
    public mutating func updateConfiguration(named name: String, to configuration: PersistedConfiguration) {
        guard let index = profiles.firstIndex(where: { $0.name == name }) else { return }
        profiles[index] = NamedProfile(name: name, configuration: configuration)
    }
}

/// app 启动/关闭之间持久化「多 profile 集合」的出口协议。跟 `PersistenceStore` /
/// `EngineKit.Transport` 同一套设计：一个协议、一个测试用 mock、一个真实实现，方便协调者注入。
public protocol ProfileStoring: Sendable {
    func load() async -> ProfileCollection
    func save(_ collection: ProfileCollection) async
}

/// 生产路径的真实实现：JSONEncoder/JSONDecoder 读写磁盘上一个真实文件
/// （默认 `~/Library/Application Support/appidge/profiles.json`——刻意**不同于**
/// 单配置的 `config.json`，两份互不覆盖）。
/// 缺文件（首次启动）或文件损坏都吞掉错误、返回**空的默认集合**，绝不 crash——这是本地
/// 配置缓存，读不到就当作「还没有任何 profile」，让上层重新走引导/新建。
public struct ProfileStore: ProfileStoring {
    private let fileURL: URL

    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("appidge", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public init(fileURL: URL = ProfileStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() async -> ProfileCollection {
        guard let data = try? Data(contentsOf: fileURL),
              let collection = try? JSONDecoder().decode(ProfileCollection.self, from: data)
        else { return ProfileCollection() }
        return collection
    }

    public func save(_ collection: ProfileCollection) async {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 测试/协调者专用：不碰真实磁盘，只在内存里保存最后一次 `save` 的值；可选预置一个初始
/// 集合模拟「上次启动已经存过 profile」。仿 `MockPersistenceStore`。
public actor MockProfileStore: ProfileStoring {
    private var stored: ProfileCollection

    public init(initial: ProfileCollection = ProfileCollection()) {
        self.stored = initial
    }

    public func load() async -> ProfileCollection {
        stored
    }

    public func save(_ collection: ProfileCollection) async {
        stored = collection
    }
}
