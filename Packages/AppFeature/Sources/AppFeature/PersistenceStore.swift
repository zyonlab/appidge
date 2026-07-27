import Foundation
import Core

/// 一台上游代理的**磁盘持久化孪生**——刻意**没有 `password` 字段**。
///
/// 安全约束（本轮的关键要求）：明文密码**绝不**写进磁盘上的 JSON。用一个结构上就
/// 不含密码字段的类型来保证这件事，比"记得在编码时把密码置空"更硬——泄漏在类型系统
/// 层面就是不可能的，而不是靠某处代码自觉。`id`/`host`/`port`/`kind`/`username`
/// 都保留（username 不是凭据，是"用哪个账号"的标识，丢了会导致连不上）。
///
/// **P1 遗留**：真正的凭据存储要走 Keychain（`SecItemAdd`/`SecItemCopyMatching`），
/// 磁盘上这份配置只记"有这么一台代理、用户名是谁"，密码运行时从 Keychain 取。
public struct PersistedProxyServer: Sendable, Equatable, Codable {
    public let id: String
    public let host: String
    public let port: UInt16
    public let kind: Core.ProxyKind
    public let username: String?

    public init(id: String, host: String, port: UInt16, kind: Core.ProxyKind, username: String?) {
        self.id = id
        self.host = host
        self.port = port
        self.kind = kind
        self.username = username
    }

    /// 从 `Core.ProxyServer` 抽取可持久化字段，**丢掉 password**。
    public init(stripping server: Core.ProxyServer) {
        self.init(
            id: server.id.value, host: server.host, port: server.port,
            kind: server.kind, username: server.username
        )
    }

    /// 还原成 `Core.ProxyServer`，`password` 必然为 nil（磁盘上从来没存过）。
    /// 运行时若需要密码，P1 会在这一步从 Keychain 回填。
    public func toProxyServer() -> Core.ProxyServer {
        Core.ProxyServer(
            id: Core.ProxyServerID(id), host: host, port: port,
            kind: kind, username: username, password: nil
        )
    }
}

/// 跨启动持久化的「配置」子集：只包含用户设置过的东西（扫描到的目录、分配的规则、
/// 配置过的上游代理、是否已完成引导），不包含运行时/瞬时状态（`isEngineHealthy`、
/// `diagnostics`、以及 `MonitoredProcess.stats` 里的实时流量——
/// 那些每次启动都应该重置）。代理密码也**不在**持久化范围（见 `PersistedProxyServer`）。
public struct PersistedConfiguration: Sendable, Equatable, Codable {
    public var processes: [Core.ProcessID: Core.MonitoredProcess]
    public var catalog: [Core.ProcessID: Core.DirectoryEntry]
    public var proxyServers: [PersistedProxyServer]
    public var activeProxyServerID: String?
    public var proxyRoutingMode: Core.ProxyRoutingMode
    public var hasCompletedOnboarding: Bool
    /// 细粒度规则表(进程 × 主机 × 端口),按优先级排好序的数组——顺序本身就是语义(首个命中生效),
    /// 所以是 `Array` 不是 `Set`/`Dictionary`。`ProxyMatchRule` 已经是 `Codable`,直接存整个结构体
    /// (含 `isEnabled`),不用另外拆字段。
    public var matchRules: [Core.ProxyMatchRule]
    /// 环自愈学到的硬旁路排除(来源进程双信号)。这是**学到的配置**而非瞬时状态:切语言靠重启生效,
    /// 不持久化的话新实例会以空集 resync、把扩展里已生效的排除整体覆盖掉——本地代理(xray 等)
    /// 瞬间落回兜底「走代理」规则,真环重开,而环检测阈值(60/0.25s,防微信类误报特意收紧)
    /// 不保证能及时把它学回来。`dynamicOriginExclusion` 则不持久化:启动后端口发现会重查。
    public var loopAutoExclusions: Core.OriginExclusionDiscovery

    public init(
        processes: [Core.ProcessID: Core.MonitoredProcess] = [:],
        catalog: [Core.ProcessID: Core.DirectoryEntry] = [:],
        proxyServers: [PersistedProxyServer] = [],
        activeProxyServerID: String? = nil,
        proxyRoutingMode: Core.ProxyRoutingMode = .single,
        hasCompletedOnboarding: Bool = false,
        matchRules: [Core.ProxyMatchRule] = [],
        loopAutoExclusions: Core.OriginExclusionDiscovery = Core.OriginExclusionDiscovery()
    ) {
        self.processes = processes
        self.catalog = catalog
        self.proxyServers = proxyServers
        self.activeProxyServerID = activeProxyServerID
        self.proxyRoutingMode = proxyRoutingMode
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.matchRules = matchRules
        self.loopAutoExclusions = loopAutoExclusions
    }

    /// 手写 `init(from:)`(而不是全靠合成):`matchRules` 是这轮新加的字段,老版本写在磁盘上的
    /// `config.json` 没有这个 key——合成的 `Decodable` 会把缺 key 当解码失败,整份配置(进程/
    /// 目录/代理服务器全部)都读不出来,等于把用户所有配置清空。`decodeIfPresent ?? []`
    /// 让老文件照常解出来,只是 `matchRules` 为空(符合"老文件从没存过规则"的事实)。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processes = try container.decode([Core.ProcessID: Core.MonitoredProcess].self, forKey: .processes)
        catalog = try container.decode([Core.ProcessID: Core.DirectoryEntry].self, forKey: .catalog)
        proxyServers = try container.decode([PersistedProxyServer].self, forKey: .proxyServers)
        activeProxyServerID = try container.decodeIfPresent(String.self, forKey: .activeProxyServerID)
        proxyRoutingMode = try container.decode(Core.ProxyRoutingMode.self, forKey: .proxyRoutingMode)
        hasCompletedOnboarding = try container.decode(Bool.self, forKey: .hasCompletedOnboarding)
        matchRules = try container.decodeIfPresent([Core.ProxyMatchRule].self, forKey: .matchRules) ?? []
        // 同 matchRules 的向后兼容策略:老文件没有这个 key,解成空集而不是让整份配置解码失败。
        loopAutoExclusions = try container.decodeIfPresent(
            Core.OriginExclusionDiscovery.self, forKey: .loopAutoExclusions
        ) ?? Core.OriginExclusionDiscovery()
    }
}

public extension PersistedConfiguration {
    /// 从完整的 `Core.AppState` 里只抽取需要跨启动保存的字段，运行时/瞬时字段
    /// （全局开关、引擎健康度、诊断结果）故意不带走。
    init(from state: Core.AppState) {
        self.init(
            processes: state.processes,
            catalog: state.catalog,
            // 排序确定（按 id），且逐台 strip 掉 password——明文密码绝不落盘。
            proxyServers: state.proxyServers.values
                .sorted { $0.id.value < $1.id.value }
                .map(PersistedProxyServer.init(stripping:)),
            activeProxyServerID: state.activeProxyServerID?.value,
            proxyRoutingMode: state.proxyRoutingMode,
            hasCompletedOnboarding: state.hasCompletedOnboarding,
            // state.rules 已经是按优先级排好的数组(reducer 的 addMatchRule 追加、reorderMatchRules
            // 就地重排),原样带走——不排序,顺序本身就是"首个命中生效"的语义。
            matchRules: state.rules,
            loopAutoExclusions: state.loopAutoExclusions
        )
    }

    /// 把持久化的配置还原成一串要在启动时 dispatch 给 store 的 `Core.Action`，顺序确定
    /// （按 `ProcessID.value` 排序，`matchRules` 保持原数组序），方便单测断言、也让重复启动可重现。
    ///
    /// 组装顺序:`loopAutoExclusionsRestored` **最前**(排除先落地防环,与 `resyncExtension`
    /// 把排除名单排首位同一条纪律);随后 `directoryScanned` 一次性批量灌回目录，
    /// 每个进程先 `processDiscovered`（默认落地为 `.direct`），规则不是默认值才追加
    /// `assignRule`；`matchRules` 逐条 `addMatchRule`(reducer 就是 `state.rules.append`，
    /// 原数组序原样重建)；最后如果引导已完成，追加一个 `onboardingCompleted`。
    func restorationActions() -> [Core.Action] {
        var actions: [Core.Action] = []

        // 环自愈排除先行:后面的恢复/后续 resync 都会触发对扩展的推送,排除必须已经在 state 里,
        // 否则推下去的还是空集(正是切语言后 xray 落回「走代理」的根因)。
        if loopAutoExclusions != Core.OriginExclusionDiscovery() {
            actions.append(.loopAutoExclusionsRestored(loopAutoExclusions))
        }

        if !catalog.isEmpty {
            let entries = catalog.values.sorted { $0.id.value < $1.id.value }
            actions.append(.directoryScanned(entries))
        }

        for process in processes.values.sorted(by: { $0.id.value < $1.id.value }) {
            actions.append(.processDiscovered(
                id: process.id, displayName: process.displayName, executablePath: process.executablePath
            ))
            if process.rule != .direct {
                actions.append(.assignRule(processID: process.id, rule: process.rule))
            }
        }

        // addMatchRule 现在**插到表首**(见 Reducer.addMatchRule 的"新规则置顶"语义)。持久化的
        // matchRules 已按优先级排好(index 0 = 最高),所以**倒序**重放:最后一条先插、第一条最后插,
        // 每次置顶正好把原顺序原样重建回来。正序重放会把整表颠倒。
        for rule in matchRules.reversed() {
            actions.append(.addMatchRule(rule))
        }

        // proxyServers 已经在 init(from:) 里按 id 排好；密码持久化时被剥离，还原出来
        // 的 Core.ProxyServer.password 必为 nil。每台一个 addProxyServer。
        for server in proxyServers {
            actions.append(.addProxyServer(server.toProxyServer()))
        }
        // 只要有代理就补一条 setActiveProxyServer：reducer 会把第一台加入的代理自动选为
        // active，所以即便持久化的 activeProxyServerID 是 nil，也要显式发一条 nil 把那个
        // 自动选择清掉，才能忠实还原"有代理但没选中"这个状态。
        if !proxyServers.isEmpty {
            actions.append(.setActiveProxyServer(activeProxyServerID.map(Core.ProxyServerID.init)))
        }
        // 非默认的路由模式才需要还原;默认 .single 就靠 AppState 的默认值,不必发。
        if proxyRoutingMode != .single {
            actions.append(.setProxyRoutingMode(proxyRoutingMode))
        }

        if hasCompletedOnboarding {
            actions.append(.onboardingCompleted)
        }

        return actions
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
        Self.write(configuration, to: fileURL)
    }

    /// 同步落盘——退出路径(`applicationWillTerminate`)没法 await,但 JSON 编码 + 原子写本身
    /// 不阻塞,直接同步写。用于「退出前强制存一次」,堵住『改动后 400ms 防抖没触发就退出 → 丢改动』
    /// 的窗口(密码不在这份里、走 Keychain,退出不用管)。
    public func saveSynchronously(_ configuration: PersistedConfiguration) {
        Self.write(configuration, to: fileURL)
    }

    private static func write(_ configuration: PersistedConfiguration, to fileURL: URL) {
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
