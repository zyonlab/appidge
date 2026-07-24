import Foundation
import Testing
import Core
@testable import AppFeature

/// 端到端：Store（@MainActor 单向数据流）+ 纯 reducer + 注入两份内存锚点的 LicenseEffectHandler，
/// 驱动首启记名 → 双锚点落地 → 删一份仍判「已开始」，以及试用期功能开放。时间用固定时钟。
@Suite("Trial flow — Store + reducer + handler + dual anchors end to end")
struct TrialFlowIntegrationTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    private func makeStore(
        clockNow: Date,
        anchorA: InMemoryTrialAnchorStore,
        anchorB: InMemoryTrialAnchorStore,
        trialConfig: TrialConfig = .default
    ) async -> Store {
        let handler = LicenseEffectHandler(
            apiClient: MockLicenseAPIClient(),
            keychain: InMemoryLicenseKeychainStore(),
            clock: FixedLicenseClock(now: clockNow),
            config: LicenseClientConfig(instanceName: "appidge-install-test", appVersion: "9.9.9"),
            openCheckout: { _ in },
            trialAnchorStores: [anchorA, anchorB]
        )
        return await MainActor.run {
            Store(initialState: AppState(trialConfig: trialConfig), effectHandler: { await handler.handle($0) })
        }
    }

    private func waitForPhase(_ store: Store, _ predicate: @escaping @Sendable (LicensePhase) -> Bool) async -> LicensePhase {
        for _ in 0..<200 {
            let phase = await MainActor.run { store.state.licensePhase }
            if predicate(phase) { return phase }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await MainActor.run { store.state.licensePhase }
    }

    private func isTrial(_ phase: LicensePhase) -> Bool {
        if case .trial = phase { return true } else { return false }
    }

    @Test("first launch names now, opens trial, and writes BOTH anchors")
    func firstLaunchWritesBothAnchors() async {
        let a = InMemoryTrialAnchorStore()
        let b = InMemoryTrialAnchorStore()
        let store = await makeStore(clockNow: t0, anchorA: a, anchorB: b)

        await MainActor.run { store.dispatch(.trialLoadRequested) }
        let phase = await waitForPhase(store, isTrial)
        #expect(phase == .trial(daysLeft: 7))
        #expect(await MainActor.run { store.state.isLicenseActive })   // 试用期功能开放
        #expect(await a.current()?.firstLaunchAt == t0)                // 两份锚点都落地
        #expect(await b.current()?.firstLaunchAt == t0)
    }

    @Test("deleting one anchor still counts as started (no reset) and self-heals it back")
    func deleteOneAnchorStillStarted() async {
        let a = InMemoryTrialAnchorStore()
        let b = InMemoryTrialAnchorStore()
        // 第一次启动：记名 t0。
        let store1 = await makeStore(clockNow: t0, anchorA: a, anchorB: b)
        await MainActor.run { store1.dispatch(.trialLoadRequested) }
        _ = await waitForPhase(store1, isTrial)

        // 用户删掉锚点 A，把系统时间调回 t0 想重置；锚点 B 仍在。
        await a.wipe()
        #expect(await a.current() == nil)

        // 第六天再启动（即便时钟被调回也一样，这里模拟诚实的第六天）。
        let day6 = t0.addingTimeInterval(6 * 86_400)
        let store2 = await makeStore(clockNow: day6, anchorA: a, anchorB: b)
        await MainActor.run { store2.dispatch(.trialLoadRequested) }
        let phase = await waitForPhase(store2) { $0 == .trial(daysLeft: 1) || $0 == .trialExpired }
        #expect(phase == .trial(daysLeft: 1))                          // 按 t0 起算，未重置
        #expect(await a.current()?.firstLaunchAt == t0)                // 被删的 A 已自愈补回
        #expect(await b.current()?.firstLaunchAt == t0)
    }

    @Test("expired trial locks paid capability but the store keeps running (never black-holes)")
    func expiredLocksButRuns() async {
        let a = InMemoryTrialAnchorStore(stored: TrialInfo(firstLaunchAt: t0, clockHighWater: t0))
        let b = InMemoryTrialAnchorStore(stored: TrialInfo(firstLaunchAt: t0, clockHighWater: t0))
        let past = t0.addingTimeInterval(8 * 86_400)
        let store = await makeStore(clockNow: past, anchorA: a, anchorB: b)
        await MainActor.run { store.dispatch(.trialLoadRequested) }
        let phase = await waitForPhase(store) { $0 == .trialExpired }
        #expect(phase == .trialExpired)
        #expect(!(await MainActor.run { store.state.isLicenseActive }))
        // 引擎健康度与授权解耦：试用到期不动网络接管。
        #expect(await MainActor.run { store.state.isEngineHealthy })
    }
}
