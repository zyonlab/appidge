import Foundation
import Core
import Security

/// 代理凭据（密码）的存取出口协议。跟持久化其余部分同一套设计：一个协议、一个测试用
/// mock（``InMemoryCredentialStore``）、一个真实实现（``KeychainCredentialStore``）。
/// 密码**只**经这里进出，永不进磁盘上的 JSON（见 ``PersistedProxyServer`` 刻意没有 password 字段）。
public protocol CredentialStore: Sendable {
    func savePassword(_ password: String?, for id: Core.ProxyServerID) async
    func password(for id: Core.ProxyServerID) async -> String?
    func deletePassword(for id: Core.ProxyServerID) async
}

/// 测试专用：内存字典。`savePassword(nil,...)` 等同删除。
public actor InMemoryCredentialStore: CredentialStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func savePassword(_ password: String?, for id: Core.ProxyServerID) async {
        if let password {
            storage[id.value] = password
        } else {
            storage[id.value] = nil
        }
    }

    public func password(for id: Core.ProxyServerID) async -> String? {
        storage[id.value]
    }

    public func deletePassword(for id: Core.ProxyServerID) async {
        storage[id.value] = nil
    }
}

/// 生产路径：macOS Keychain（`kSecClassGenericPassword`，account = 代理 id，service 常量）。
/// 跟 ``NEFlowTransport`` 一样，这个真实实现**不进自动化测试**——Keychain 需要真实钥匙串/
/// entitlement，CI 环境没有。`savePassword(nil,...)` 删除条目；写入用「先删后加」保证覆盖。
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.appidge.proxy-credentials") {
        self.service = service
    }

    public func savePassword(_ password: String?, for id: Core.ProxyServerID) async {
        guard let password, let data = password.data(using: .utf8) else {
            await deletePassword(for: id)
            return
        }
        var attributes = baseQuery(for: id)
        SecItemDelete(attributes as CFDictionary) // 先删旧的，避免 duplicate
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func password(for id: Core.ProxyServerID) async -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    public func deletePassword(for id: Core.ProxyServerID) async {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    private func baseQuery(for id: Core.ProxyServerID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.value
        ]
    }
}

public extension PersistedConfiguration {
    /// 把每台代理的密码存进凭据库（不是 JSON），按 id 归档。nil 密码 → 删除任何旧条目。
    /// 集成方在调用 `FilePersistenceStore.save` 落盘（无密码）的同时调这个存密码。
    static func saveCredentials(from servers: [Core.ProxyServer], to store: any CredentialStore) async {
        for server in servers {
            await store.savePassword(server.password, for: server.id)
        }
    }

    /// 跟 ``restorationActions()`` 完全同序，唯一差别：每台代理的 `.addProxyServer` 里把密码
    /// 从凭据库回填，这样重启后恢复的代理不用重新输密码。同步版保持不变（其测试不受影响）。
    func restorationActions(rehydratingCredentialsFrom store: any CredentialStore) async -> [Core.Action] {
        var actions: [Core.Action] = []
        for action in restorationActions() {
            if case .addProxyServer(let server) = action {
                let password = await store.password(for: server.id)
                actions.append(.addProxyServer(rehydrate(server, password: password)))
            } else {
                actions.append(action)
            }
        }
        return actions
    }

    private func rehydrate(_ server: Core.ProxyServer, password: String?) -> Core.ProxyServer {
        Core.ProxyServer(
            id: server.id, host: server.host, port: server.port,
            kind: server.kind, username: server.username, password: password
        )
    }
}
