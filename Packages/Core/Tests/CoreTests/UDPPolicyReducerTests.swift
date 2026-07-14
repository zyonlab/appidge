import Testing
@testable import Core

@Suite("Reducer — UDP policy toggle sets state and pushes the effect")
struct UDPPolicyReducerTests {

    @Test("default state UDP policy is block (stop the leak)")
    func defaultBlock() {
        #expect(AppState().udpPolicy == .block)
    }

    @Test(
        "setUDPPolicy sets the policy and emits applyUDPPolicy",
        arguments: [UDPPolicy.block, .direct, .proxySOCKS5]
    )
    func setPolicy(policy: UDPPolicy) {
        let (state, effects) = Reducer.reduce(AppState(), .setUDPPolicy(policy))
        #expect(state.udpPolicy == policy)
        #expect(effects == [.applyUDPPolicy(policy)])
    }
}
