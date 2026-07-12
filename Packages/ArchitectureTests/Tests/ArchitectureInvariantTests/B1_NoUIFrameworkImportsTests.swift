import Testing
import Foundation

@Suite("B1 — Core / IPCContract / EngineKit never import AppKit or SwiftUI")
struct B1NoUIFrameworkImportsTests {

    @Test("no forbidden UI-framework imports in the three non-UI packages", arguments: ["Core", "IPCContract", "EngineKit"])
    func noUIFrameworkImports(package: String) throws {
        let forbidden = ["AppKit", "SwiftUI"]
        let files = try swiftFiles(in: RepoPaths.sourcesDir(of: package))
        #expect(!files.isEmpty, "\(package) has no source files to scan — check RepoPaths")

        var offenders: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for framework in forbidden where trimmed.hasPrefix("import \(framework)") {
                    offenders.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "forbidden imports found: \(offenders.joined(separator: ", "))")
    }
}
