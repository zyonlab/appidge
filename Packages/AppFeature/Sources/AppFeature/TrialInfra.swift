import Core
import Foundation
import Security

/// 试用锚点的真实持久化实现（两份冗余锚点）。纯本地防篡改：Keychain 一份 + Application Support
/// 文件一份，读取时 reducer 取两者中较早的 firstLaunchAt + 最高水位（见 Core `reduceTrial`），
/// 删一份下次启动自愈补写。这两个实现不进自动化测试（CI 无钥匙串/沙盒容器），状态机由
/// `InMemoryTrialAnchorStore` 覆盖。编解码复用 ``LicenseCoding``（ISO-8601 日期，与 TrialInfo 一致）。

/// 锚点一：Keychain（`kSecClassGenericPassword` 单条 JSON blob）。与 ``KeychainLicenseStore`` 同构，
/// 写入优先 `SecItemUpdate` 原子覆盖，仅 item 不存在时 `SecItemAdd`，避免“先删后加失败”丢锚点。
public final class KeychainTrialAnchorStore: TrialAnchorStore, @unchecked Sendable {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
        case corrupted
    }

    private let service: String
    private let account: String

    public init(service: String = "com.appidge.trial", account: String = "trial-anchor") {
        self.service = service
        self.account = account
    }

    public func readAnchor() async throws -> TrialInfo? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { throw KeychainError.corrupted }
        return try LicenseCoding.decoder.decode(TrialInfo.self, from: data)
    }

    public func writeAnchor(_ info: TrialInfo) async throws {
        let data = try LicenseCoding.encoder.encode(info)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    public func clearAnchor() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// 锚点二：Application Support 下的 JSON 文件。与 Keychain 冗余——删掉钥匙串条目但文件仍在
/// （或反之）即可判定“已开始试用”。actor 串行化文件 IO。
public actor FileTrialAnchorStore: TrialAnchorStore {
    private let fileURL: URL

    /// 默认落 `~/Library/Application Support/Appidge/trial-anchor.json`（沙盒下为 App 容器内同路径）。
    public init(fileName: String = "trial-anchor.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Appidge", isDirectory: true)
        self.fileURL = dir.appendingPathComponent(fileName, isDirectory: false)
    }

    public func readAnchor() async throws -> TrialInfo? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try LicenseCoding.decoder.decode(TrialInfo.self, from: data)
    }

    public func writeAnchor(_ info: TrialInfo) async throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try LicenseCoding.encoder.encode(info)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clearAnchor() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
