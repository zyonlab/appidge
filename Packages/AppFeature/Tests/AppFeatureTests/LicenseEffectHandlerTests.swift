import Foundation
import Testing
import Core
@testable import AppFeature

/// 测试用：线程安全记录 openCheckout 被打开的 URL。
final class OpenedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func append(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}

@Suite("LicenseEffectHandler — effect → action via injected protocols")
struct LicenseEffectHandlerTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600)

    private func response(_ status: LicenseStatus) -> LicenseResponse {
        LicenseResponse(status: status, instanceId: "inst_1", expiresAt: nil, activations: 1, activationLimit: 3, validatedAt: t0)
    }

    private func makeHandler(
        api: MockLicenseAPIClient, keychain: InMemoryLicenseKeychainStore, opened: OpenedURLs = OpenedURLs()
    ) -> LicenseEffectHandler {
        LicenseEffectHandler(
            apiClient: api, keychain: keychain, clock: FixedLicenseClock(now: t0),
            config: LicenseClientConfig(instanceName: "appidge-install-test", appVersion: "9.9.9"),
            openCheckout: { opened.append($0) }
        )
    }

    @Test("activate success builds request from config and returns succeeded with the echoed key")
    func activateSuccess() async {
        let api = MockLicenseAPIClient(activateResult: .success(response(.active)))
        let handler = makeHandler(api: api, keychain: InMemoryLicenseKeychainStore())
        let action = await handler.handle(.activateLicense(licenseKey: "KEY-1234-5678"))
        #expect(action == .licenseActivateSucceeded(licenseKey: "KEY-1234-5678", response: response(.active), now: t0))
        let requests = await api.recordedActivateRequests()
        #expect(requests.first?.instanceName == "appidge-install-test")
        #expect(requests.first?.appVersion == "9.9.9")
    }

    @Test("activate facade activation_limit maps to activationLimit failure")
    func activateActivationLimit() async {
        let api = MockLicenseAPIClient(activateResult: .failure(.facade(LicenseFacadeError(error: .activationLimit))))
        let handler = makeHandler(api: api, keychain: InMemoryLicenseKeychainStore())
        #expect(await handler.handle(.activateLicense(licenseKey: "K12345678")) == .licenseActivateFailed(.activationLimit))
    }

    @Test("activate transport error maps to transient (retryable), never a hard lock")
    func activateTransport() async {
        let api = MockLicenseAPIClient(activateResult: .failure(.transport))
        let handler = makeHandler(api: api, keychain: InMemoryLicenseKeychainStore())
        #expect(await handler.handle(.activateLicense(licenseKey: "K12345678")) == .licenseActivateFailed(.transient))
    }

    @Test("validate success returns succeeded")
    func validateSuccess() async {
        let api = MockLicenseAPIClient(validateResult: .success(response(.active)))
        let handler = makeHandler(api: api, keychain: InMemoryLicenseKeychainStore())
        #expect(await handler.handle(.validateLicense(licenseKey: "K12345678", instanceId: "inst_1"))
            == .licenseValidateSucceeded(response: response(.active), now: t0))
    }

    @Test("validate facade revoked locks; upstream_unavailable/transport go to grace-eligible transient")
    func validateFailureMapping() async {
        let revoked = makeHandler(
            api: MockLicenseAPIClient(validateResult: .failure(.facade(LicenseFacadeError(error: .revoked)))),
            keychain: InMemoryLicenseKeychainStore()
        )
        #expect(await revoked.handle(.validateLicense(licenseKey: "K12345678", instanceId: "i"))
            == .licenseValidateFailed(.revoked, now: t0))
        let upstream = makeHandler(
            api: MockLicenseAPIClient(validateResult: .failure(.facade(LicenseFacadeError(error: .upstreamUnavailable)))),
            keychain: InMemoryLicenseKeychainStore()
        )
        #expect(await upstream.handle(.validateLicense(licenseKey: "K12345678", instanceId: "i"))
            == .licenseValidateFailed(.transient, now: t0))
    }

    @Test("deactivate success returns succeeded; facade error returns deactivateFailed")
    func deactivate() async {
        let ok = makeHandler(
            api: MockLicenseAPIClient(deactivateResult: .success(DeactivateResponse())),
            keychain: InMemoryLicenseKeychainStore()
        )
        #expect(await ok.handle(.deactivateLicense(licenseKey: "K12345678", instanceId: "i")) == .licenseDeactivateSucceeded)
        let fail = makeHandler(
            api: MockLicenseAPIClient(deactivateResult: .failure(.facade(LicenseFacadeError(error: .rateLimited)))),
            keychain: InMemoryLicenseKeychainStore()
        )
        #expect(await fail.handle(.deactivateLicense(licenseKey: "K12345678", instanceId: "i")) == .licenseDeactivateFailed(transient: true))
    }

    @Test("persist writes to keychain and returns no follow-up; nil clears")
    func persist() async {
        let keychain = InMemoryLicenseKeychainStore()
        let handler = makeHandler(api: MockLicenseAPIClient(), keychain: keychain)
        let info = LicenseInfo(licenseKey: "K12345678", instanceId: "i", status: .active, activations: 1, activationLimit: 3, lastValidatedAt: t0)
        #expect(await handler.handle(.persistLicense(info)) == nil)
        #expect(await keychain.current() == info)
        #expect(await handler.handle(.persistLicense(nil)) == nil)
        #expect(await keychain.current() == nil)
    }

    @Test("keychain save failure surfaces licensePersistenceFailed (non-fatal, does not lock)")
    func persistFailure() async {
        let keychain = InMemoryLicenseKeychainStore(failSave: true)
        let handler = makeHandler(api: MockLicenseAPIClient(), keychain: keychain)
        let info = LicenseInfo(licenseKey: "K12345678", instanceId: "i", status: .active, activations: 1, activationLimit: 3, lastValidatedAt: t0)
        #expect(await handler.handle(.persistLicense(info)) == .licensePersistenceFailed(.save))
    }

    @Test("safe deactivate clear leaves a revoked tombstone when physical Keychain delete fails")
    func safeDeactivateClearFailure() async {
        let active = LicenseInfo(
            licenseKey: "K12345678", instanceId: "i", status: .active,
            activations: 1, activationLimit: 3, lastValidatedAt: t0
        )
        var tombstone = active
        tombstone.status = .revoked
        let keychain = InMemoryLicenseKeychainStore(stored: active, failClear: true)
        let handler = makeHandler(api: MockLicenseAPIClient(), keychain: keychain)

        #expect(await handler.handle(.clearPersistedLicense(fallback: tombstone))
            == .licensePersistenceFailed(.clear))
        #expect(await keychain.current()?.status == .revoked)
    }

    @Test("load returns the stored record; a keychain read failure degrades safely to nil (unlicensed)")
    func load() async {
        let stored = LicenseInfo(licenseKey: "K12345678", instanceId: "i", status: .active, activations: 1, activationLimit: 3, lastValidatedAt: t0)
        let ok = makeHandler(api: MockLicenseAPIClient(), keychain: InMemoryLicenseKeychainStore(stored: stored))
        #expect(await ok.handle(.loadPersistedLicense) == .licenseRestored(stored, now: t0))
        let failing = makeHandler(api: MockLicenseAPIClient(), keychain: InMemoryLicenseKeychainStore(stored: stored, failLoad: true))
        #expect(await failing.handle(.loadPersistedLicense) == .licenseRestored(nil, now: t0))
    }

    @Test("openCheckout invokes the injected opener with the URL")
    func openCheckout() async {
        let opened = OpenedURLs()
        let handler = makeHandler(api: MockLicenseAPIClient(), keychain: InMemoryLicenseKeychainStore(), opened: opened)
        #expect(await handler.handle(.openCheckout(url: "https://checkout.example/x")) == nil)
        #expect(opened.all == ["https://checkout.example/x"])
    }

    @Test("non-license effects are ignored (returns nil)")
    func ignoresOtherEffects() async {
        let handler = makeHandler(api: MockLicenseAPIClient(), keychain: InMemoryLicenseKeychainStore())
        #expect(await handler.handle(.scanDirectory) == nil)
        #expect(await handler.handle(.log("x")) == nil)
    }

    @Test("error → failure-kind mapping tables")
    func errorMappingTables() {
        #expect(LicenseEffectHandler.activationFailure(from: .facade(LicenseFacadeError(error: .invalidLicense))) == .invalidLicense)
        #expect(LicenseEffectHandler.activationFailure(from: .facade(LicenseFacadeError(error: .revoked))) == .revoked)
        #expect(LicenseEffectHandler.activationFailure(from: .server) == .transient)
        #expect(LicenseEffectHandler.validationFailure(from: .facade(LicenseFacadeError(error: .invalidLicense))) == .revoked)
        #expect(LicenseEffectHandler.validationFailure(from: .facade(LicenseFacadeError(error: .internalError))) == .transient)
        #expect(LicenseEffectHandler.validationFailure(from: .decoding) == .transient)
        #expect(LicenseEffectHandler.isTransient(.facade(LicenseFacadeError(error: .upstreamUnavailable))))
        #expect(!LicenseEffectHandler.isTransient(.facade(LicenseFacadeError(error: .invalidLicense))))
        #expect(LicenseEffectHandler.isTransient(.transport))
    }
}
