import Testing
@testable import IPCContract

@Suite("XPCTransportConfig — 版本化 mach service 连接候选（升级黑洞名字占用的根治）")
struct XPCServiceNameTests {
    let legacy = "group.com.appidge.xpc"

    @Test("首选名(内嵌扩展 plist 读出的版本化名)在前,legacy 兜底在后")
    func preferredFirstLegacyFallback() {
        let candidates = XPCTransportConfig.connectionCandidates(preferred: "group.com.appidge.xpc.83")
        #expect(candidates == ["group.com.appidge.xpc.83", legacy])
    }

    @Test("读不到首选名(nil/空白)→ 只剩 legacy,行为与旧版完全一致")
    func nilOrBlankFallsBackToLegacyOnly() {
        #expect(XPCTransportConfig.connectionCandidates(preferred: nil) == [legacy])
        #expect(XPCTransportConfig.connectionCandidates(preferred: "") == [legacy])
        #expect(XPCTransportConfig.connectionCandidates(preferred: "  ") == [legacy])
    }

    @Test("首选名 == legacy(旧扩展的 plist)→ 去重,只出现一次")
    func dedupWhenPreferredEqualsLegacy() {
        #expect(XPCTransportConfig.connectionCandidates(preferred: "group.com.appidge.xpc") == [legacy])
    }

    @Test("首选名不以 App Group 为前缀(读坏/被改)→ 丢弃,fail safe 回 legacy")
    func rejectsNamesOutsideAppGroupPrefix() {
        // NEMachServiceName 必须以扩展的 App Group 为前缀(git log b92b35b 踩坑硬规则)——
        // 无效值宁可丢掉也不能拿去连,防止连到任意 mach service。
        #expect(XPCTransportConfig.connectionCandidates(preferred: "com.evil.other") == [legacy])
        #expect(XPCTransportConfig.connectionCandidates(preferred: "group.com.other.xpc") == [legacy])
    }

    @Test("候选表永不为空,legacy 恒在最后一位")
    func alwaysNonEmptyWithLegacyLast() {
        for preferred in [nil, "", "group.com.appidge.xpc.999", "junk"] as [String?] {
            let candidates = XPCTransportConfig.connectionCandidates(preferred: preferred)
            #expect(!candidates.isEmpty)
            #expect(candidates.last == legacy)
        }
    }
}
