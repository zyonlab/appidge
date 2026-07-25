import Foundation
import Core
import Security

/// 授权 JSON 编解码：日期用 ISO-8601（与 facade 契约一致）。
public enum LicenseCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 构建期公开配置。**绝不硬编码生产地址**：facade base URL / checkout 链接读自 App 主包 Info.plist，
/// 缺失时 base 回落到本地 dev（`127.0.0.1:8787`），永不误用生产。appVersion 读自包信息。
public enum LicenseBuildConfig {
    /// facade 基址（无尾斜杠）。生产由构建配置注入 `LicenseAPIBaseURL=https://api.appidge.com`。
    public static var apiBaseURL: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LicenseAPIBaseURL") as? String,
              !value.isEmpty else {
            return "http://127.0.0.1:8787"
        }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// 稳定购买入口（官网定价页或支付商托管结账页）。为空表示未配置——UI 隐藏入口。
    public static var checkoutURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "LicenseCheckoutURL") as? String) ?? ""
    }

    public static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    public static var clientConfig: LicenseClientConfig {
        LicenseClientConfig(instanceName: LicenseInstallIdentifier.current, appVersion: appVersion)
    }
}

/// 隐私友好且稳定的安装标识：一次性生成的随机不透明 id 存 UserDefaults（非机密），
/// **绝不**用邮箱/主机名/硬件序列号。用作 activate 的 `instanceName`。
public enum LicenseInstallIdentifier {
    private static let key = "com.appidge.license.installID"

    public static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let generated = "appidge-install-" + suffix
        defaults.set(generated, forKey: key)
        return generated
    }
}

/// 系统时钟（挂钟时间）。测试用 `FixedLicenseClock` 注入。
public struct SystemClock: LicenseClock {
    public init() {}
    public var now: Date { Date() }
}

/// license facade 的 URLSession 客户端。**只**打自有 facade，绝不直连带 `Bearer token` 的支付商 API。
/// HTTP 状态/错误体统一翻成 ``LicenseAPIError``：2xx 解码成功；有 facade 错误体 → `.facade`；
/// 5xx 无体 → `.server`；网络/超时 → `.transport`；解析不了 → `.decoding`。
public struct URLSessionLicenseAPIClient: LicenseAPIClient {
    let baseURL: String
    let session: URLSession

    public init(baseURL: String = LicenseBuildConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func activate(_ request: ActivateRequest) async -> Result<LicenseResponse, LicenseAPIError> {
        await post("/v1/licenses/activate", body: request)
    }

    public func validate(_ request: ValidateRequest) async -> Result<LicenseResponse, LicenseAPIError> {
        await post("/v1/licenses/validate", body: request)
    }

    public func deactivate(_ request: DeactivateRequest) async -> Result<DeactivateResponse, LicenseAPIError> {
        await post("/v1/licenses/deactivate", body: request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body
    ) async -> Result<Response, LicenseAPIError> {
        guard let url = URL(string: baseURL + path) else { return .failure(.transport) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            urlRequest.httpBody = try LicenseCoding.encoder.encode(body)
        } catch {
            return .failure(.decoding)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport) }
            return Self.decode(status: http.statusCode, data: data)
        } catch {
            return .failure(.transport)
        }
    }

    static func decode<Response: Decodable>(status: Int, data: Data) -> Result<Response, LicenseAPIError> {
        if (200..<300).contains(status) {
            guard let decoded = try? LicenseCoding.decoder.decode(Response.self, from: data) else {
                return .failure(.decoding)
            }
            return .success(decoded)
        }
        if let facade = try? LicenseCoding.decoder.decode(LicenseFacadeError.self, from: data) {
            return .failure(.facade(facade))
        }
        return (500..<600).contains(status) ? .failure(.server) : .failure(.decoding)
    }
}

/// 授权记录的真实 Keychain 出口（`kSecClassGenericPassword`，单条 JSON blob）。
/// license key / instance id / lastValidatedAt / 时钟高水位**只**存这里，绝不落明文 plist/UserDefaults。
/// 与 ``KeychainCredentialStore`` 同构：真实实现不进自动化测试（CI 无钥匙串/entitlement），
/// 由 ``InMemoryLicenseKeychainStore`` 承担状态机测试。写入优先 `SecItemUpdate` 原子覆盖，
/// 仅在 item 不存在时 `SecItemAdd`，避免“先删成功、后加失败”永久丢失旧有效记录。
public final class KeychainLicenseStore: LicenseKeychainStore, @unchecked Sendable {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
        case corrupted
    }

    private let service: String
    private let account: String

    public init(service: String = "com.appidge.license", account: String = "license-record") {
        self.service = service
        self.account = account
    }

    public func saveLicense(_ info: LicenseInfo) async throws {
        let data = try LicenseCoding.encoder.encode(info)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    public func loadLicense() async throws -> LicenseInfo? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { throw KeychainError.corrupted }
        return try LicenseCoding.decoder.decode(LicenseInfo.self, from: data)
    }

    public func clearLicense() async throws {
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

public extension LicenseEffectHandler {
    /// 生产装配：真实 URLSession facade 客户端 + Keychain + 系统时钟 + 构建期配置。
    /// `openCheckout` 由 App 层注入（打开官网购买页或 Hosted Checkout）。
    static func makeProduction(openCheckout: @escaping @Sendable (String) -> Void) -> LicenseEffectHandler {
        LicenseEffectHandler(
            apiClient: URLSessionLicenseAPIClient(),
            keychain: KeychainLicenseStore(),
            clock: SystemClock(),
            config: LicenseBuildConfig.clientConfig,
            openCheckout: openCheckout,
            // 试用双锚点：Keychain + Application Support 文件（冗余防单点删除重置）。见 TrialInfra.swift。
            trialAnchorStores: [KeychainTrialAnchorStore(), FileTrialAnchorStore()]
        )
    }
}
