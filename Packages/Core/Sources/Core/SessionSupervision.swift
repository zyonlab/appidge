import Foundation

/// 接管**会话**的启动后监督决策。
///
/// 扩展「装上并获批」只是前提；真正让系统把出站流量交给 provider，还需要 app 侧建立
/// `NETransparentProxyManager` 会话并 `startVPNTunnel()`。会话可能在 app 不知情的情况下被停掉
/// —— 最典型的是语言切换：`LanguageBootstrap.relaunch()` 开出接班实例后，老实例退出时
/// `stopCachedSessionForTermination()` 会停掉**所有**已知会话，而 NE 配置是按 app 全局一份，
/// 于是接班者刚起的会话被前任停掉，扩展再收不到任何 flow（活动列表空）。
///
/// 这里只做判定、不做副作用，且**可反复评估**：不假设「交接一定成功」，只要状态不对就把会话起回来。
public enum SessionSupervisionDecision: Sendable, Equatable {
    /// 无需动作。
    case none
    /// 能力开放、扩展在跑，会话却没连上 → 把会话起回来。
    case startSession
}

extension AppState {
    /// 启动后（及任何需要复查的时机）判断接管会话是否需要被拉起。
    ///
    /// 三个前置全部满足才动作，任一不满足都返回 `.none`：
    /// - 能力已开放（``isLicenseActive``）且已完成引导 —— 否则会话本就不该在跑；
    /// - 扩展确实在跑（``ExtensionActivation/isRunning``）—— 没获批时起会话没有意义，
    ///   该把用户指向系统设置，而不是反复尝试；
    /// - 会话当前没连上 —— 已连上就绝不无谓重启接管（重启接管会打断在途连接）。
    ///
    /// - Parameter isSessionConnected: 由 App 层查询 `NETransparentProxyManager` 得到的真实会话状态。
    public func sessionSupervisionDecision(isSessionConnected: Bool) -> SessionSupervisionDecision {
        guard isLicenseActive, hasCompletedOnboarding else { return .none }
        guard extensionActivation.isRunning else { return .none }
        return isSessionConnected ? .none : .startSession
    }
}

/// 语言切换重启时的**会话交接**策略。
///
/// 两条退出路径语义正好相反，必须区分：
/// - **普通退出 / Sparkle 升级重启** → 停掉所有会话。UI 不在，接管就不该在；升级时扩展二进制
///   会被整个替换，把老会话跨着 provider 替换带过去正是「绑死旧 provider」的黑洞成因。
/// - **语言切换重启** → 交接给接班者。扩展没有变，接班实例已经起来并持有同一份全局 NE 配置；
///   此时再停会话，停掉的正是接班者刚起的那个。
public enum RelaunchHandoff {
    /// 是否可以交接退出。
    public enum Decision: Sendable, Equatable {
        /// 接班没确认成功 —— 留在原地继续运行，绝不交接。
        case abortStayRunning
        /// 接班已确认 —— 可以交接并退出。
        case handOffAndTerminate
    }

    /// 退出时如何处置会话。
    public enum TerminationPolicy: Sendable, Equatable {
        /// 停掉本进程已知的所有会话（普通退出 / 升级重启）。
        case stopAllSessions
        /// 保留会话给接班实例（语言切换交接）。
        case keepSessionForSuccessor
    }

    /// **安全红线**：只有确认接班实例真的启动了才交接。
    ///
    /// 原实现把 `NSWorkspace.openApplication` 的两个回调参数全忽略、无条件 `NSApp.terminate`。
    /// 在「退出即停会话」的旧语义下，这最多是白退一次（会话已停，网络是好的）；一旦改成交接语义，
    /// 同一条路径就会变成：app 退了、接班者没起来、**会话还在跑且没有任何 UI 能停它**
    /// —— catch-all 接管挂死整个系统，用户只能重启电脑。所以失败必须留在原地。
    public static func decide(successorLaunched: Bool) -> Decision {
        successorLaunched ? .handOffAndTerminate : .abortStayRunning
    }

    /// 退出路径的会话处置。默认（非交接）一律停光，保持既有的「UI 不在，接管不在」保证。
    public static func terminationPolicy(isHandingOff: Bool) -> TerminationPolicy {
        isHandingOff ? .keepSessionForSuccessor : .stopAllSessions
    }
}
