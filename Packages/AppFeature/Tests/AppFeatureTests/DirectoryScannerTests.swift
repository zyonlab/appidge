import Testing
import Foundation
import Darwin
import Core
@testable import AppFeature

/// FileSystemDirectoryScanner is exercised against a real, disposable temp directory with
/// hand-written fake `.app` bundles — never the real `/Applications` (slow, non-deterministic,
/// environment-dependent). Each test that touches the filesystem cleans up its temp dir via
/// `defer`, even on failure.
@Suite("DirectoryScanner — enumerates *.app bundles, tags by industry")
struct DirectoryScannerTests {

    @Test("MockDirectoryScanner returns exactly what it was constructed with")
    func mockScannerReturnsConstructedEntries() async {
        let entries = [
            DirectoryEntry(id: ProcessID("com.example.one"), displayName: "One", executablePath: "/tmp/One.app"),
            DirectoryEntry(
                id: ProcessID("com.example.two"),
                displayName: "Two",
                executablePath: "/tmp/Two.app",
                industryTag: .finance
            )
        ]
        let scanner = MockDirectoryScanner(entries: entries)
        let result = await scanner.scan()
        #expect(result == entries)
    }

    @Test("""
    scans a real temp directory: reads Info.plist for CFBundleIdentifier/CFBundleName, \
    falls back to the filename when the plist is missing or unreadable, tags by industry, \
    ignores non-.app entries, and does not recurse into subdirectories
    """)
    func scansTempDirectoryForAppBundles() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeAppBundle(
            in: root,
            name: "GoodApp",
            infoPlist: ["CFBundleIdentifier": "com.example.gooddapp", "CFBundleName": "Good App Display Name"]
        )
        try makeAppBundle(in: root, name: "NoPlist", infoPlist: nil)
        try makeAppBundleWithMalformedPlist(in: root, name: "BadPlist")

        // non-.app entries at the top level must be ignored, not crash the scan
        try Data("hello".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("NotAnApp"), withIntermediateDirectories: true
        )

        // nested one level down — must NOT be picked up, scan is non-recursive
        let subdir = root.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try makeAppBundle(
            in: subdir,
            name: "Nested",
            infoPlist: ["CFBundleIdentifier": "com.example.nested", "CFBundleName": "Nested"]
        )

        let industryIndex = IndustrySeedIndex(seeds: [(prefix: "com.example.", industry: .productivity)])
        let scanner = FileSystemDirectoryScanner(applicationsDirectory: root, industryIndex: industryIndex)
        let entries = await scanner.scan()

        #expect(entries.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.value, $0) })

        let good = try #require(byID["com.example.gooddapp"])
        #expect(good.displayName == "Good App Display Name")
        #expect(good.executablePath == root.appendingPathComponent("GoodApp.app").path)
        #expect(good.industryTag == .productivity)

        let noPlist = try #require(byID["NoPlist"])
        #expect(noPlist.displayName == "NoPlist")
        #expect(noPlist.industryTag == .unknown)

        let badPlist = try #require(byID["BadPlist"])
        #expect(badPlist.displayName == "BadPlist")
        #expect(badPlist.industryTag == .unknown)

        #expect(byID["com.example.nested"] == nil, "nested bundle one level down must not be picked up")
        #expect(!entries.contains { $0.displayName == "Nested" })
    }

    @Test("an applications directory that doesn't exist yields an empty scan, not a crash")
    func missingDirectoryYieldsEmptyResult() async {
        let missing = makeTempDirectory(create: false)
        let scanner = FileSystemDirectoryScanner(applicationsDirectory: missing)
        let entries = await scanner.scan()
        #expect(entries.isEmpty)
    }

    @Test("the default industryIndex is IndustrySeedIndex.placeholder")
    func defaultsToPlaceholderIndex() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // matches a placeholder seed prefix verbatim (see Core/IndustryTag.swift)
        try makeAppBundle(
            in: root,
            name: "Xcode",
            infoPlist: ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleName": "Xcode"]
        )

        let scanner = FileSystemDirectoryScanner(applicationsDirectory: root)
        let entries = await scanner.scan()
        let xcode = try #require(entries.first)
        #expect(xcode.industryTag == .technology)
    }

    // MARK: - fixtures

    /// Resolved via the POSIX `realpath()` because `/var` is a symlink to `/private/var` on
    /// macOS and `FileManager.contentsOfDirectory` returns the resolved form — Foundation's
    /// own `URL.resolvingSymlinksInPath()` deliberately leaves `/tmp`/`/var`/`/etc` alone for
    /// historical compatibility, so it would NOT fix the mismatch here. Without this,
    /// comparing raw executablePath strings against an unresolved `root` spuriously fails
    /// even though the scanner behaved correctly.
    private func makeTempDirectory(create: Bool = true) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryScannerTests-\(UUID().uuidString)")
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard create, let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func makeAppBundle(in directory: URL, name: String, infoPlist: [String: Any]?) throws {
        let contentsURL = directory.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        guard let infoPlist else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    private func makeAppBundleWithMalformedPlist(in directory: URL, name: String) throws {
        let contentsURL = directory.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try Data("this is not a valid property list".utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
