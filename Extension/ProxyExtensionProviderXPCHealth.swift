import Foundation
import EngineKit

/// XPC 监听器注册自检的**驱动**(决策在 ``EngineKit/XPCListenerSelfCheck``,探针 I/O 在
/// ``EngineKit/XPCFlowTransport``;拆到同类型 extension 文件是本 target 压 file_length 的既有先例)。
///
/// 要解的缺陷(2026-07-26 真机 log 实锤,80→81 升级后 100% 复现):升级换血窗口里,新扩展
/// 进程可能在新旧 launchd job 交替的竞态中被拉起,`NSXPCListener(machServiceName:)` 注册
/// **静默失败**——app 侧 bootstrap look-up 报 "No such process",app 重启无效,只有扩展进程
/// 重生才能恢复。此时配置推不进来(排除名单为空 → 本地代理流量被全量接管直连 pump,三次断网
/// 事故的同款地雷),连接事件送不出去(活动页永远空白但引擎显示 OK)。
///
/// 恢复闭环:探针失败 → 重建 listener 重试(旧 job 死掉后名字释放,进程内即可自愈)→ 额度用尽
/// 判死 → **sessionless 时 exit 让 launchd 重生进程**;有活跃会话时绝不退出(杀进程=全系统断网),
/// 带伤运行到 stopProxy(app 侧警告引导用户「重启接管」,或自愈有界重启一次),停会话后再退。
extension ProxyExtensionProvider {
    /// 首探延迟:listener `resume()` 后给 bootstrap 注册留的落定时间。
    private static let selfCheckInitialDelay: TimeInterval = 1.0
    /// 重建 listener 后的再探延迟:竞态窗口在秒级,给旧 job 让位留时间。
    private static let selfCheckRetryDelay: TimeInterval = 2.0
    /// 单次探针超时:进程内 XPC 往返正常在毫秒级,2s 足够宽。
    private static let selfCheckProbeTimeout: TimeInterval = 2.0
    /// 判死退出前的缓冲:让 stopProxy 的 completionHandler 回执先送达 NE,并给「随即而来的
    /// 新 startProxy」一个显形窗口(退出前会复查,绝不带活跃会话退出)。
    private static let exitGraceDelay: TimeInterval = 0.3

    /// startProxy 建好 transport/listener 后调用:重置自检状态并安排首个探针。
    func startListenerSelfCheck(transport: XPCFlowTransport) {
        configLock.withLock { storedListenerSelfCheck = XPCListenerSelfCheck() }
        scheduleListenerProbe(transport: transport, after: Self.selfCheckInitialDelay)
    }

    private func scheduleListenerProbe(transport: XPCFlowTransport, after delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self, weak transport] in
            // transport 已被换掉(stop→start / start→start 防御路径)= 本轮自检作废,新一轮已自行启动。
            guard let self, let transport, self.transport === transport else { return }
            transport.probeSelfRegistration(timeoutSeconds: Self.selfCheckProbeTimeout) { [weak self, weak transport] ok in
                guard let self, let transport, self.transport === transport else { return }
                self.handleListenerProbeResult(ok, transport: transport)
            }
        }
    }

    private func handleListenerProbeResult(_ success: Bool, transport: XPCFlowTransport) {
        let directive = configLock.withLock { storedListenerSelfCheck.recordProbe(success: success) }
        switch directive {
        case .none:
            ExtDiag.log("xpc self-check: listener registration verified (owned by this process)")
        case .retryAfterRecreate:
            ExtDiag.log("xpc self-check: probe failed — recreating listener and retrying")
            transport.recreateListener()
            scheduleListenerProbe(transport: transport, after: Self.selfCheckRetryDelay)
        case .registrationFailed:
            ExtDiag.log("xpc self-check: listener registration FAILED after all attempts — "
                + "app cannot reach this provider (bootstrap look-up will report 'No such process')")
            exitIfRegistrationFailed(reason: "self-check exhausted")
        }
    }

    /// 注册已判死时,若当前 sessionless 就(延迟并复查后)退出进程,让 launchd 重生;
    /// 有活跃会话则只记日志、带伤运行(fail-open),等 stopProxy 再来一次。健康/待定状态下 no-op。
    func exitIfRegistrationFailed(reason: String) {
        let (failed, shouldExit) = configLock.withLock {
            (storedListenerSelfCheck.verdict == .failed,
             storedListenerSelfCheck.shouldExitProcess(sessionActive: storedSessionActive))
        }
        guard failed else { return }
        guard shouldExit else {
            ExtDiag.log("xpc self-check: exit deferred (session active — killing now would black-hole "
                + "the whole system); will exit after stopProxy. reason=\(reason)")
            return
        }
        ExtDiag.log("xpc self-check: sessionless with dead listener — exiting so launchd respawns "
            + "a fresh process with a clean bootstrap registration. reason=\(reason)")
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGraceDelay) { [weak self] in
            guard let self else { return }
            // 退出前复查:缓冲期间若有新 startProxy 进来(「重启接管」的 stop→start 竞态),
            // 新会话已活跃或自检已被重置为待定——都绝不退出。
            let stillExitable = self.configLock.withLock {
                self.storedListenerSelfCheck.shouldExitProcess(sessionActive: self.storedSessionActive)
            }
            guard stillExitable else {
                ExtDiag.log("xpc self-check: exit aborted — a new session/self-check started meanwhile")
                return
            }
            exit(0)
        }
    }
}
