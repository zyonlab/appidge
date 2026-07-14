import Testing
@testable import Core

@Suite("Reducer — packet-capture toggle sets state and pushes the effect")
struct PacketCaptureReducerTests {

    @Test("enabling sets the flag and emits applyPacketCapture(true)")
    func enable() {
        let (state, effects) = Reducer.reduce(AppState(), .setPacketCaptureEnabled(true))
        #expect(state.isPacketCaptureEnabled == true)
        #expect(effects == [.applyPacketCapture(true)])
    }

    @Test("disabling clears the flag and emits applyPacketCapture(false)")
    func disable() {
        let (state, effects) = Reducer.reduce(AppState(isPacketCaptureEnabled: true), .setPacketCaptureEnabled(false))
        #expect(state.isPacketCaptureEnabled == false)
        #expect(effects == [.applyPacketCapture(false)])
    }

    @Test("default state has capture off")
    func defaultOff() {
        #expect(AppState().isPacketCaptureEnabled == false)
    }
}
