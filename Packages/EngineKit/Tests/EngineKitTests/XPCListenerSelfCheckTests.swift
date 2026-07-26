import Testing
@testable import EngineKit

/// 扩展侧 XPC 监听器注册自检的**决策**逻辑(纯值)。
///
/// 背景(2026-07-26 真机 log 实锤,80→81 升级后 100% 复现):系统扩展升级换血窗口里,
/// 新扩展进程可能在新旧 launchd job 交替的竞态中被拉起,`NSXPCListener(machServiceName:)`
/// 注册失败——app 侧 bootstrap look-up 报 "No such process",且 **app 重启无效,只有扩展
/// 进程重生才能恢复**。扩展自己却毫无感知,继续以空排除名单接管流量(xray 被全量接管直连
/// pump,90 秒 5139 条——三次断网事故的同款性能地雷)。
///
/// 自检机制:transport 建 listener 后向同一 mach service 发进程内探针(delegate 按 pid 识别);
/// 失败先重建 listener 重试(旧 job 可能刚好死掉、名字已释放,进程内即可自愈),额度用尽判死。
/// **判死后只有 sessionless 才允许 exit**——有活跃会话时杀进程 = 全系统断网
/// (见记忆 appidge-upgrade-blackhole),只能等 stopProxy 之后再退,让 launchd 重生进程。
@Suite("XPC 监听器注册自检决策")
struct XPCListenerSelfCheckTests {

    @Test("初始待定:未探测前不判死、任何情况都不退出")
    func initialPendingNeverExits() {
        let check = XPCListenerSelfCheck()
        #expect(check.verdict == .pending)
        #expect(!check.shouldExitProcess(sessionActive: false))
        #expect(!check.shouldExitProcess(sessionActive: true))
    }

    @Test("探针成功 → 健康,不再需要动作")
    func successIsHealthy() {
        var check = XPCListenerSelfCheck()
        #expect(check.recordProbe(success: true) == XPCListenerSelfCheck.Directive.none)
        #expect(check.verdict == .healthy)
        #expect(!check.shouldExitProcess(sessionActive: false))
    }

    @Test("失败但额度未尽 → 重建 listener 再探(旧 job 死掉后名字已释放,进程内即可自愈)")
    func failureRetriesWithRecreate() {
        var check = XPCListenerSelfCheck(maxAttempts: 3)
        #expect(check.recordProbe(success: false) == .retryAfterRecreate)
        #expect(check.verdict == .pending)
        #expect(check.recordProbe(success: false) == .retryAfterRecreate)
        #expect(check.verdict == .pending)
        #expect(!check.shouldExitProcess(sessionActive: false))
    }

    @Test("连续失败额度用尽 → 判死(registrationFailed)")
    func exhaustedFailuresGiveUp() {
        var check = XPCListenerSelfCheck(maxAttempts: 3)
        _ = check.recordProbe(success: false)
        _ = check.recordProbe(success: false)
        #expect(check.recordProbe(success: false) == .registrationFailed)
        #expect(check.verdict == .failed)
    }

    @Test("判死 + sessionless → 允许退出重生;有活跃会话 → 绝不退出(杀进程=全系统断网)")
    func exitOnlyWhenSessionless() {
        var check = XPCListenerSelfCheck(maxAttempts: 1)
        _ = check.recordProbe(success: false)
        #expect(check.verdict == .failed)
        #expect(check.shouldExitProcess(sessionActive: false))
        #expect(!check.shouldExitProcess(sessionActive: true))
    }

    @Test("重试途中一次成功即恢复健康,失败计数清零")
    func recoveryMidwayResets() {
        var check = XPCListenerSelfCheck(maxAttempts: 2)
        _ = check.recordProbe(success: false)
        #expect(check.recordProbe(success: true) == XPCListenerSelfCheck.Directive.none)
        #expect(check.verdict == .healthy)
        // 计数已清零:再失败一次只是重试,不会直接判死。
        #expect(check.recordProbe(success: false) == .retryAfterRecreate)
    }

    @Test("判死后再报失败仍是判死(幂等,驱动方多报无害)")
    func failedStaysFailed() {
        var check = XPCListenerSelfCheck(maxAttempts: 1)
        _ = check.recordProbe(success: false)
        #expect(check.recordProbe(success: false) == .registrationFailed)
        #expect(check.verdict == .failed)
    }
}
