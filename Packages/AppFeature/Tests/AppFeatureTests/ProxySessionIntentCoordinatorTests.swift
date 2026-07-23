import Testing
@testable import AppFeature

@Suite("ProxySessionIntentCoordinator — newer capability intent invalidates in-flight work")
struct ProxySessionIntentCoordinatorTests {
    @Test("stop invalidates an older in-flight start ticket")
    func stopSupersedesStart() {
        var coordinator = ProxySessionIntentCoordinator()
        let start = coordinator.request(.running)
        let stop = coordinator.request(.stopped)

        #expect(!coordinator.isCurrent(start))
        #expect(coordinator.isCurrent(stop))
        #expect(coordinator.intent == .stopped)
    }

    @Test("a stale restart completion cannot overwrite a later stop")
    func staleRestartCompletionCannotResume() {
        var coordinator = ProxySessionIntentCoordinator()
        let restart = coordinator.request(.restarting)
        _ = coordinator.request(.stopped)

        coordinator.complete(restart)

        #expect(coordinator.intent == .stopped)
    }

    @Test("current restart and reset completions normalize to stable intents")
    func completionNormalizesTransientIntents() {
        var coordinator = ProxySessionIntentCoordinator()
        let restart = coordinator.request(.restarting)
        coordinator.complete(restart)
        #expect(coordinator.intent == .running)

        let reset = coordinator.request(.resetting)
        coordinator.complete(reset)
        #expect(coordinator.intent == .stopped)
    }
}
