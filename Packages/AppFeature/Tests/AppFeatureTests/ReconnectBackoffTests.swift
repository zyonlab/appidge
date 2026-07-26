import Testing
@testable import AppFeature

/// XPC 重连退避策略(纯值)。背景:扩展在系统设置里被停用后 mach service 无人监听,连接
/// 立即失效;没有退避时,send() 的懒重连(无延迟)× 每次新建连接触发 onConnect → resync
/// → 6 条 send → 又新建连接……自持风暴把 app 本体打到 100%+ CPU(真机实锤)。
@Suite("ReconnectBackoff — 指数退避,封顶 30s,链路证实健康即归零")
struct ReconnectBackoffTests {

    @Test("连续断开:1s → 2s → 4s → 8s → 16s → 30s(封顶)")
    func exponentialWithCap() {
        var backoff = ReconnectBackoff()
        var delays: [Double] = []
        for _ in 0..<7 {
            backoff.recordDrop()
            delays.append(backoff.delaySeconds)
        }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test("reset 归零:下一次断开又从 1s 起步")
    func resetRestarts() {
        var backoff = ReconnectBackoff()
        for _ in 0..<5 { backoff.recordDrop() }
        backoff.reset()
        backoff.recordDrop()
        #expect(backoff.delaySeconds == 1)
    }

    @Test("从未断开时无需等待(0s)")
    func freshHasNoDelay() {
        #expect(ReconnectBackoff().delaySeconds == 0)
    }

    // MARK: - 通道不可达判定(升级换血窗口的监听器注册失败)
    //
    // 之前对连接失败只有**静默重试**——扩展监听器注册失败(bootstrap look-up "No such process")
    // 时 app 永远重试、永远不告诉用户,活动页空白但引擎显示 OK。现在把「连续掉线过阈值」
    // 判成通道不可达,翻转沿回灌 store 供 UI 警告 + 自愈。

    @Test("连续掉线不足阈值(3 次)仍视为可达——正常重连抖动不误报")
    func fewDropsStillReachable() {
        var backoff = ReconnectBackoff()
        backoff.recordDrop()
        #expect(!backoff.isChannelConsideredUnreachable)
        backoff.recordDrop()
        #expect(!backoff.isChannelConsideredUnreachable)
    }

    @Test("连续掉线达到 3 次 → 判为不可达")
    func threeDropsUnreachable() {
        var backoff = ReconnectBackoff()
        for _ in 0..<3 { backoff.recordDrop() }
        #expect(backoff.isChannelConsideredUnreachable)
    }

    @Test("收到扩展真实消息(reset)即恢复可达")
    func resetRestoresReachability() {
        var backoff = ReconnectBackoff()
        for _ in 0..<5 { backoff.recordDrop() }
        backoff.reset()
        #expect(!backoff.isChannelConsideredUnreachable)
    }
}
