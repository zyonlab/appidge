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

    /// 建/存配置并启动会话。幂等:已在跑就不重复启。
    static func start() async {
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
    static func restart() async {
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
                emit("reset: no saved managers; stopped cached session if any")
                return
            }
            for mgr in managers {
                mgr.connection.stopVPNTunnel()
                try await mgr.removeFromPreferences()
            }
            manager = nil
            emit("reset: stopped and removed \(managers.count) manager(s) — interception fully torn down")
        } catch {
            emit("RESET FAILED: \(error.localizedDescription)")
        }
    }

    /// app 退出路径的同步兜底(`applicationWillTerminate` 里没法 await):直接停本会话缓存的
    /// manager 的会话。宗旨:**UI 不在,接管就不该在**——规则没人管、出问题没人能停,catch-all
    /// 拦截挂在系统上直到重启,正是"Chrome 断网只能重启电脑"的处境。配置保留,下次启动照常接管。
    static func stopCachedSessionForTermination() {
        manager?.connection.stopVPNTunnel()
        emit("stopVPNTunnel() on app termination")
    }

    /// 当前会话是否在跑(UI 可据此显示是否真正在接管流量)。
    static func isRunning() async -> Bool {
        guard let mgr = try? await loadOrLoadFirst() else { return false }
        return mgr.connection.status == .connected
    }

    private static func loadOrLoadFirst() async throws -> NETransparentProxyManager? {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        manager = managers.first ?? manager
        return manager
    }

    private static func loadOrCreate() async throws -> NETransparentProxyManager {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let mgr = managers.first ?? NETransparentProxyManager()
        // NETransparentProxyManager 用 NETunnelProviderProtocol + providerBundleIdentifier 指向系统扩展。
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleID
        // serverAddress 必须非空;透明代理里只是占位、不代表真实服务器。
        proto.serverAddress = "appidge (per-process)"
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "appidge · 按进程代理"
        mgr.isEnabled = true
        try await mgr.saveToPreferences()   // 首次在此弹「添加配置」授权
        try await mgr.loadFromPreferences() // 存后必须重新 load 才能 start
        manager = mgr
        emit("manager saved+loaded; provider=\(extensionBundleID) enabled=\(mgr.isEnabled)")
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
