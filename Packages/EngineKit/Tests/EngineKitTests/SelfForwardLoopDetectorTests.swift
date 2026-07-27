import Testing
import IPCContract
@testable import EngineKit

@Suite("ProcessFamily — 进程亲缘判定(同 pid / 父子 / 兄弟 / 同进程组),多进程本地代理的同族识别")
struct ProcessFamilyTests {

    @Test("同 pid 即同族")
    func samePid() {
        let a = ProcessFamily(pid: 100)
        #expect(a.isRelated(to: ProcessFamily(pid: 100)))
    }

    @Test("父子同族:flow 进程的 ppid == 监听进程(yunti 主程序监听、子进程 xray 出站)")
    func childOfListener() {
        let listener = ProcessFamily(pid: 100)
        let child = ProcessFamily(pid: 200, parentPid: 100)
        #expect(child.isRelated(to: listener))
        #expect(listener.isRelated(to: child))
    }

    @Test("兄弟同族:共享同一个非 launchd 父进程")
    func siblingsShareParent() {
        let a = ProcessFamily(pid: 200, parentPid: 100)
        let b = ProcessFamily(pid: 300, parentPid: 100)
        #expect(a.isRelated(to: b))
    }

    @Test("launchd 兄弟不连坐:ppid 都是 1 的两个无关 GUI app 不算同族")
    func launchdChildrenAreNotSiblings() {
        let wechat = ProcessFamily(pid: 200, parentPid: 1)
        let xray = ProcessFamily(pid: 300, parentPid: 1)
        #expect(!wechat.isRelated(to: xray))
    }

    @Test("同进程组(pgid > 1)同族")
    func sameProcessGroup() {
        let a = ProcessFamily(pid: 200, parentPid: 1, groupID: 150)
        let b = ProcessFamily(pid: 300, parentPid: 1, groupID: 150)
        #expect(a.isRelated(to: b))
    }

    @Test("无关进程不同族(父不同、组不同)")
    func unrelatedProcesses() {
        let a = ProcessFamily(pid: 200, parentPid: 50, groupID: 200)
        let b = ProcessFamily(pid: 300, parentPid: 60, groupID: 300)
        #expect(!a.isRelated(to: b))
    }
}

@Suite("SelfForwardLoopDetector — 「来源即上游」确定性环判定:转发目标是来源自己 = 按定义成环")
struct SelfForwardLoopDetectorTests {

    private let xray = ProcessFamily(pid: 500, parentPid: 400)
    private let wechat = ProcessFamily(pid: 900, parentPid: 1)

    /// 预热:把 1080 端口的监听者解析结果灌进缓存。
    private func warmed(
        listener: ProcessFamily?, port: UInt16 = 1080, now: Double = 0
    ) -> SelfForwardLoopDetector {
        var detector = SelfForwardLoopDetector()
        _ = detector.evaluate(flowFamily: nil, localCandidatePorts: [port], now: now)
        detector.storeListener(listener, forPort: port, now: now)
        return detector
    }

    @Test("缓存新鲜 + 同族命中:单条 flow 即判环,零阈值零窗口")
    func freshCacheRelatedFamilyIsLoop() {
        var detector = warmed(listener: xray)
        let verdict = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 1)
        #expect(verdict.isLoop)
        #expect(verdict.portsToResolve.isEmpty)
    }

    @Test("微信场景免疫:来源与监听者无亲缘,连接率再高也不判环")
    func unrelatedSourceNeverLoops() {
        var detector = warmed(listener: xray)
        for i in 0..<1000 {
            let verdict = detector.evaluate(
                flowFamily: wechat, localCandidatePorts: [1080], now: 1 + Double(i) * 0.001
            )
            #expect(!verdict.isLoop)
        }
    }

    @Test("远程上游(无本机候选端口):不判环、不发起解析")
    func remoteUpstreamIsInert() {
        var detector = SelfForwardLoopDetector()
        let verdict = detector.evaluate(flowFamily: xray, localCandidatePorts: [], now: 0)
        #expect(!verdict.isLoop)
        #expect(verdict.portsToResolve.isEmpty)
    }

    @Test("冷缓存 fail-open:不判环,该端口进 portsToResolve;紧随的第二次调用不重复要求(解析去重)")
    func coldCacheFailsOpenAndDeduplicatesResolution() {
        var detector = SelfForwardLoopDetector()
        let first = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 0)
        #expect(!first.isLoop)
        #expect(first.portsToResolve == [1080])
        let second = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 0.01)
        #expect(second.portsToResolve.isEmpty)
    }

    @Test("解析结果「该端口无监听者」也缓存:TTL 内不再要求解析、不判环")
    func resolvedAbsenceIsCachedNegative() {
        var detector = warmed(listener: nil)
        let verdict = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 1)
        #expect(!verdict.isLoop)
        #expect(verdict.portsToResolve.isEmpty)
    }

    @Test("TTL 过期:旧值不再用于判环(pid 可能已易主),重新要求解析")
    func expiredCacheFailsOpenAndReresolves() {
        var detector = warmed(listener: xray, now: 0)
        let verdict = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 31)
        #expect(!verdict.isLoop)
        #expect(verdict.portsToResolve == [1080])
    }

    @Test("解析在途超时(解析任务挂了):超过在途时限后允许重新要求")
    func stuckResolutionRetriesAfterTimeout() {
        var detector = SelfForwardLoopDetector()
        _ = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 0)
        let during = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 5)
        #expect(during.portsToResolve.isEmpty)
        let after = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080], now: 20)
        #expect(after.portsToResolve == [1080])
    }

    @Test("flow 家族解析失败(pid 拿不到):fail-open 不判环")
    func unknownFlowFamilyFailsOpen() {
        var detector = warmed(listener: xray)
        let verdict = detector.evaluate(flowFamily: nil, localCandidatePorts: [1080], now: 1)
        #expect(!verdict.isLoop)
    }

    @Test("多候选端口(故障转移/负载均衡):任一本机候选的监听者同族即判环")
    func anyCandidatePortMatchIsLoop() {
        var detector = SelfForwardLoopDetector()
        _ = detector.evaluate(flowFamily: nil, localCandidatePorts: [1080, 8888], now: 0)
        detector.storeListener(nil, forPort: 1080, now: 0)
        detector.storeListener(xray, forPort: 8888, now: 0)
        let verdict = detector.evaluate(flowFamily: xray, localCandidatePorts: [1080, 8888], now: 1)
        #expect(verdict.isLoop)
    }

    @Test("localCandidatePorts:只认回环地址上游;链取第一跳;故障转移/负载均衡取全部候选;直连为空")
    func localCandidatePortsFiltersRoutes() {
        func server(_ id: String, _ host: String, _ port: UInt16) -> ProxyServerDTO {
            ProxyServerDTO(id: id, host: host, port: port, kind: .socks5)
        }
        let local = server("l", "127.0.0.1", 1080)
        let localhost = server("h", "localhost", 8888)
        let remote = server("r", "10.0.0.5", 1080)

        #expect(SelfForwardLoopDetector.localCandidatePorts(of: .direct).isEmpty)
        #expect(SelfForwardLoopDetector.localCandidatePorts(of: .single(local)) == [1080])
        #expect(SelfForwardLoopDetector.localCandidatePorts(of: .single(remote)).isEmpty)
        #expect(SelfForwardLoopDetector.localCandidatePorts(of: .chain([remote, local])).isEmpty)
        #expect(SelfForwardLoopDetector.localCandidatePorts(of: .chain([local, remote])) == [1080])
        #expect(SelfForwardLoopDetector.localCandidatePorts(
            of: .failover([remote, local, localhost])) == [1080, 8888])
        #expect(SelfForwardLoopDetector.localCandidatePorts(
            of: .loadBalance([localhost, remote])) == [8888])
    }

    @Test("上报节流:同一来源间隔内只报一次,过间隔再报;不同来源互不影响")
    func reportThrottlePerSource() {
        var detector = SelfForwardLoopDetector()
        let first = detector.shouldReport(sourceKey: "/opt/xray", now: 0)
        let withinInterval = detector.shouldReport(sourceKey: "/opt/xray", now: 1)
        let otherSource = detector.shouldReport(sourceKey: "/opt/other", now: 1)
        let afterInterval = detector.shouldReport(sourceKey: "/opt/xray", now: 6)
        #expect(first)
        #expect(!withinInterval)
        #expect(otherSource)
        #expect(afterInterval)
    }
}
