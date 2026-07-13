import Foundation
import Core

/// Produces the app catalog for the directory panel. Whoever wires this in dispatches
/// the result as `Core.Action.directoryScanned(entries)` — not this file's job.
public protocol DirectoryScanning: Sendable {
    func scan() async -> [Core.DirectoryEntry]
}

/// Enumerates `*.app` bundles directly inside `applicationsDirectory` (non-recursive) and
/// tags each by industry via `industryIndex`. Never crashes on a missing/unreadable
/// `Info.plist` — falls back to the bundle's filename so one malformed app can't blank out
/// the whole catalog.
public struct FileSystemDirectoryScanner: DirectoryScanning {
    private let applicationsDirectory: URL
    private let industryIndex: Core.IndustrySeedIndex

    public init(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
        industryIndex: Core.IndustrySeedIndex = .placeholder
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.industryIndex = industryIndex
    }

    public func scan() async -> [Core.DirectoryEntry] {
        enumerateAppBundleURLs().map(makeEntry(for:))
    }

    private func enumerateAppBundleURLs() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: applicationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeEntry(for bundleURL: URL) -> Core.DirectoryEntry {
        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let info = readInfoPlist(at: bundleURL)
        let bundleID = info?["CFBundleIdentifier"] as? String
        let displayName = (info?["CFBundleName"] as? String) ?? fallbackName

        return Core.DirectoryEntry(
            id: Core.ProcessID(bundleID ?? fallbackName),
            displayName: displayName,
            executablePath: bundleURL.path,
            industryTag: industryIndex.tag(bundleID: bundleID ?? "")
        )
    }

    private func readInfoPlist(at bundleURL: URL) -> [String: Any]? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return plist as? [String: Any]
    }
}

/// Test double: returns whatever it was constructed with, never touches the filesystem.
public struct MockDirectoryScanner: DirectoryScanning {
    private let entries: [Core.DirectoryEntry]

    public init(entries: [Core.DirectoryEntry]) {
        self.entries = entries
    }

    public func scan() async -> [Core.DirectoryEntry] {
        entries
    }
}
