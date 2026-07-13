import Foundation
import SystemExtensions
import os.log

/// 真实提交系统扩展激活请求（不是空壳）。这是 CLAUDE.md 第 4 节里"唯一 loop 物理上
/// 做不了的一步"的代码侧：请求一旦提交，用户必须去「系统设置 → 隐私与安全性」点
/// 「允许」，这是系统强制的人工步骤，没有 API 能绕过。
private let activatorLogger = Logger(subsystem: "com.appidge.app", category: "SystemExtensionActivator")

@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionActivator()

    private let extensionBundleID = "com.appidge.app.ProxyExtension"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        activatorLogger.log("submitted activation request for \(self.extensionBundleID, privacy: .public)")
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
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activatorLogger.error("activation failed: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activatorLogger.log("activation finished: \(String(describing: result), privacy: .public)")
    }
}
