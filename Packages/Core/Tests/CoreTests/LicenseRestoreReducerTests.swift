import Foundation
import Testing
@testable import Core

@Suite("Reducer — license restore, reset & capability gating")
struct LicenseRestoreReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    let grace = AppState.licenseGracePeriod

    private func info(_ status: LicenseStatus, lastValidatedAt: Date, expiresAt: Date? = nil) -> LicenseInfo {
        LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: status, expiresAt: expiresAt,
            activations: 1, activationLimit: 3, lastValidatedAt: lastValidatedAt
        )
    }

    @Test("restore nil → unlicensed")
    func restoreNil() {
        let (next, effects) = Reducer.reduce(AppState(), .licenseRestored(nil, now: t0))
        #expect(next.licensePhase == .unlicensed)
        #expect(next.license == nil)
        #expect(effects.isEmpty)
    }

    @Test("restore a fresh active record within grace → licensed")
    func restoreLicensed() {
        let recent = t0.addingTimeInterval(-3600)
        let (next, _) = Reducer.reduce(AppState(), .licenseRestored(info(.active, lastValidatedAt: recent), now: t0))
        #expect(next.licensePhase == .licensed)
        #expect(next.isLicenseActive)
    }

    @Test("restore an active record whose grace already lapsed offline → expired (and persists status)")
    func restoreGraceLapsed() {
        let stale = t0.addingTimeInterval(-(grace + 3600))
        let (next, effects) = Reducer.reduce(AppState(), .licenseRestored(info(.active, lastValidatedAt: stale), now: t0))
        #expect(next.licensePhase == .expired)
        #expect(next.license?.status == .expired)
        #expect(effects == [.persistLicense(next.license)])
    }

    @Test("restore a revoked record stays revoked regardless of clock")
    func restoreRevoked() {
        let (next, _) = Reducer.reduce(AppState(), .licenseRestored(info(.revoked, lastValidatedAt: t0), now: t0))
        #expect(next.licensePhase == .revoked)
        #expect(!next.isLicenseActive)
    }

    @Test("restore a subscription past expiresAt → expired")
    func restoreExpiredByDate() {
        let expiresAt = t0.addingTimeInterval(-3600)
        let (next, _) = Reducer.reduce(
            AppState(), .licenseRestored(info(.active, lastValidatedAt: t0.addingTimeInterval(-60), expiresAt: expiresAt), now: t0)
        )
        #expect(next.licensePhase == .expired)
    }

    @Test("isLicenseActive gates paid capability by phase")
    func capabilityGating() {
        let active: [LicensePhase] = [.licensed, .validating, .gracePeriod, .deactivating]
        let locked: [LicensePhase] = [.unlicensed, .activating, .revoked, .expired, .recoverableError("x")]
        for phase in active {
            var state = AppState(); state.licensePhase = phase
            #expect(state.isLicenseActive, "\(phase) should be active")
        }
        for phase in locked {
            var state = AppState(); state.licensePhase = phase
            #expect(!state.isLicenseActive, "\(phase) should be locked")
        }
    }

    @Test("resetState (profile switch) preserves license phase and record")
    func resetPreservesLicense() {
        var state = AppState()
        state.license = info(.active, lastValidatedAt: t0)
        state.licensePhase = .licensed
        state.proxyServers[ProxyServerID("a")] = ProxyServer(id: ProxyServerID("a"), host: "h", port: 1)
        let (reset, _) = Reducer.reduce(state, .resetState)
        #expect(reset.licensePhase == .licensed)      // account-level, not per-profile
        #expect(reset.license == state.license)
        #expect(reset.proxyServers.isEmpty)            // profile state still cleared
    }

    @Test("licenses stays decoupled from networking: no forwarding effects from any license action")
    func noForwardingEffects() {
        // A license failure must never emit applyRuleSet / applyProxyConfig etc. (blackhole guard).
        var state = AppState()
        state.license = info(.active, lastValidatedAt: t0)
        state.licensePhase = .gracePeriod
        let (_, effects) = Reducer.reduce(state, .licenseValidateFailed(.transient, now: t0.addingTimeInterval(60)))
        for effect in effects {
            switch effect {
            case .applyRuleSet, .applyProxyConfig, .applyRoutingMode, .applyUDPPolicy,
                 .applyPacketCapture, .applyProcessOriginExclusions:
                Issue.record("license action emitted a networking effect: \(effect)")
            default:
                break
            }
        }
    }

    @Test("purchase requested opens the configured checkout link, no state change")
    func purchaseOpensCheckout() {
        let (next, effects) = Reducer.reduce(AppState(), .licensePurchaseRequested(checkoutURL: "https://checkout.example/x"))
        #expect(next == AppState())
        #expect(effects == [.openCheckout(url: "https://checkout.example/x")])
    }
}
