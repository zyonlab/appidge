import Core
import IPCContract

/// 纯函数翻译层：把扩展推来的 wire-format `IPCContract.ExtensionToAppMessage`
/// 翻成 store 能吃的 `[Core.Action]`。Core 零依赖（不能直接认识 IPCContract 的类型），
/// 所以这层住在 AppFeature——既能 import Core 也能 import IPCContract，是两者之间唯一的桥。
/// 不碰 IPCReceiver/Store/Transport：纯映射，无副作用，方便单测穷举每个分支。
public enum ExtensionMessageHandling {
    public static func actions(for message: IPCContract.ExtensionToAppMessage) -> [Core.Action] {
        switch message {
        case .flowStatsBatch(let batch):
            let deltas = Dictionary(
                uniqueKeysWithValues: batch.entries.map { entry in
                    (
                        Core.ProcessID(entry.processID.value),
                        Core.FlowStatsDelta(bytesUpDelta: entry.bytesUpDelta, bytesDownDelta: entry.bytesDownDelta)
                    )
                }
            )
            return [.flowStatsDeltaReceived(deltas)]

        case .diagnosticResult(let result):
            return [
                .diagnosticResultReceived(
                    processID: Core.ProcessID(result.processID.value),
                    kind: coreDiagnosticKind(from: result.kind),
                    passed: result.passed,
                    detail: result.detail
                )
            ]

        case .engineFailure(let reason):
            return [.engineFailure(reason: reason)]
        }
    }

    /// 穷举 switch（不带 default）：DiagnosticKindDTO 以后新增 case 时这里编译报错，
    /// 而不是悄悄漏映射一个诊断类型。
    private static func coreDiagnosticKind(from dto: IPCContract.DiagnosticKindDTO) -> Core.DiagnosticKind {
        switch dto {
        case .ruleHit: .ruleHit
        case .actuallyProxied: .actuallyProxied
        case .upstreamReachable: .upstreamReachable
        case .dnsResolution: .dnsResolution
        case .udpIPv6QuicLeak: .udpIPv6QuicLeak
        case .envConflict: .envConflict
        }
    }

    /// 反方向：UI dispatch `.requestDiagnostic` 之后，effectHandler 要把 Core.DiagnosticKind
    /// 翻回 wire-format 才能通过 AppSideTransport 发给扩展。同样是穷举 switch，不带 default。
    public static func dtoDiagnosticKind(from coreKind: Core.DiagnosticKind) -> IPCContract.DiagnosticKindDTO {
        switch coreKind {
        case .ruleHit: .ruleHit
        case .actuallyProxied: .actuallyProxied
        case .upstreamReachable: .upstreamReachable
        case .dnsResolution: .dnsResolution
        case .udpIPv6QuicLeak: .udpIPv6QuicLeak
        case .envConflict: .envConflict
        }
    }

    public static func diagnosticRequestMessage(
        processID: Core.ProcessID, kinds: [Core.DiagnosticKind]
    ) -> IPCContract.AppToExtensionMessage {
        .requestDiagnostic(
            IPCContract.DiagnosticRequestDTO(
                processID: IPCContract.ProcessIdentifierDTO(processID.value),
                kinds: kinds.map(dtoDiagnosticKind(from:))
            )
        )
    }
}
