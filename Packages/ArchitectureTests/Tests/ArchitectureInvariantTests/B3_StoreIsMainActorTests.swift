import Testing
import Foundation

@Suite("B3 — AppFeature.Store is @MainActor")
struct B3StoreIsMainActorTests {

    @Test("Store class declaration is preceded by @MainActor")
    func storeIsAnnotatedMainActor() throws {
        let file = RepoPaths.sourcesDir(of: "AppFeature").appendingPathComponent("Store.swift")
        let contents = try String(contentsOf: file, encoding: .utf8)

        guard let classRange = contents.range(of: "class Store") else {
            Issue.record("could not find 'class Store' declaration in \(file.path)")
            return
        }
        let prefix = contents[contents.startIndex..<classRange.lowerBound]
        #expect(prefix.contains("@MainActor"), "Store must be annotated @MainActor")
    }

    @Test("a real negative-example compiler error is on record proving isolation is enforced")
    func negativeExampleIsRecorded() throws {
        let evidence = RepoPaths.packagesRoot
            .appendingPathComponent("AppFeature")
            .appendingPathComponent("NegativeExamples")
            .appendingPathComponent("NonMainActorStoreAccess.md")
        let contents = try String(contentsOf: evidence, encoding: .utf8)
        #expect(contents.contains("error: main actor-isolated property 'state' can not be referenced"))
    }
}
