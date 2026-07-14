import Testing
@testable import EngineKit

/// `LoopDetector` 是纯值类型、确定性的「转发环」检测器:时间戳由调用方传入,内部不读时钟,
/// 因此每条判据都能用固定的 `now` 序列钉死。它会被扩展喂入每次「捕获」的 signature(上游端点 +
/// 目的地),同一 signature 在窗口内累计到达阈值即判定成环(见 CLAUDE.md §4 / §2 值语义约束)。
@Suite("LoopDetector — 窗口内同签名突发计数的转发环检测")
struct LoopDetectorTests {

    // MARK: 初始 / 阈值以下

    @Test("初始状态:全新检测器的首次记录永不命中")
    func initialStateNeverFlagsOnFirstRecord() {
        var detector = LoopDetector(threshold: 5, windowSeconds: 1.0)
        #expect(detector.record(signature: "s", now: 0.0) == false)
    }

    @Test("窗口内次数未达阈值 → 始终不命中")
    func underThresholdNeverFlags() {
        var detector = LoopDetector(threshold: 5, windowSeconds: 1.0)
        // 同一瞬间连打 4 次(阈值 5),累计 1..4,均在阈值之下。
        #expect(detector.record(signature: "s", now: 0.0) == false)
        #expect(detector.record(signature: "s", now: 0.0) == false)
        #expect(detector.record(signature: "s", now: 0.0) == false)
        #expect(detector.record(signature: "s", now: 0.0) == false)
    }

    // MARK: 恰好命中 / 每轮突发只报一次

    @Test("窗口内恰好达到阈值 → 在第阈值次命中一次")
    func exactlyThresholdFlagsOnce() {
        var detector = LoopDetector(threshold: 5, windowSeconds: 1.0)
        #expect(detector.record(signature: "s", now: 0.0) == false) // 1
        #expect(detector.record(signature: "s", now: 0.0) == false) // 2
        #expect(detector.record(signature: "s", now: 0.0) == false) // 3
        #expect(detector.record(signature: "s", now: 0.0) == false) // 4
        #expect(detector.record(signature: "s", now: 0.0) == true)  // 5 → 命中
    }

    @Test("命中后重置该签名窗口:越过阈值不会每次都刷屏,每轮突发只报一次")
    func flagsOncePerBurstNotEveryCallPastThreshold() {
        var detector = LoopDetector(threshold: 5, windowSeconds: 1.0)
        var flags: [Bool] = []
        for _ in 0..<10 {
            flags.append(detector.record(signature: "s", now: 0.0))
        }
        // 第 5 次与第 10 次各命中一次(命中即清空,需重新积累一整轮突发)。
        #expect(flags == [false, false, false, false, true,
                          false, false, false, false, true])
    }

    // MARK: 窗口剔除 / 慢速滴漏

    @Test("间距等于窗口的慢速滴漏:旧记录被逐条挤出 → 永不命中")
    func slowDripNeverFlags() {
        var detector = LoopDetector(threshold: 3, windowSeconds: 1.0)
        // 每次间隔 1.0s == 窗口:上一条恰好被剔除,窗内永远只剩当前这一条。
        for step in 0...10 {
            #expect(detector.record(signature: "s", now: Double(step)) == false)
        }
    }

    @Test("窗外旧记录被剔除:突发被时间间隙打断后需在新窗口内重新凑齐阈值")
    func entriesOutsideWindowAreEvicted() {
        var detector = LoopDetector(threshold: 3, windowSeconds: 1.0)
        #expect(detector.record(signature: "s", now: 0.0) == false) // c1
        #expect(detector.record(signature: "s", now: 0.5) == false) // c2
        // now=2.0:0.0 与 0.5 年龄均 ≥ 1 被剔除,仅剩自身 → 计数从头开始。
        #expect(detector.record(signature: "s", now: 2.0) == false) // c1
        #expect(detector.record(signature: "s", now: 2.4) == false) // c2
        // 2.0 / 2.4 / 2.8 三条都落在同一个 <1s 窗口内 → 命中。
        #expect(detector.record(signature: "s", now: 2.8) == true)  // c3 → 命中
    }

    @Test("窗口边界排他:年龄恰好等于窗口的记录判为窗外;略小于窗口则仍在窗内")
    func windowBoundaryIsExclusive() {
        // 恰好 1.0s 前的记录被剔除 → 只剩当前一条,阈值 2 不命中。
        var exact = LoopDetector(threshold: 2, windowSeconds: 1.0)
        #expect(exact.record(signature: "s", now: 0.0) == false)
        #expect(exact.record(signature: "s", now: 1.0) == false)
        // 略小于 1.0s(0.999s)前的记录仍保留 → 累计到 2 命中。
        var inside = LoopDetector(threshold: 2, windowSeconds: 1.0)
        #expect(inside.record(signature: "s", now: 0.0) == false)
        #expect(inside.record(signature: "s", now: 0.999) == true)
    }

    // MARK: 签名相互独立

    @Test("不同签名彼此独立计数,且某签名的命中/重置不影响其它签名")
    func differentSignaturesAreIndependent() {
        var detector = LoopDetector(threshold: 2, windowSeconds: 1.0)
        #expect(detector.record(signature: "A", now: 0.0) == false) // A c1
        #expect(detector.record(signature: "B", now: 0.0) == false) // B c1
        #expect(detector.record(signature: "A", now: 0.0) == true)  // A c2 → 命中并重置
        #expect(detector.record(signature: "B", now: 0.0) == true)  // B 不受 A 重置影响 → c2 命中
        #expect(detector.record(signature: "A", now: 0.0) == false) // A 重置后重新计数 c1
    }

    // MARK: 阈值边界

    @Test("阈值为 1:每条捕获都判定成环")
    func thresholdOfOneFlagsEveryRecord() {
        var detector = LoopDetector(threshold: 1, windowSeconds: 1.0)
        #expect(detector.record(signature: "s", now: 0.0) == true)
        #expect(detector.record(signature: "s", now: 0.0) == true)
        #expect(detector.record(signature: "s", now: 100.0) == true)
    }

    @Test("阈值 ≤ 0 被钳到 1:误配时退化为每条都命中,而非产生混乱语义")
    func thresholdBelowOneIsTreatedAsOne() {
        var zero = LoopDetector(threshold: 0, windowSeconds: 1.0)
        #expect(zero.record(signature: "s", now: 0.0) == true)
        var negative = LoopDetector(threshold: -5, windowSeconds: 1.0)
        #expect(negative.record(signature: "s", now: 0.0) == true)
    }

    // MARK: 值语义

    @Test("值语义:拷贝彼此独立,互不共享可变状态")
    func copiesAreIndependentValueTypes() {
        var original = LoopDetector(threshold: 2, windowSeconds: 1.0)
        #expect(original.record(signature: "s", now: 0.0) == false) // original c1
        var copy = original                                         // 拷贝:此刻各自都持有 c1
        #expect(copy.record(signature: "s", now: 0.0) == true)      // copy → c2 命中
        // original 未被 copy 的记录影响,仍持有自己的 c1 → 这次才凑到 c2 命中。
        #expect(original.record(signature: "s", now: 0.0) == true)
    }
}
