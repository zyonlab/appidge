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

    /// 停止会话(不删配置)。
    static func stop() async {
        manager?.connection.stopVPNTunnel()
        emit("stopVPNTunnel() called")
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
