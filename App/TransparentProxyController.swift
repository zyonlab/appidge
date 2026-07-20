import Foundation
@preconcurrency import NetworkExtension
import os.log

private let tpLog = Logger(subsystem: "com.appidge.app", category: "TransparentProxy")

/// 启动 / 停止透明代理**会话**。扩展获批只是「装上」;真正让系统把出站流量交给 provider,
/// 还必须由 app 侧建一个 `NETransparentProxyManager` 配置并 `startVPNTunnel()` ——
/// 那一刻 provider 的 `startProxy` 才被调用、`setTunnelNetworkSettings` 生效、`handleNewFlow` 才收到流量。
/// 之前这块完全缺失,所以扩展 enabled 了却「还没有连接」。
///
/// 首次 `saveToPreferences()` 会弹一次「appidge 想添加 VPN / 代理配置」——用户点允许后配置留存,以后静默。
/// 诊断:关键步骤写 stderr(从终端跑 app 可抓)+ os.Logger。
@MainActor
enum TransparentProxyController {
    private static let extensionBundleID = "com.appidge.app.ProxyExtension"
    private static var manager: NETransparentProxyManager?
    /// 本进程**见过的所有** appidge 会话 manager(每次 `loadAllFromPreferences` 后更新)。退出时要
    /// 同步停掉全部——只停缓存的单个 `manager` 不够:会话可能由别的实例(如语言切换重启出的新实例)
    /// 持有,漏停就留下僵尸接管、全系统断网直到下次启动。`reset()` 移除配置后清空。
    private static var knownManagers: [NETransparentProxyManager] = []

    /// 记住这一批加载到的 manager(供退出时全量停会话)。非空才覆盖,避免一次偶发的空加载把已知的抹掉;
    /// 顺带把主 `manager` 对齐到第一个。
    private static func remember(_ managers: [NETransparentProxyManager]) {
        if !managers.isEmpty { knownManagers = managers }
        manager = managers.first ?? manager
    }

    /// 是否已有一次 start 在进行中(@MainActor 上 await 前同步占旗,防并发)。
    private static var startInFlight = false

    /// 建/存配置并启动会话。幂等:已在跑就不重复启。
    static func start() async {
        // 防并发:`loadOrCreate()` 有 await,两次并发 start()(checkStatus + onStateChange)都会在
        // await 后读到 disconnected → 都 startVPNTunnel → 两次 startProxy → 两个 XPC 监听器抢同一
        // mach service → flow 投错监听器全丢(真机「会话卡 connecting、收不到 flow」的真因)。
        // 同一时刻只允许一次 start,余者跳过。
        guard !startInFlight else {
            emit("start(): 已有 start 在进行,跳过本次(防并发双 startVPNTunnel)")
            return
        }
        startInFlight = true
        defer { startInFlight = false }
        do {
            let mgr = try await loadOrCreate()
            switch mgr.connection.status {
            case .connected, .connecting:
                emit("session already \(statusName(mgr.connection.status))")
            default:
                try mgr.connection.startVPNTunnel()
                emit("startVPNTunnel() called — provider.startProxy should now run")
            }
        } catch {
            let ns = error as NSError
            emit("START FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        }
    }

    /// **重启会话 = 重新绑定到当前(最新)扩展 provider**。反复热升级后系统可能把运行中的
    /// 会话继续绑在待卸载的旧 provider 实例上(流量被交给僵尸扩展 → 黑洞),等价于用户手动在
    /// 系统设置里关开一次网络扩展。这里程序化地做:停会话 → 等它真的断开 → 重新起。
    /// 用于:版本握手发现会话绑了旧扩展、或用户点「重启接管」。
    /// 是否已有一次 restart 在进行中(@MainActor 上同步先占,防并发)。
    private static var restartInFlight = false

    static func restart() async {
        // 版本升级时 startOnLaunch 的 restart 与版本握手 maybeHealStaleBinding 的 restart 可能同时触发;
        // 并发的 stop→等→start 会互相打架(一个在停、一个在起)。同一时刻只允许一次,余者跳过——
        // 那一次已经把会话干净重绑,跳过无损。
        guard !restartInFlight else {
            emit("restart(): 已有重启在进行,跳过本次(避免并发 stop/start 抖动)")
            return
        }
        restartInFlight = true
        defer { restartInFlight = false }
        emit("restart(): stopping session to rebind to the current provider")
        do {
            let mgr = try await loadOrCreate()
            mgr.connection.stopVPNTunnel()
            // 等到真的 disconnected 再起(最多 ~5s);不等的话 startVPNTunnel 可能被忽略。
            for _ in 0..<50 {
                if mgr.connection.status == .disconnected || mgr.connection.status == .invalid { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try mgr.connection.startVPNTunnel()
            emit("restart(): startVPNTunnel() called — session should now bind to the latest provider")
        } catch {
            let ns = error as NSError
            emit("restart FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        }
    }

    /// 停止会话(不删配置)。没有活动会话 = 扩展不再收到任何 flow,所有应用立即恢复原生联网。
    /// 之前只停缓存的 manager,本会话没 start 过(比如上次 app 异常退出后重开)就停了个寂寞——
    /// 现在先 load 系统偏好里的配置再停,保证停的是真正在跑的那个会话。
    static func stop() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            remember(managers)
            for mgr in managers {
                mgr.connection.stopVPNTunnel()
            }
            if let cached = manager, managers.isEmpty {
                cached.connection.stopVPNTunnel()
            }
            emit("stopVPNTunnel() called on \(managers.count) manager(s)")
        } catch {
            manager?.connection.stopVPNTunnel()
            emit("stop: loadAllFromPreferences failed (\(error.localizedDescription)), stopped cached session only")
        }
    }

    /// **紧急恢复(重置)**:停止会话并把 appidge 的透明代理配置从系统网络偏好里整个移除——
    /// 拦截彻底解除,所有应用立即恢复原生联网,**无需重启电脑**(重启电脑"能修好"正是因为
    /// 开机后没人再 startVPNTunnel;这里把同样的效果做成一个按钮,并且清掉配置本身)。
    /// 系统扩展保持安装;重新开启接管 = 重启 app 或点「启用」(会重建配置,首次重建可能再弹一次
    /// "添加 VPN/代理配置"授权)。
    static func reset() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard !managers.isEmpty else {
                manager?.connection.stopVPNTunnel()
                manager = nil
                knownManagers = []
                emit("reset: no saved managers; stopped cached session if any")
                return
            }
            for mgr in managers {
                mgr.connection.stopVPNTunnel()
                try await mgr.removeFromPreferences()
            }
            manager = nil
            knownManagers = []   // 配置已整个移除,退出时没有会话需要再停
            emit("reset: stopped and removed \(managers.count) manager(s) — interception fully torn down")
        } catch {
            emit("RESET FAILED: \(error.localizedDescription)")
        }
    }

    /// app 退出路径的同步兜底(`applicationWillTerminate` 里没法 await):停掉本进程见过的**所有**
    /// 会话 manager,而不只是缓存的那一个——会话可能由别的实例(如语言切换重启出的新实例)持有,
    /// 只停一个会漏掉、留下僵尸接管全系统断网。宗旨:**UI 不在,接管就不该在**——规则没人管、出问题
    /// 没人能停,catch-all 拦截挂在系统上直到重启,正是"Chrome 断网只能重启电脑"的处境。
    /// 只停会话、不删配置,下次启动照常静默接管。
    static func stopCachedSessionForTermination() {
        // knownManagers 覆盖本进程 start/stop/restart 期间 loadAllFromPreferences 见过的全部会话;
        // 极端情况下(本进程从没加载过)回落到停缓存的 manager,尽最大努力不留僵尸接管。
        var targets = knownManagers
        if targets.isEmpty, let cached = manager { targets = [cached] }
        for mgr in targets {
            mgr.connection.stopVPNTunnel()
        }
        emit("stopVPNTunnel() on app termination — stopped \(targets.count) session(s)")
    }

    /// 当前会话是否在跑(UI 可据此显示是否真正在接管流量)。
    static func isRunning() async -> Bool {
        guard let mgr = try? await loadOrLoadFirst() else { return false }
        return mgr.connection.status == .connected
    }

    private static func loadOrLoadFirst() async throws -> NETransparentProxyManager? {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        remember(managers)
        return manager
    }

    private static func loadOrCreate() async throws -> NETransparentProxyManager {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let existing = managers.first
        let mgr = existing ?? NETransparentProxyManager()
        // NETransparentProxyManager 用 NETunnelProviderProtocol + providerBundleIdentifier 指向系统扩展。
        let currentProto = mgr.protocolConfiguration as? NETunnelProviderProtocol
        // **幂等**:只有「新建」或「已存在但配置不对」才 saveToPreferences。每次都存会让 NE 守护重新加载
        // 配置、把 provider 的 setTunnelNetworkSettings 冲掉——启动路径多次 loadOrCreate 连环存,会话
        // connected 却不再拦截任何流量(真机实锤的「会话通、活动栏空」)。已正确就直接复用,不再重存。
        let needsSave = existing == nil
            || currentProto?.providerBundleIdentifier != extensionBundleID
            || mgr.isEnabled != true
        if needsSave {
            let proto = currentProto ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleID
            // serverAddress 必须非空;透明代理里只是占位、不代表真实服务器。
            proto.serverAddress = "appidge (per-process)"
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "appidge · 按进程代理"
            mgr.isEnabled = true
            try await mgr.saveToPreferences()   // 首次在此弹「添加配置」授权
            try await mgr.loadFromPreferences() // 存后必须重新 load 才能 start
            emit("manager saved+loaded (created/reconfigured); provider=\(extensionBundleID)")
        } else {
            emit("manager reused (config already correct, no re-save)")
        }
        // 记住全部已知会话(新建时也把这台记进去),供退出全量停会话。
        remember(managers.isEmpty ? [mgr] : managers)
        return mgr
    }

    private static func statusName(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid: "invalid"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        @unknown default: "unknown"
        }
    }

    private static func emit(_ s: String) {
        FileHandle.standardError.write(Data(("TP: " + s + "\n").utf8))
        tpLog.log("\(s, privacy: .public)")
    }
}
