import Testing
import Foundation

@Suite("B4 — EngineKit routing is an actor, Transport is protocol-injected, tests use MockTransport only")
struct B4EngineKitActorAndMockOnlyTests {

    @Test("FlowRouter is declared as an actor")
    func flowRouterIsAnActor() throws {
        let file = RepoPaths.sourcesDir(of: "EngineKit").appendingPathComponent("FlowRouter.swift")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("public actor FlowRouter"))
    }

    @Test("Transport is a protocol, and both a real and a mock implementation exist")
    func transportIsAProtocolWithRealAndMockImpls() throws {
        let engineSources = RepoPaths.sourcesDir(of: "EngineKit")
        let transport = try String(contentsOf: engineSources.appendingPathComponent("Transport.swift"), encoding: .utf8)
        #expect(transport.contains("public protocol Transport"))

        let mock = try String(contentsOf: engineSources.appendingPathComponent("MockTransport.swift"), encoding: .utf8)
        #expect(mock.contains("actor MockTransport: Transport"))

        let real = try String(contentsOf: engineSources.appendingPathComponent("NEFlowTransport.swift"), encoding: .utf8)
        #expect(real.contains("NEFlowTransport: Transport"))
    }

    @Test("EngineKitTests never imports Network/NetworkExtension and never references the real transport")
    func testsUseMockTransportOnly() throws {
        let testFiles = try swiftFiles(in: RepoPaths.testsDir(of: "EngineKit"))
        #expect(!testFiles.isEmpty)

        var offenders: [String] = []
        for file in testFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["import Network", "import NetworkExtension", "NEFlowTransport"] {
                if contents.contains(forbidden) {
                    offenders.append("\(file.lastPathComponent) references \(forbidden)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: ", "))")
    }
}
