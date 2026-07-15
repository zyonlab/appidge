import Foundation
@preconcurrency import NetworkExtension
import EngineKit
import IPCContract

/// UDP 处理拆到独立文件(压 `ProxyExtensionProvider.swift` 的 file_length,同 `TCPFlowPump.swift`
/// 的既有先例)——跨文件访问 provider 的成员,故那几个成员在主文件里放宽到非 `private`
/// (`private` 只在同文件内的 extension 才透明)。
extension ProxyExtensionProvider {
    /// UDP/QUIC:按 3 态策略处理。allowDirect→不接管(原生直连);block→接管并 drop(止漏);
    /// proxy→经 SOCKS5 UDP ASSOCIATE 中继。
    func blockOrAllowUDPFlow(_ flow: NEAppProxyUDPFlow) -> Bool {
        let sourceID = flow.metaData.sourceAppSigningIdentifier
        let active = proxyConfig?.activeServer
        let disposition = UDPFlowPolicy.disposition(
            sourceIdentifier: sourceID,
            ownIdentifiers: ownIdentifiers,
            perProcessRule: perProcessRules[sourceID],
            udpPolicy: udpPolicy,
            upstreamIsSOCKS5: active?.kind == .socks5
        )
        switch disposition {
        case .allowDirect:
            return false // 不接管,UDP 原生直连。
        case .block:
            flowLogger.log("blocking UDP flow from \(sourceID, privacy: .public)")
            flow.open(withLocalFlowEndpoint: nil) { error in
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
            return true
        case .proxy:
            // disposition 已保证 active 是 SOCKS5;兜底再判一次。
            guard let active, active.kind == .socks5 else {
                flow.open(withLocalFlowEndpoint: nil) { error in
                    flow.closeReadWithError(error); flow.closeWriteWithError(error)
                }
                return true
            }
            startUDPRelay(flow: flow, proxy: active)
            return true
        }
    }

    /// 建一个 SOCKS5 UDP 中继并按 id 持有(结束时经 onFinished 用同一 id 移除)。id 是 let,可安全
    /// 被 @Sendable 的 onFinished 捕获(不像捕获 relay 变量那样触发并发告警)。
    func startUDPRelay(flow: NEAppProxyUDPFlow, proxy: ProxyServerDTO) {
        let id = UUID().uuidString
        let relay = SOCKS5UDPRelay(flow: flow, proxy: proxy) { [weak self] in
            guard let self else { return }
            self.configLock.withLock { _ = self.storedUDPRelays.removeValue(forKey: id) }
        }
        configLock.withLock { storedUDPRelays[id] = relay }
        Task { await relay.start() }
    }
}
