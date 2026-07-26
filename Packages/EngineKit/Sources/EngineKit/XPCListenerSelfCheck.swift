import Foundation

/// 扩展侧 XPC 监听器注册自检的**决策**(纯值,单测见 XPCListenerSelfCheckTests;探针 I/O 在
/// ``XPCFlowTransport/probeSelfRegistration(timeoutSeconds:completion:)``,驱动在
/// `Extension/ProxyExtensionProviderXPCHealth.swift`)。
///
/// 要解的缺陷(2026-07-26 真机实锤,80→81 升级 100% 复现):系统扩展升级换血窗口里,新扩展
/// 进程可能在新旧 launchd job 交替的竞态中被拉起,`NSXPCListener(machServiceName:)` 注册失败
/// ——app 侧 bootstrap look-up 报 "No such process",app 重启无效,只有扩展进程重生才能恢复。
/// 扩展自己毫无感知:配置推不进来(排除名单为空 → 本地代理流量被全量接管直连 pump),
/// 连接事件送不出去(活动页永远空白但引擎显示 OK)。
///
/// 决策规则:
/// - 探针成功 → `healthy`,不再动作;
/// - 失败且额度未尽 → 重建 listener 再探(旧 job 可能刚好死掉、mach 名字已释放,进程内即可自愈);
/// - 额度用尽 → `failed`(注册确实起不来,进程内无解);
/// - **`failed` 且 sessionless 才允许 exit** 让 launchd 重生进程——有活跃会话时杀进程 =
///   全系统断网(升级黑洞同款),只能等 stopProxy 之后再退。
public struct XPCListenerSelfCheck: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// 还在探测(含重试途中)。
        case pending
        /// 探针证实监听器注册成功、由本进程持有。
        case healthy
        /// 重试额度用尽仍失败——注册起不来,进程内无解,等 sessionless 退出重生。
        case failed
    }

    /// `recordProbe` 返回给驱动方的下一步动作。
    public enum Directive: Sendable, Equatable {
        /// 无需动作(健康)。
        case none
        /// 重建 listener 后再探一次。
        case retryAfterRecreate
        /// 判死:记录状态,sessionless 时退出重生(见 ``shouldExitProcess(sessionActive:)``)。
        case registrationFailed
    }

    public private(set) var verdict: Verdict = .pending
    private var consecutiveFailures = 0
    /// 总探测额度(首次 + 重试)。默认 3:真机竞态窗口在秒级,两轮重建重试足以覆盖
    /// 「旧 job 稍后死掉」的自愈窗口;再多只是拖延必然的重生。
    public let maxAttempts: Int

    public init(maxAttempts: Int = 3) {
        self.maxAttempts = maxAttempts
    }

    public mutating func recordProbe(success: Bool) -> Directive {
        if success {
            verdict = .healthy
            consecutiveFailures = 0
            return .none
        }
        consecutiveFailures += 1
        if consecutiveFailures >= maxAttempts {
            verdict = .failed
            return .registrationFailed
        }
        verdict = .pending
        return .retryAfterRecreate
    }

    /// 是否该退出进程让 launchd 重生。只有「判死 + 无活跃会话」才允许——有会话时杀进程
    /// 等于把全系统流量拽进黑洞,宁可带伤运行(fail-open)并靠 app 侧警告引导用户重启接管。
    public func shouldExitProcess(sessionActive: Bool) -> Bool {
        verdict == .failed && !sessionActive
    }
}
