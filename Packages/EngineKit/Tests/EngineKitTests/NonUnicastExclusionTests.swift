import Testing
@testable import EngineKit

@Suite("NonUnicastExclusion — 组播/广播目的地识别(UDP 硬闸用)")
struct NonUnicastExclusionTests {

    @Test("IPv4 组播 224.0.0.0/4 命中(mDNS/SSDP 都在此)")
    func ipv4Multicast() {
        #expect(NonUnicastExclusion.isNonUnicast(host: "224.0.0.251"))   // mDNS
        #expect(NonUnicastExclusion.isNonUnicast(host: "239.255.255.250")) // SSDP
        #expect(NonUnicastExclusion.isNonUnicast(host: "224.0.0.0"))
        #expect(NonUnicastExclusion.isNonUnicast(host: "239.255.255.255"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "223.255.255.255"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "240.0.0.1"))
    }

    @Test("IPv4 受限广播 255.255.255.255 命中(DHCP)")
    func ipv4Broadcast() {
        #expect(NonUnicastExclusion.isNonUnicast(host: "255.255.255.255"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "255.255.255.254"))
    }

    @Test("IPv6 组播 ff00::/8 命中(含带方括号形式)")
    func ipv6Multicast() {
        #expect(NonUnicastExclusion.isNonUnicast(host: "ff02::fb"))  // mDNS
        #expect(NonUnicastExclusion.isNonUnicast(host: "[ff02::1]"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "fe80::1"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "2001:db8::1"))
    }

    @Test("普通单播与主机名不命中")
    func unicastAndNamesPass() {
        #expect(!NonUnicastExclusion.isNonUnicast(host: "8.8.8.8"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: "example.com"))
        #expect(!NonUnicastExclusion.isNonUnicast(host: ""))
    }
}
