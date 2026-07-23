import Foundation
import Testing
@testable import Core

@Suite("Reducer — license validation, grace & clock-rollback")
struct LicenseValidationReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    let grace = AppState.licenseGracePeriod              // 7 days

    private func licensedState(lastValidatedAt: Date, expiresAt: Date? = nil, highWater: Date? = nil) -> AppState {
        var state = AppState()
        state.license = LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: .active, expiresAt: expiresAt,
            activations: 1, activationLimit: nil, lastValidatedAt: lastValidatedAt, clockHighWater: highWater
        )
        state.licensePhase = .licensed
        return state
    }

    private func response(_ status: LicenseStatus, expiresAt: Date? = nil, validatedAt: Date) -> LicenseResponse {
        LicenseResponse(
            status: status, instanceId: "inst_1", expiresAt: expiresAt,
            activations: 1, activationLimit: nil, validatedAt: validatedAt
        )
    }

    @Test("validate requested from licensed → validating and emits validateLicense")
    func validateRequested() {
        let (next, effects) = Reducer.reduce(licensedState(lastValidatedAt: t0), .licenseValidateRequested(now: t0))
        #expect(next.licensePhase == .validating)
        #expect(effects == [.validateLicense(licenseKey: "K12345678", instanceId: "inst_1")])
    }

    @Test("validate requested is a no-op when unlicensed or revoked")
    func validateRequestedGuarded() {
        #expect(Reducer.reduce(AppState(), .licenseValidateRequested(now: t0)).0.licensePhase == .unlicensed)
        var revoked = licensedState(lastValidatedAt: t0); revoked.licensePhase = .revoked
        let (next, effects) = Reducer.reduce(revoked, .licenseValidateRequested(now: t0))
        #expect(next.licensePhase == .revoked)
        #expect(effects.isEmpty)
    }

    @Test("expired license can revalidate without temporarily reopening the paid capability")
    func expiredCanRevalidate() {
        var expired = licensedState(lastValidatedAt: t0)
        expired.licensePhase = .expired
        expired.license?.status = .expired

        let (validating, effects) = Reducer.reduce(
            expired,
            .licenseValidateRequested(now: t0.addingTimeInterval(grace + 1))
        )
        #expect(validating.licensePhase == .validating)
        #expect(!validating.isLicenseActive)
        #expect(effects == [.validateLicense(licenseKey: "K12345678", instanceId: "inst_1")])

        let refreshedAt = t0.addingTimeInterval(grace + 2)
        let (recovered, _) = Reducer.reduce(
            validating,
            .licenseValidateSucceeded(response: response(.active, validatedAt: refreshedAt), now: refreshedAt)
        )
        #expect(recovered.licensePhase == .licensed)
        #expect(recovered.isLicenseActive)
    }

    @Test("transient failure while recovering an expired license stays locked and retryable")
    func expiredTransientStaysExpired() {
        var state = licensedState(lastValidatedAt: t0)
        state.licensePhase = .validating
        state.license?.status = .expired
        let (next, _) = Reducer.reduce(
            state,
            .licenseValidateFailed(.transient, now: t0.addingTimeInterval(grace + 1))
        )
        #expect(next.licensePhase == .expired)
        #expect(!next.isLicenseActive)
    }

    @Test("validate succeeded refreshes lastValidatedAt and returns to licensed")
    func validateSucceeded() {
        var state = licensedState(lastValidatedAt: t0); state.licensePhase = .validating
        let later = t0.addingTimeInterval(grace / 2)
        let (next, effects) = Reducer.reduce(state, .licenseValidateSucceeded(response: response(.active, validatedAt: later), now: later))
        #expect(next.licensePhase == .licensed)
        #expect(next.license?.lastValidatedAt == later)
        #expect(effects == [.persistLicense(next.license)])
    }

    @Test("validate succeeded with revoked/expired lands locked")
    func validateSucceededTerminal() {
        var state = licensedState(lastValidatedAt: t0); state.licensePhase = .validating
        #expect(Reducer.reduce(state, .licenseValidateSucceeded(response: response(.revoked, validatedAt: t0), now: t0)).0.licensePhase == .revoked)
        #expect(Reducer.reduce(state, .licenseValidateSucceeded(response: response(.expired, validatedAt: t0), now: t0)).0.licensePhase == .expired)
    }

    @Test("explicit revoked/expired validate failure locks immediately")
    func validateFailedTerminal() {
        let state = licensedState(lastValidatedAt: t0)
        let (rev, _) = Reducer.reduce(state, .licenseValidateFailed(.revoked, now: t0))
        #expect(rev.licensePhase == .revoked)
        #expect(rev.license?.status == .revoked)
        let (exp, _) = Reducer.reduce(state, .licenseValidateFailed(.expired, now: t0))
        #expect(exp.licensePhase == .expired)
    }

    @Test("transient validate failure does NOT revoke: enters grace and stays functional")
    func transientEntersGrace() {
        let state = licensedState(lastValidatedAt: t0)
        let (next, _) = Reducer.reduce(state, .licenseValidateFailed(.transient, now: t0.addingTimeInterval(3600)))
        #expect(next.licensePhase == .gracePeriod)
        #expect(next.isLicenseActive) // paid capability preserved during outage
    }

    @Test("grace boundary: exactly at 7 days still functional; one second past expires")
    func graceBoundary() {
        let state = licensedState(lastValidatedAt: t0)
        let atBoundary = t0.addingTimeInterval(grace)
        #expect(Reducer.reduce(state, .licenseValidateFailed(.transient, now: atBoundary)).0.licensePhase == .gracePeriod)
        let pastBoundary = t0.addingTimeInterval(grace + 1)
        #expect(Reducer.reduce(state, .licenseValidateFailed(.transient, now: pastBoundary)).0.licensePhase == .expired)
    }

    @Test("clock rollback cannot extend grace: high-water pins elapsed forward")
    func clockRollbackDefeatsGraceExtension() {
        // High-water already advanced to t0 + 10 days (seen earlier this session / persisted).
        let state = licensedState(lastValidatedAt: t0, highWater: t0.addingTimeInterval(10 * 24 * 3600))
        // Attacker rolls the wall clock back to t0 + 1 day to look "within grace".
        let rolledBack = t0.addingTimeInterval(24 * 3600)
        let (next, _) = Reducer.reduce(state, .licenseValidateFailed(.transient, now: rolledBack))
        // referenceNow = max(now, highWater, lastValidated) = t0+10d → elapsed 10d > 7d → expired.
        #expect(next.licensePhase == .expired)
    }

    @Test("clock tick in grace expires once the window is exhausted; no network effect")
    func clockTickExhaustsGrace() {
        var state = licensedState(lastValidatedAt: t0)
        state.licensePhase = .gracePeriod
        let (still, e1) = Reducer.reduce(state, .licenseClockTick(now: t0.addingTimeInterval(grace - 10)))
        #expect(still.licensePhase == .gracePeriod)
        #expect(e1.isEmpty)
        let (expired, e2) = Reducer.reduce(state, .licenseClockTick(now: t0.addingTimeInterval(grace + 10)))
        #expect(expired.licensePhase == .expired)
        #expect(e2 == [.persistLicense(expired.license)])
    }

    @Test("clock tick expires a licensed subscription once past expiresAt")
    func clockTickSubscriptionExpiry() {
        let expiresAt = t0.addingTimeInterval(30 * 24 * 3600)
        let state = licensedState(lastValidatedAt: t0, expiresAt: expiresAt)
        let (before, _) = Reducer.reduce(state, .licenseClockTick(now: expiresAt.addingTimeInterval(-10)))
        #expect(before.licensePhase == .licensed)
        let (after, _) = Reducer.reduce(state, .licenseClockTick(now: expiresAt.addingTimeInterval(10)))
        #expect(after.licensePhase == .expired)
    }
}
