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
        onStateChange?(.activating)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        activatorLogger.log("submitted activation request for \(self.extensionBundleID, privacy: .public)")
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
        activatorLogger.log("needs user approval in System Settings > Privacy & Security")
        Task { @MainActor in self.report(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let reason = error.localizedDescription
        activatorLogger.error("activation failed: \(reason, privacy: .public)")
        Task { @MainActor in self.report(.failed(reason: reason)) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activatorLogger.log("activation finished: \(String(describing: result), privacy: .public)")
        // .completed / .willCompleteAfterReboot 都视作已接管（重启后生效那种也算装上了）。
        Task { @MainActor in self.report(.active) }
    }
}
