import Foundation
@preconcurrency import NetworkExtension
import os.log
import AppFeature

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

    /// 所有启停请求进入同一个串行 worker。`revision` 是 capability 世代号：任何异步操作在
    /// `await` 后都必须确认自己仍是最新请求，旧 start/restart 才不能越过后来的 revoke/stop。
    private static var sessionCoordinator = ProxySessionIntentCoordinator()
    private static var sessionWorker: Task<Void, Never>?

    /// 请求会话运行。同步登记意图后由串行 worker 执行；调用方无需再包一层不受控的 `Task`。
    static func start() {
        PerfDiag.milestone("session.start_called")
        request(.running)
    }

    /// 请求停止会话。先同步停掉已知 manager，再由 worker 加载系统偏好做全量确认；
    /// 同时递增 revision，使所有在途 start/restart 在下一次恢复执行时自动失效。
    static func stop() {
        request(.stopped)
    }

    /// 请求重绑到当前 provider。与 start/stop 共用同一 worker 和世代号。
    static func restart() {
        request(.restarting)
    }

    /// 请求紧急停止并移除透明代理配置。
    static func reset() {
        request(.resetting)
    }

    private static func request(_ intent: ProxySessionIntent) {
        sessionCoordinator.request(intent)
        if intent == .stopped || intent == .resetting {
            stopKnownManagersImmediately()
        }
        guard sessionWorker == nil else { return }
        sessionWorker = Task { @MainActor in
            await reconcileSessionIntent()
        }
    }

    /// 单消费者循环：若某次 await 期间来了更新请求，旧操作退出/跳过，循环立即处理最新意图。
    private static func reconcileSessionIntent() async {
        while true {
            let ticket = sessionCoordinator.currentTicket
            switch ticket.intent {
            case .running:
                await performStart(ticket: ticket)
            case .stopped:
                await performStop(ticket: ticket)
            case .restarting:
                await performRestart(ticket: ticket)
            case .resetting:
                await performReset(ticket: ticket)
            }

            guard sessionCoordinator.isCurrent(ticket) else { continue }
            sessionCoordinator.complete(ticket)
            sessionWorker = nil
            return
        }
    }

    /// 建/存配置并启动会话。幂等:已在跑就不重复启。
    private static func performStart(ticket: ProxySessionIntentTicket) async {
        do {
            let mgr = try await loadOrCreate()
            guard sessionCoordinator.isCurrent(ticket) else {
                emit("start cancelled: a newer stop/restart request superseded it")
                return
            }
            switch mgr.connection.status {
            case .connected, .connecting:
                emit("session already \(statusName(mgr.connection.status))")
            default:
                try mgr.connection.startVPNTunnel()
                // 到这里为止是 app 能控制的部分；之后 provider.startProxy / setTunnelNetworkSettings
                // 由系统调度，与 flow.first 的差值即「NE 会话建立」本身的耗时（天然成本，改不动）。
                PerfDiag.milestone("session.tunnel_started")
                emit("startVPNTunnel() called — provider.startProxy should now run")
                // 隧道**真正连上**的时刻。缺了这个点就分不清「flow.first 晚」到底是
                // 隧道建立慢，还是隧道早就通了、只是机器空闲没有新连接产生——两者
                // 一个可能有优化空间、一个完全正常。有界轮询，最多 30s，只为埋点。
                observeUntilConnected(mgr)
            }
        } catch {
            let ns = error as NSError
            emit("START FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        }
    }

    /// **重启会话 = 重新绑定到当前(最新)扩展 provider**。反复热升级后系统可能把运行中的
    /// 会话继续绑在待卸载的旧 provider 实例上(流量被交给僵尸扩展 → 黑洞),等价于用户手动在
    /// 系统设置里关开一次网络扩展。这里程序化地做:停会话 → 等它真的断开 → 重新起。
    /// 用于:启动首次重绑(startOnLaunch)、版本握手发现会话绑了旧扩展、或用户点「重启接管」。
    private static func performRestart(ticket: ProxySessionIntentTicket) async {
        emit("restart(): stopping session to rebind to the current provider")
        do {
            let mgr = try await loadOrCreate()
            guard sessionCoordinator.isCurrent(ticket) else {
                emit("restart cancelled before stop: a newer capability request superseded it")
                return
            }
            mgr.connection.stopVPNTunnel()
            // 等到真的 disconnected 再起(最多 ~5s);不等的话 startVPNTunnel 可能被忽略。
            for _ in 0..<50 {
                guard sessionCoordinator.isCurrent(ticket) else {
                    emit("restart cancelled after stop: session must remain stopped")
                    return
                }
                if mgr.connection.status == .disconnected || mgr.connection.status == .invalid { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard sessionCoordinator.isCurrent(ticket) else {
                emit("restart cancelled before startVPNTunnel(): session must remain stopped")
                return
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
    private static func performStop(ticket: ProxySessionIntentTicket) async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard sessionCoordinator.isCurrent(ticket) else { return }
            remember(managers)
            for mgr in managers {
                mgr.connection.stopVPNTunnel()
            }
            if let cached = manager, managers.isEmpty {
                cached.connection.stopVPNTunnel()
            }
            emit("stopVPNTunnel() called on \(managers.count) manager(s)")
        } catch {
            guard sessionCoordinator.isCurrent(ticket) else { return }
            manager?.connection.stopVPNTunnel()
            emit("stop: loadAllFromPreferences failed (\(error.localizedDescription)), stopped cached session only")
        }
    }

    /// **紧急恢复(重置)**:停止会话并把 appidge 的透明代理配置从系统网络偏好里整个移除——
    /// 拦截彻底解除,所有应用立即恢复原生联网,**无需重启电脑**(重启电脑"能修好"正是因为
    /// 开机后没人再 startVPNTunnel;这里把同样的效果做成一个按钮,并且清掉配置本身)。
    /// 系统扩展保持安装;重新开启接管 = 重启 app 或点「启用」(会重建配置,首次重建可能再弹一次
    /// "添加 VPN/代理配置"授权)。
    private static func performReset(ticket: ProxySessionIntentTicket) async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard sessionCoordinator.isCurrent(ticket) else { return }
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

    /// 不等待系统偏好读取，先停本进程已经见过的 manager。后续 `performStop` 仍会全量加载，
    /// 覆盖“旧进程留下会话、当前进程尚未见过”的情况。
    private static func stopKnownManagersImmediately() {
        var targets = knownManagers
        if let cached = manager, !targets.contains(where: { $0 === cached }) {
            targets.append(cached)
        }
        for mgr in targets {
            mgr.connection.stopVPNTunnel()
        }
        emit("stop requested — immediately stopped \(targets.count) known session(s)")
    }

    /// app 退出路径的同步兜底(`applicationWillTerminate` 里没法 await):停掉本进程见过的**所有**
    /// 会话 manager,而不只是缓存的那一个——会话可能由别的实例(如语言切换重启出的新实例)持有,
    /// 只停一个会漏掉、留下僵尸接管全系统断网。宗旨:**UI 不在,接管就不该在**——规则没人管、出问题
    /// 没人能停,catch-all 拦截挂在系统上直到重启,正是"Chrome 断网只能重启电脑"的处境。
    /// 只停会话、不删配置,下次启动照常静默接管。
    static func stopCachedSessionForTermination() {
        sessionCoordinator.request(.stopped)
        sessionWorker?.cancel()
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

    /// 轮询到隧道 `.connected` 为止（上限 30s），记一个里程碑。**纯埋点**：不改变任何行为，
    /// 不参与启停决策，超时就放弃、不做任何补救动作。
    private static func observeUntilConnected(_ mgr: NETransparentProxyManager) {
        Task { @MainActor in
            for _ in 0..<300 {
                if mgr.connection.status == .connected {
                    PerfDiag.milestone("session.connected")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            PerfDiag.milestone("session.connected", note: "timeout-30s")
        }
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
