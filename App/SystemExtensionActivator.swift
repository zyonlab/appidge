import Foundation
import SystemExtensions
import os.log
import Core

/// 真实提交系统扩展激活请求（不是空壳）。这是 CLAUDE.md 第 4 节里"唯一 loop 物理上
/// 做不了的一步"的代码侧：请求一旦提交，用户必须去「系统设置 → 隐私与安全性」点
/// 「允许」，这是系统强制的人工步骤，没有 API 能绕过。
///
/// delegate 的每个回调都翻成一个 ``ExtensionActivation`` 经 `onStateChange` 回灌 store，
/// 状态栏据此如实显示"安装中 / 待批准 / 已接管 / 安装失败"，而不是永远默认"引擎正常"。
private let activatorLogger = Logger(subsystem: "com.appidge.app", category: "SystemExtensionActivator")

@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionActivator()

    /// 激活状态变化的回调（App 层把它接到 `store.dispatch(.extensionActivationChanged($0))`）。
    var onStateChange: ((ExtensionActivation) -> Void)?

    private let extensionBundleID = "com.appidge.app.ProxyExtension"

    /// 提交激活请求。首次引导时点「启用」会走它；每次启动也用它（幂等）把状态栏校准到
    /// 真实情况——已批准会立刻回 `.active`，未批准回 `.needsApproval`，缺 entitlement/签名
    /// 不符回 `.failed`。因为激活状态不持久化（和引擎健康度一样是运行时状态）。
    func activate() {
        diagnose()
        onStateChange?(.activating)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        emit("submitted activation request for \(extensionBundleID)")
    }

    /// 诊断:打印 app **自己看到的** bundle 路径 + `Contents/Library/SystemExtensions` 目录里的
    /// 实际内容(每个 .systemextension 的 id / 版本 / 是否 NE / 包类型)。写 stderr(从终端跑可抓)
    /// + os.Logger。用来定位 "Extension not found" 到底是「app 看不到自己的扩展」还是别的。
    func emit(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        activatorLogger.log("\(s, privacy: .public)")
    }

    func diagnose() {
        let fm = FileManager.default
        let b = Bundle.main
        var s = "=== APPIDGE-SYSEXT-DIAG ===\n"
        s += "app bundlePath: \(b.bundlePath)\n"
        s += "app bundleID:   \(b.bundleIdentifier ?? "nil")\n"
        s += "requested id:   \(extensionBundleID)\n"
        let dir = b.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        s += "sysext dir:     \(dir.path)  exists=\(fm.fileExists(atPath: dir.path))\n"
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for it in items {
                s += "  • \(it.lastPathComponent)\n"
                let info = it.appendingPathComponent("Contents/Info.plist")
                if let d = NSDictionary(contentsOf: info) {
                    s += "    id=\(d["CFBundleIdentifier"] ?? "nil") ver=\(d["CFBundleVersion"] ?? "nil")"
                    s += " NE=\(d["NetworkExtension"] != nil) pkg=\(d["CFBundlePackageType"] ?? "nil")\n"
                } else {
                    s += "    (Info.plist unreadable: \(info.path))\n"
                }
            }
        } else {
            s += "  (contentsOfDirectory failed — app can't list its own SystemExtensions dir)\n"
        }
        s += "==========================="
        emit(s)
    }

    /// delegate 回调是 `nonisolated`（但 queue 是 `.main`）；统一跳回 MainActor 再回灌，
    /// 满足 Swift 6 严格并发。
    private func report(_ activation: ExtensionActivation) {
        onStateChange?(activation)
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        FileHandle.standardError.write(Data("SEA: needs user approval\n".utf8))
        activatorLogger.log("needs user approval in System Settings > Privacy & Security")
        Task { @MainActor in self.report(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        let detail = "activation FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) userInfo=\(ns.userInfo)"
        FileHandle.standardError.write(Data((detail + "\n").utf8))
        activatorLogger.error("\(detail, privacy: .public)")
        Task { @MainActor in self.report(.failed(reason: error.localizedDescription)) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        FileHandle.standardError.write(Data("SEA: activation finished result=\(result.rawValue)\n".utf8))
        activatorLogger.log("activation finished: \(String(describing: result), privacy: .public)")
        // .completed / .willCompleteAfterReboot 都视作已接管（重启后生效那种也算装上了）。
        Task { @MainActor in self.report(.active) }
    }
}
