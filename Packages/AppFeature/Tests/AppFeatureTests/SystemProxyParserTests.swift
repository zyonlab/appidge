import Foundation
import Testing
import Core
@testable import AppFeature

@Suite("SystemProxyParser — 系统代理设置字典 → ProxyEnvironment.SystemProxy")
struct SystemProxyParserTests {

    @Test("空字典 = 无系统代理")
    func emptyIsNone() {
        #expect(SystemProxyParser.parse([:]) == .none)
    }

    @Test("PAC 启用且有 URL → .pac,优先于手动代理")
    func pacWins() {
        let settings: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://wpad/proxy.pac",
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890
        ]
        #expect(SystemProxyParser.parse(settings) == .pac(url: "http://wpad/proxy.pac"))
    }

    @Test("PAC 启用但 URL 空 → 不算 PAC,回落手动/无")
    func pacWithoutURLIgnored() {
        let settings: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": ""]
        #expect(SystemProxyParser.parse(settings) == .none)
    }

    @Test("手动 HTTPS 代理 → .manual,摘要含协议+主机+端口")
    func manualHTTPS() {
        let settings: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]
        #expect(SystemProxyParser.parse(settings) == .manual(summary: "HTTPS 127.0.0.1:7890"))
    }

    @Test("多协议同时启用 → 摘要按 HTTPS·HTTP·SOCKS 顺序全列")
    func multipleProtocols() {
        let settings: [String: Any] = [
            "HTTPSEnable": 1, "HTTPSProxy": "10.0.0.1", "HTTPSPort": 443,
            "HTTPEnable": 1, "HTTPProxy": "10.0.0.1", "HTTPPort": 80,
            "SOCKSEnable": 1, "SOCKSProxy": "10.0.0.2", "SOCKSPort": 1080
        ]
        #expect(SystemProxyParser.parse(settings)
            == .manual(summary: "HTTPS 10.0.0.1:443 · HTTP 10.0.0.1:80 · SOCKS 10.0.0.2:1080"))
    }

    @Test("enable=0 的协议不计入")
    func disabledProtocolIgnored() {
        let settings: [String: Any] = [
            "HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080
        ]
        #expect(SystemProxyParser.parse(settings) == .manual(summary: "SOCKS 127.0.0.1:1080"))
    }

    @Test("布尔标志兼容 NSNumber / Bool")
    func flagTypesTolerated() {
        let asBool: [String: Any] = ["SOCKSEnable": true, "SOCKSProxy": "h", "SOCKSPort": 1]
        #expect(SystemProxyParser.parse(asBool) == .manual(summary: "SOCKS h:1"))
        let asNumber: [String: Any] = ["SOCKSEnable": NSNumber(value: 1), "SOCKSProxy": "h", "SOCKSPort": 1]
        #expect(SystemProxyParser.parse(asNumber) == .manual(summary: "SOCKS h:1"))
    }

    @Test("hasBypassLayer:任一层存在即为真")
    func bypassLayerFlag() {
        #expect(!Core.ProxyEnvironment().hasBypassLayer)
        #expect(Core.ProxyEnvironment(systemProxy: .manual(summary: "x")).hasBypassLayer)
        #expect(Core.ProxyEnvironment(environmentVariables: ["HTTP_PROXY"]).hasBypassLayer)
        #expect(Core.ProxyEnvironment(extraTunnelInterfaces: ["utun4"]).hasBypassLayer)
    }
}
