import Testing
@testable import Core

@Suite("Reducer — directory catalog, diagnostics, onboarding")
struct DirectoryAndDiagnosticsReducerTests {

    @Test("directoryScanned inserts new catalog entries and updates existing ones by id")
    func directoryScannedUpsertsCatalog() {
        let a = ProcessID("a")
        let state = AppState()
        let (next, effects) = Reducer.reduce(
            state,
            .directoryScanned([
                DirectoryEntry(id: a, displayName: "A", executablePath: "/a", industryTag: .technology)
            ])
        )
        #expect(next.catalog[a]?.displayName == "A")
        #expect(next.catalog[a]?.industryTag == .technology)
        #expect(effects.isEmpty)

        let (rescanned, _) = Reducer.reduce(
            next,
            .directoryScanned([
                DirectoryEntry(id: a, displayName: "A renamed", executablePath: "/a", industryTag: .finance)
            ])
        )
        #expect(rescanned.catalog[a]?.displayName == "A renamed")
        #expect(rescanned.catalog[a]?.industryTag == .finance)
        #expect(rescanned.catalog.count == 1)
    }

    @Test("directoryScanned also seeds a MonitoredProcess entry so scanned apps are immediately rule-assignable")
    func directoryScannedSeedsProcessesForRuleAssignment() {
        let a = ProcessID("a")
        let (next, _) = Reducer.reduce(
            AppState(),
            .directoryScanned([DirectoryEntry(id: a, displayName: "A", executablePath: "/a")])
        )
        #expect(next.processes[a]?.displayName == "A")
        #expect(next.processes[a]?.rule == .direct)
    }

    @Test("directoryScanned re-scanning an already-known app does not clobber its assigned rule")
    func directoryScannedRescanPreservesAssignedRule() {
        let a = ProcessID("a")
        let (afterFirstScan, _) = Reducer.reduce(
            AppState(),
            .directoryScanned([DirectoryEntry(id: a, displayName: "A", executablePath: "/a")])
        )
        let (afterAssign, _) = Reducer.reduce(afterFirstScan, .assignRule(processID: a, rule: .proxied))
        let (afterRescan, _) = Reducer.reduce(
            afterAssign,
            .directoryScanned([DirectoryEntry(id: a, displayName: "A renamed", executablePath: "/a")])
        )
        #expect(afterRescan.processes[a]?.rule == .proxied)
        #expect(afterRescan.catalog[a]?.displayName == "A renamed")
    }

    @Test("directoryScanned leaves untouched catalog entries value-equal (incremental, no full recompute)")
    func directoryScannedIsIncremental() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        var state = AppState()
        state.catalog[a] = DirectoryEntry(id: a, displayName: "A", executablePath: "/a")
        state.catalog[b] = DirectoryEntry(id: b, displayName: "B", executablePath: "/b")
        let bBefore = state.catalog[b]!

        let (next, _) = Reducer.reduce(
            state,
            .directoryScanned([DirectoryEntry(id: a, displayName: "A updated", executablePath: "/a")])
        )
        #expect(next.catalog[b] == bBefore)
    }

    @Test("requestDiagnostic does not mutate state and emits a runDiagnostic effect")
    func requestDiagnosticEmitsEffect() {
        let a = ProcessID("a")
        let state = AppState()
        let (next, effects) = Reducer.reduce(
            state,
            .requestDiagnostic(processID: a, kinds: [.ruleHit, .dnsResolution])
        )
        #expect(next == state)
        #expect(effects == [.runDiagnostic(processID: a, kinds: [.ruleHit, .dnsResolution])])
    }

    @Test("diagnosticResultReceived records the outcome for that process+kind only")
    func diagnosticResultReceivedRecordsOutcome() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        var state = AppState()
        state.diagnostics[b] = [.ruleHit: DiagnosticOutcome(passed: true, detail: "b baseline")]
        let bBefore = state.diagnostics[b]!

        let (next, effects) = Reducer.reduce(
            state,
            .diagnosticResultReceived(processID: a, kind: .dnsResolution, passed: false, detail: "timed out")
        )
        #expect(next.diagnostics[a]?[.dnsResolution] == DiagnosticOutcome(passed: false, detail: "timed out"))
        #expect(next.diagnostics[b] == bBefore)
        #expect(effects.isEmpty)
    }

    @Test("onboardingCompleted flips the flag and nothing else")
    func onboardingCompletedFlipsFlag() {
        var state = AppState()
        state.isPacketCaptureEnabled = true
        let (next, effects) = Reducer.reduce(state, .onboardingCompleted)
        #expect(next.hasCompletedOnboarding == true)
        #expect(next.isPacketCaptureEnabled == true)
        #expect(effects.isEmpty)
    }

    @Test("appLaunched does not mutate state and emits a scanDirectory effect")
    func appLaunchedEmitsScanDirectoryEffect() {
        let state = AppState()
        let (next, effects) = Reducer.reduce(state, .appLaunched)
        #expect(next == state)
        #expect(effects == [.scanDirectory])
    }
}
