import Testing
@testable import AppFeature

@Suite("ProfileCollection.updateConfiguration — replace a profile's config in place")
struct ProfileUpdateConfigTests {

    @Test("updates the named profile's configuration, keeping position/name/active unchanged")
    func updatesInPlace() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: PersistedConfiguration(activeProxyServerID: "old-a"))
        collection.add(name: "B", configuration: PersistedConfiguration(activeProxyServerID: "old-b"))
        // active 是首个加入的 A。
        collection.updateConfiguration(named: "A", to: PersistedConfiguration(activeProxyServerID: "new-a"))

        #expect(collection.profiles.map(\.name) == ["A", "B"])          // 顺序不变
        #expect(collection.activeName == "A")                            // active 不变
        #expect(collection.profiles[0].configuration.activeProxyServerID == "new-a")
        #expect(collection.profiles[1].configuration.activeProxyServerID == "old-b") // 别的不动
    }

    @Test("an unknown name is a no-op")
    func unknownNameNoOp() {
        var collection = ProfileCollection()
        collection.add(name: "A", configuration: PersistedConfiguration(activeProxyServerID: "a"))
        let before = collection
        collection.updateConfiguration(named: "ghost", to: PersistedConfiguration(activeProxyServerID: "z"))
        #expect(collection == before)
    }
}
