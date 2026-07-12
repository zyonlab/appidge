import Foundation

/// 纯文件系统/文本扫描，不 import 任何被测包 —— 这样才能证明「无反向依赖」，
/// 而不是靠被测包自己声称。
enum RepoPaths {
    /// .../Packages/ArchitectureTests/Tests/ArchitectureInvariantTests/RepoPaths.swift
    static let thisFile = URL(fileURLWithPath: #filePath)

    static let packagesRoot: URL = thisFile
        .deletingLastPathComponent() // ArchitectureInvariantTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // ArchitectureTests/
        .deletingLastPathComponent() // Packages/

    /// e.g. Packages/EngineKit/Sources/EngineKit — the module directory, not just "Sources".
    static func sourcesDir(of package: String) -> URL {
        packagesRoot.appendingPathComponent(package).appendingPathComponent("Sources").appendingPathComponent(package)
    }

    static func testsDir(of package: String) -> URL {
        packagesRoot.appendingPathComponent(package).appendingPathComponent("Tests")
    }

    static func packageManifest(of package: String) -> URL {
        packagesRoot.appendingPathComponent(package).appendingPathComponent("Package.swift")
    }
}

func swiftFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return []
    }
    var results: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        results.append(url)
    }
    return results
}
