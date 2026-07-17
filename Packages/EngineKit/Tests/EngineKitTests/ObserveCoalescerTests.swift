import Testing
@testable import EngineKit

@Suite("ObserveCoalescer — 观测事件确定性 id + 时间节流")
struct ObserveCoalescerTests {

    @Test("同一 (进程,主机,端口) 的 id 恒定,不同任一维度则不同")
    func stableIDIsDeterministic() {
        let idOne = ObserveCoalescer.stableID(processID: "a.out", host: "1.2.3.4", port: 443)
        let idSame = ObserveCoalescer.stableID(processID: "a.out", host: "1.2.3.4", port: 443)
        let idDiffPort = ObserveCoalescer.stableID(processID: "a.out", host: "1.2.3.4", port: 80)
        #expect(idOne == idSame)
        #expect(idOne != idDiffPort)
    }

    @Test("首次投递放行;interval 内同 key 抑制;越过 interval 再放行")
    func throttlesWithinInterval() {
        var coalescer = ObserveCoalescer(interval: 2.0)
        let key = "observe:a|h|443"
        let first = coalescer.shouldEmit(key: key, now: 100.0)
        let within1 = coalescer.shouldEmit(key: key, now: 100.5)
        let within2 = coalescer.shouldEmit(key: key, now: 101.9)
        let atThreshold = coalescer.shouldEmit(key: key, now: 102.0)
        let afterThreshold = coalescer.shouldEmit(key: key, now: 102.1)
        #expect(first)
        #expect(!within1)
        #expect(!within2)
        #expect(atThreshold)
        #expect(!afterThreshold)
    }

    @Test("不同 key 各自独立节流")
    func keysAreIndependent() {
        var coalescer = ObserveCoalescer(interval: 2.0)
        let k1First = coalescer.shouldEmit(key: "k1", now: 100.0)
        let k2First = coalescer.shouldEmit(key: "k2", now: 100.0)
        let k1Within = coalescer.shouldEmit(key: "k1", now: 100.5)
        #expect(k1First)
        #expect(k2First)
        #expect(!k1Within)
    }

    @Test("key 表超上限时清理过期条目,不无限增长")
    func prunesExpiredWhenOverCapacity() {
        var coalescer = ObserveCoalescer(interval: 2.0, maxKeys: 3)
        // 三个旧 key 在 t=100 投过,到 t=200 全部过期。
        for k in ["a", "b", "c"] { _ = coalescer.shouldEmit(key: k, now: 100.0) }
        // t=200 投第四个 key:触发 prune,过期的 a/b/c 被清;不 crash、正常放行。
        let d = coalescer.shouldEmit(key: "d", now: 200.0)
        let aAgain = coalescer.shouldEmit(key: "a", now: 200.0)
        #expect(d)
        #expect(aAgain)
    }
}
