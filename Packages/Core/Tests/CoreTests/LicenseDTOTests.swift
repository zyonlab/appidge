import Foundation
import Testing
@testable import Core

/// 契约 DTO 对 `contracts/fixtures/facade/*.json` 的 Codable 往返 —— 语言边界真相是 OpenAPI 契约，
/// 这里用**真实 fixture 文件**验证 Swift DTO 与之对齐（经 `#filePath` 定位仓库根，不复制 JSON）。
@Suite("License DTO — Codable round-trips against contract fixtures")
struct LicenseDTOTests {

    /// 仓库根：本测试文件在 Packages/Core/Tests/CoreTests/ 下，上溯 5 级到根。
    private func fixtureData(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("contracts/fixtures/facade/\(name)")
        return try Data(contentsOf: url)
    }

    /// 取 fixture 顶层的 `request` / `response` 子对象，重新序列化成独立 Data 供类型化解码。
    private func subObject(_ key: String, from data: Data) throws -> Data {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sub = try #require(root[key])
        return try JSONSerialization.data(withJSONObject: sub)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @Test("activate.success: request + response decode to the right values and round-trip")
    func activateSuccess() throws {
        let file = try fixtureData("activate.success.json")

        let request = try decoder.decode(ActivateRequest.self, from: try subObject("request", from: file))
        #expect(request.licenseKey == "MOCK-LICENSE-0000-0000-0000")
        #expect(request.instanceName == "appidge-install-mock01")
        #expect(request.appVersion == "1.0.0")

        let response = try decoder.decode(LicenseResponse.self, from: try subObject("response", from: file))
        #expect(response.status == .active)
        #expect(response.instanceId == "inst_MOCK_0000000000")
        #expect(response.expiresAt == nil) // 买断
        #expect(response.activations == 1)
        #expect(response.activationLimit == 3)

        // round-trip: 编码再解码应等值
        let reRequest = try decoder.decode(ActivateRequest.self, from: try encoder.encode(request))
        let reResponse = try decoder.decode(LicenseResponse.self, from: try encoder.encode(response))
        #expect(reRequest == request)
        #expect(reResponse == response)
    }

    @Test("validate.revoked: response decodes to revoked status and round-trips")
    func validateRevoked() throws {
        let file = try fixtureData("validate.revoked.json")

        let request = try decoder.decode(ValidateRequest.self, from: try subObject("request", from: file))
        #expect(request.instanceId == "inst_MOCK_0000000000")

        let response = try decoder.decode(LicenseResponse.self, from: try subObject("response", from: file))
        #expect(response.status == .revoked)
        #expect(response.instanceId == "inst_MOCK_0000000000")

        let reResponse = try decoder.decode(LicenseResponse.self, from: try encoder.encode(response))
        #expect(reResponse == response)
    }

    @Test("error.activation_limit: decodes to the stable facade error code")
    func errorActivationLimit() throws {
        let file = try fixtureData("error.activation_limit.json")
        let error = try decoder.decode(LicenseFacadeError.self, from: try subObject("response", from: file))
        #expect(error.error == .activationLimit)
        #expect(error.message?.isEmpty == false)

        let reError = try decoder.decode(LicenseFacadeError.self, from: try encoder.encode(error))
        #expect(reError == error)
    }

    @Test("all 8 stable facade error codes round-trip by their wire strings")
    func facadeErrorCodeStrings() throws {
        let mapping: [(LicenseFacadeErrorCode, String)] = [
            (.invalidRequest, "invalid_request"), (.invalidLicense, "invalid_license"),
            (.activationLimit, "activation_limit"), (.expired, "expired"), (.revoked, "revoked"),
            (.rateLimited, "rate_limited"), (.upstreamUnavailable, "upstream_unavailable"),
            (.internalError, "internal_error")
        ]
        for (code, wire) in mapping {
            #expect(code.rawValue == wire)
            let json = Data("{\"error\":\"\(wire)\"}".utf8)
            #expect(try decoder.decode(LicenseFacadeError.self, from: json).error == code)
        }
    }

    @Test("LicenseInfo (client Keychain record) round-trips, preserving clock high-water")
    func licenseInfoRoundTrip() throws {
        let info = LicenseInfo(
            licenseKey: "K12345678", instanceId: "inst_1", status: .active, expiresAt: nil,
            activations: 1, activationLimit: 3,
            lastValidatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            clockHighWater: Date(timeIntervalSince1970: 1_767_312_000)
        )
        let decoded = try decoder.decode(LicenseInfo.self, from: try encoder.encode(info))
        #expect(decoded == info)
    }
}
