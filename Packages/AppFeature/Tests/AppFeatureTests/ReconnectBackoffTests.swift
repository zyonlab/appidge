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
}
