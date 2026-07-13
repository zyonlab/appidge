import Testing
import Core
@testable import AppFeature

/// `PersistedConfiguration.restorationActions()` is the testable core of onboarding
/// restore: turning a loaded configuration into the exact ordered `Core.Action`s the
/// app dispatches at launch. It only reuses existing `Core.Action` cases
/// (`directoryScanned`, `processDiscovered`, `assignRule`, `onboardingCompleted`) —
/// no new case was needed. Kept in AppFeature (not App/AppidgeApp.swift) specifically
/// so this decision logic gets real TDD coverage; App/OnboardingView.swift and
/// AppidgeApp.swift stay thin SwiftUI glue, same as the existing untested
/// App/ContentView.swift.
@Suite("PersistedConfiguration.restorationActions — ordered Action sequence for launch restore")
struct PersistenceRestorationTests {

    @Test("empty configuration produces no actions")
    func emptyConfigurationProducesNoActions() {
        let actions = PersistedConfiguration().restorationActions()
        #expect(actions.isEmpty)
    }

    @Test("catalog entries become a single batched directoryScanned action, sorted by id")
    func catalogBecomesSingleDirectoryScannedAction() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(catalog: [
            b: DirectoryEntry(id: b, displayName: "B", executablePath: "/b"),
            a: DirectoryEntry(id: a, displayName: "A", executablePath: "/a")
        ])
        let actions = config.restorationActions()
        #expect(actions == [.directoryScanned([
            DirectoryEntry(id: a, displayName: "A", executablePath: "/a"),
            DirectoryEntry(id: b, displayName: "B", executablePath: "/b")
        ])])
    }

    @Test("a process with the default .direct rule only emits processDiscovered")
    func processWithDefaultRuleOnlyEmitsDiscovery() {
        let id = ProcessID("x")
        let config = PersistedConfiguration(processes: [
            id: MonitoredProcess(id: id, displayName: "X", executablePath: "/x", rule: .direct)
        ])
        let actions = config.restorationActions()
        #expect(actions == [.processDiscovered(id: id, displayName: "X", executablePath: "/x")])
    }

    @Test("a process with a non-default rule emits processDiscovered then assignRule")
    func processWithNonDefaultRuleEmitsDiscoveryThenAssignRule() {
        let id = ProcessID("x")
        let config = PersistedConfiguration(processes: [
            id: MonitoredProcess(id: id, displayName: "X", executablePath: "/x", rule: .proxied)
        ])
        let actions = config.restorationActions()
        #expect(actions == [
            .processDiscovered(id: id, displayName: "X", executablePath: "/x"),
            .assignRule(processID: id, rule: .proxied)
        ])
    }

    @Test("multiple processes are emitted in deterministic id-sorted order")
    func multipleProcessesAreSortedById() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(processes: [
            b: MonitoredProcess(id: b, displayName: "B", executablePath: "/b", rule: .proxied),
            a: MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .direct)
        ])
        let actions = config.restorationActions()
        #expect(actions == [
            .processDiscovered(id: a, displayName: "A", executablePath: "/a"),
            .processDiscovered(id: b, displayName: "B", executablePath: "/b"),
            .assignRule(processID: b, rule: .proxied)
        ])
    }

    @Test("hasCompletedOnboarding true appends a trailing onboardingCompleted action")
    func onboardingCompletedIsAppendedLast() {
        let config = PersistedConfiguration(hasCompletedOnboarding: true)
        #expect(config.restorationActions() == [.onboardingCompleted])
    }

    @Test("hasCompletedOnboarding false emits no onboarding action")
    func onboardingNotCompletedEmitsNoAction() {
        let config = PersistedConfiguration(hasCompletedOnboarding: false)
        #expect(config.restorationActions().isEmpty)
    }

    @Test("replaying restorationActions through the real reducer reconstructs an equivalent AppState")
    func replayingActionsThroughReducerReconstructsState() {
        let a = ProcessID("a")
        let b = ProcessID("b")
        let config = PersistedConfiguration(
            processes: [
                a: MonitoredProcess(id: a, displayName: "A", executablePath: "/a", rule: .proxied),
                b: MonitoredProcess(id: b, displayName: "B", executablePath: "/b", rule: .direct)
            ],
            catalog: [
                a: DirectoryEntry(id: a, displayName: "A", executablePath: "/a", industryTag: .technology)
            ],
            hasCompletedOnboarding: true
        )

        var state = AppState()
        for action in config.restorationActions() {
            let (next, _) = Reducer.reduce(state, action)
            state = next
        }

        #expect(state.catalog == config.catalog)
        #expect(state.processes[a]?.displayName == "A")
        #expect(state.processes[a]?.rule == .proxied)
        #expect(state.processes[b]?.displayName == "B")
        #expect(state.processes[b]?.rule == .direct)
        #expect(state.hasCompletedOnboarding == true)
        // Runtime/ephemeral fields untouched by restore, still at their fresh-launch defaults.
        #expect(state.isGlobalProxyEnabled == false)
        #expect(state.isEngineHealthy == true)
    }
}
