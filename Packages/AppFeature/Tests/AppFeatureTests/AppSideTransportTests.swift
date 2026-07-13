import Testing
import IPCContract
@testable import AppFeature

@Suite("MockAppSideTransport — records sends, dispatches simulated incoming messages")
struct AppSideTransportTests {

    @Test("send records the message, doesn't call the listener")
    func sendRecordsMessage() async {
        let transport = MockAppSideTransport()
        let request = AppToExtensionMessage.requestDiagnostic(
            DiagnosticRequestDTO(processID: ProcessIdentifierDTO("x"), kinds: [.ruleHit])
        )
        await transport.send(request)
        let sent = await transport.sentMessages
        #expect(sent == [request])
    }

    @Test("startListening registers a handler that fires on simulated incoming messages")
    func startListeningFiresOnIncoming() async {
        let transport = MockAppSideTransport()
        let received = Box<[ExtensionToAppMessage]>([])

        await transport.startListening { message in
            received.value.append(message)
        }

        let batch = ExtensionToAppMessage.flowStatsBatch(
            FlowStatsBatchMessage(entries: [], windowStart: .init(timeIntervalSince1970: 0), windowEnd: .init(timeIntervalSince1970: 1))
        )
        await transport.simulateIncoming(batch)

        #expect(received.value == [batch])
    }

    @Test("stopListening prevents further dispatch")
    func stopListeningStopsDispatch() async {
        let transport = MockAppSideTransport()
        let received = Box<[ExtensionToAppMessage]>([])

        await transport.startListening { message in received.value.append(message) }
        await transport.stopListening()
        await transport.simulateIncoming(.engineFailure(reason: "boom"))

        #expect(received.value.isEmpty)
    }
}

/// 简单的引用盒子，让测试闭包能在 async 上下文里累积观测结果，不用额外拉 actor。
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
