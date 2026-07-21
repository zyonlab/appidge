import Foundation
import Testing
@testable import Core

@Suite("Reducer — license activation & deactivation")
struct LicenseActivationReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    private func response(_ status: LicenseStatus, expiresAt: Date? = nil, validatedAt: Date) -> LicenseResponse {
        LicenseResponse(
            status: status, instanceId: "inst_MOCK_0000000000", expiresAt: expiresAt,
            activations: 1, activationLimit: 3, validatedAt: validatedAt
        )
    }

    @Test("activate requested: unlicensed → activating and emits activateLicense effect")
    func activateRequested() {
        let (next, effects) = Reducer.reduce(AppState(), .licenseActivateRequested(licenseKey: "KEY-1234-5678"))
        #expect(next.licensePhase == .activating)
        #expect(effects == [.activateLicense(licenseKey: "KEY-1234-5678")])
        #expect(next.license == nil) // key not stored until success
    }

    @Test("activate succeeded (active): stores record, becomes licensed, persists to Keychain")
    func activateSucceededActive() {
        var state = AppState(); state.licensePhase = .activating
        let (next, effects) = Reducer.reduce(
            state, .licenseActivateSucceeded(licenseKey: "KEY-1234-5678", response: response(.active, validatedAt: t0), now: t0)
        )
        #expect(next.licensePhase == .licensed)
        #expect(next.isLicenseActive)
        let info = try? #require(next.license)
        #expect(info?.licenseKey == "KEY-1234-5678")
        #expect(info?.instanceId == "inst_MOCK_0000000000")
        #expect(info?.activationLimit == 3)
        #expect(info?.lastValidatedAt == t0)
        #expect(effects == [.persistLicense(next.license)])
    }

    @Test("activate succeeded with revoked/expired status lands in the matching locked phase")
    func activateSucceededTerminal() {
        var state = AppState(); state.licensePhase = .activating
        let (rev, _) = Reducer.reduce(
            state, .licenseActivateSucceeded(licenseKey: "K12345678", response: response(.revoked, validatedAt: t0), now: t0)
        )
        #expect(rev.licensePhase == .revoked)
        #expect(!rev.isLicenseActive)
        let (exp, _) = Reducer.reduce(
            state, .licenseActivateSucceeded(licenseKey: "K12345678", response: response(.expired, validatedAt: t0), now: t0)
        )
        #expect(exp.licensePhase == .expired)
    }

    @Test("activate failed maps to the right phase; limit/invalid/transient are recoverable, not locked-forever")
    func activateFailed() {
        var state = AppState(); state.licensePhase = .activating
        #expect(Reducer.reduce(state, .licenseActivateFailed(.activationLimit)).0.licensePhase
            == .recoverableError("activationLimit"))
        #expect(Reducer.reduce(state, .licenseActivateFailed(.invalidLicense)).0.licensePhase
            == .recoverableError("invalidLicense"))
        #expect(Reducer.reduce(state, .licenseActivateFailed(.transient)).0.licensePhase
            == .recoverableError("transient"))
        #expect(Reducer.reduce(state, .licenseActivateFailed(.revoked)).0.licensePhase == .revoked)
        #expect(Reducer.reduce(state, .licenseActivateFailed(.expired)).0.licensePhase == .expired)
    }

    @Test("deactivate requested → deactivating and emits deactivateLicense; keeps access until confirmed")
    func deactivateRequested() {
        var state = AppState()
        state.license = LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: .active,
            activations: 1, activationLimit: 3, lastValidatedAt: t0
        )
        state.licensePhase = .licensed
        let (next, effects) = Reducer.reduce(state, .licenseDeactivateRequested)
        #expect(next.licensePhase == .deactivating)
        #expect(next.isLicenseActive) // still functional until server confirms
        #expect(effects == [.deactivateLicense(licenseKey: "K12345678", instanceId: "inst_1")])
    }

    @Test("deactivate succeeded clears the record and Keychain, back to unlicensed")
    func deactivateSucceeded() {
        var state = AppState()
        state.license = LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: .active,
            activations: 1, activationLimit: 3, lastValidatedAt: t0
        )
        state.licensePhase = .deactivating
        let (next, effects) = Reducer.reduce(state, .licenseDeactivateSucceeded)
        #expect(next.licensePhase == .unlicensed)
        #expect(next.license == nil)
        #expect(effects == [.persistLicense(nil)])
    }

    @Test("deactivate failed does NOT lock: falls back to licensed while a record remains")
    func deactivateFailed() {
        var state = AppState()
        state.license = LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: .active,
            activations: 1, activationLimit: 3, lastValidatedAt: t0
        )
        state.licensePhase = .deactivating
        let (next, _) = Reducer.reduce(state, .licenseDeactivateFailed(transient: true))
        #expect(next.licensePhase == .licensed)
        #expect(next.isLicenseActive)
    }
}
