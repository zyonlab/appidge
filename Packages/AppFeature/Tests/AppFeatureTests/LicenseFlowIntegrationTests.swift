import Foundation
import Testing
import Core
@testable import AppFeature

/// 端到端：Store（@MainActor 单向数据流）+ 纯 reducer + 注入 mock 的 LicenseEffectHandler，
/// 驱动一次完整激活/停用，验证相位落地、Keychain 写入、离线宽限不锁死。
@Suite("License flow — Store + reducer + handler end to end")
struct LicenseFlowIntegrationTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600)

    private func response(_ status: LicenseStatus) -> LicenseResponse {
        LicenseResponse(status: status, instanceId: "inst_1", expiresAt: nil, activations: 1, activationLimit: 3, validatedAt: t0)
    }

    private func makeStore(api: MockLicenseAPIClient, keychain: InMemoryLicenseKeychainStore) async -> Store {
        let handler = LicenseEffectHandler(
            apiClient: api, keychain: keychain, clock: FixedLicenseClock(now: t0),
            config: LicenseClientConfig(instanceName: "appidge-install-test", appVersion: "9.9.9"),
            openCheckout: { _ in }
        )
        return await MainActor.run { Store(effectHandler: { await handler.handle($0) }) }
    }

    private func waitForPhase(_ store: Store, _ predicate: @escaping @Sendable (LicensePhase) -> Bool) async -> LicensePhase {
        for _ in 0..<200 {
            let phase = await MainActor.run { store.state.licensePhase }
            if predicate(phase) { return phase }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await MainActor.run { store.state.licensePhase }
    }

    @Test("paste key → activate → licensed, and the record lands in the (mock) Keychain")
    func fullActivation() async {
        let api = MockLicenseAPIClient(activateResult: .success(response(.active)))
        let keychain = InMemoryLicenseKeychainStore()
        let store = await makeStore(api: api, keychain: keychain)

        await MainActor.run { store.dispatch(.licenseActivateRequested(licenseKey: "KEY-1234-5678")) }
        let phase = await waitForPhase(store) { $0 == .licensed }
        #expect(phase == .licensed)
        #expect(await keychain.current()?.licenseKey == "KEY-1234-5678")
        #expect(await MainActor.run { store.state.isLicenseActive })
    }

    @Test("transient validate failure keeps the user functional (grace), never black-holes capability")
    func transientKeepsGrace() async {
        let api = MockLicenseAPIClient(
            activateResult: .success(response(.active)),
            validateResult: .failure(.facade(LicenseFacadeError(error: .upstreamUnavailable)))
        )
        let store = await makeStore(api: api, keychain: InMemoryLicenseKeychainStore())
        await MainActor.run { store.dispatch(.licenseActivateRequested(licenseKey: "KEY-1234-5678")) }
        _ = await waitForPhase(store) { $0 == .licensed }

        await MainActor.run { store.dispatch(.licenseValidateRequested(now: t0)) }
        let phase = await waitForPhase(store) { $0 == .gracePeriod }
        #expect(phase == .gracePeriod)
        #expect(await MainActor.run { store.state.isLicenseActive }) // still paid-capable during outage
    }

    @Test("deactivate clears the Keychain and returns to unlicensed")
    func fullDeactivation() async {
        let api = MockLicenseAPIClient(
            activateResult: .success(response(.active)),
            deactivateResult: .success(DeactivateResponse())
        )
        let keychain = InMemoryLicenseKeychainStore()
        let store = await makeStore(api: api, keychain: keychain)
        await MainActor.run { store.dispatch(.licenseActivateRequested(licenseKey: "KEY-1234-5678")) }
        _ = await waitForPhase(store) { $0 == .licensed }

        await MainActor.run { store.dispatch(.licenseDeactivateRequested) }
        let phase = await waitForPhase(store) { $0 == .unlicensed }
        #expect(phase == .unlicensed)
        #expect(await keychain.current() == nil)
    }
}
