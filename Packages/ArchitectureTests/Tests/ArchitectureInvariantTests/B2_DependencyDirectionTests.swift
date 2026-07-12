import Testing
import Foundation

@Suite("B2 — dependency direction is one-way, no reverse dependencies")
struct B2DependencyDirectionTests {

    private func manifest(_ package: String) throws -> String {
        try String(contentsOf: RepoPaths.packageManifest(of: package), encoding: .utf8)
    }

    @Test("Core has zero local package dependencies — it is the foundation")
    func coreHasNoDependencies() throws {
        #expect(!(try manifest("Core")).contains(".package(path:"))
    }

    @Test("IPCContract has zero local package dependencies — pure wire contract")
    func ipcContractHasNoDependencies() throws {
        #expect(!(try manifest("IPCContract")).contains(".package(path:"))
    }

    @Test("EngineKit depends only on IPCContract, never on AppFeature or reaches back into Core")
    func engineKitDependsOnlyOnIPCContract() throws {
        let m = try manifest("EngineKit")
        #expect(m.contains("../IPCContract"))
        #expect(!m.contains("../AppFeature"))
        #expect(!m.contains("../Core\""))
    }

    @Test("AppFeature depends only on Core and IPCContract, never on EngineKit")
    func appFeatureDependsOnCoreAndIPCContractOnly() throws {
        let m = try manifest("AppFeature")
        #expect(m.contains("../Core"))
        #expect(m.contains("../IPCContract"))
        #expect(!m.contains("../EngineKit"))
    }

    @Test("nothing below AppFeature references it — no upward/reverse dependency", arguments: ["Core", "IPCContract", "EngineKit"])
    func noPackageDependsOnAppFeature(package: String) throws {
        #expect(!(try manifest(package)).contains("AppFeature"))
    }
}
