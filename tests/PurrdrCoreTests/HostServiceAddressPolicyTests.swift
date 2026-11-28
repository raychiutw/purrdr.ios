import Foundation
import PurrdrCore
import Testing

/// 主機服務位址的規則(#696):Release 只收 https,不收 http 與 loopback;Debug 與 UI 測試照舊收本機測試位址。
/// 全部用明確的規則參數,不改全域預設,所以和 `FakeHostService` 的 http 測試可以平行跑。
@Suite("主機服務位址：Release 規則")
struct HostServiceAddressPolicyTests {
    @Test(
        "httpsOnly 拒絕 http 與 loopback(含只寫主機名稱的 loopback)",
        arguments: ["http://127.0.0.1:47820", "https://127.0.0.1", "127.0.0.1", "localhost", "https://localhost:8443", "http://localhost", "https://[::1]:8443"])
    func httpsOnlyRejectsLocal(text: String) {
        #expect(HostServiceAddress(text, policy: .httpsOnly) == nil)
    }

    @Test("httpsOnly 照常接受 https 位址", arguments: ["studio.tail1234.ts.net", "https://studio.tail1234.ts.net:8443/"])
    func httpsOnlyAcceptsHTTPS(text: String) {
        #expect(HostServiceAddress(text, policy: .httpsOnly) != nil)
    }

    @Test("allowsLocalTesting 照舊收 loopback 的 http")
    func debugKeepsLocalHTTP() {
        #expect(HostServiceAddress("http://127.0.0.1:47820", policy: .allowsLocalTesting)?.description == "http://127.0.0.1:47820")
        #expect(HostServiceAddress(host: "127.0.0.1", port: 47820, policy: .allowsLocalTesting) != nil)
    }

    @Test("以主機名稱與 Port 組位址、編輯器欄位:httpsOnly 擋 loopback")
    func hostAndPortAndFields() {
        #expect(HostServiceAddress(host: "127.0.0.1", port: 47820, policy: .httpsOnly) == nil)
        #expect(HostServiceAddress(addressField: "localhost", portField: "47820", policy: .httpsOnly) == nil)
        #expect(HostServiceAddress(addressField: "studio.ts.net", portField: "8443", policy: .httpsOnly)?.description == "https://studio.ts.net:8443")
    }

    @Test("isRejected:合法但被擋下才算;本來就不合法的不算")
    func isRejected() {
        #expect(HostServiceAddress.isRejected("http://127.0.0.1:1", by: .httpsOnly))
        #expect(!HostServiceAddress.isRejected("http://127.0.0.1:1", by: .allowsLocalTesting))
        #expect(!HostServiceAddress.isRejected("studio.ts.net", by: .httpsOnly))
        #expect(!HostServiceAddress.isRejected("ftp://x", by: .httpsOnly))
    }

    @Test("Info.plist 值:只有明確的 YES 才允許本機測試位址,其餘一律 httpsOnly")
    func infoValue() {
        #expect(HostServiceAddress.Policy(infoValue: "YES") == .allowsLocalTesting)
        #expect(HostServiceAddress.Policy(infoValue: true) == .allowsLocalTesting)
        for value: Any? in ["NO", "$(PURRDR_ALLOW_LOCAL_HOST_SERVICE)", nil, 0, ""] {
            #expect(HostServiceAddress.Policy(infoValue: value) == .httpsOnly)
        }
    }

    @Test("配對連結:httpsOnly 擋 http 與 loopback 位址")
    func pairingLink() throws {
        let local = URL(string: "purrdr://pair?address=http%3A%2F%2F127.0.0.1%3A47820&code=K7QM-2XPA")!
        #expect(throws: HostServicePairingLinkError.malformed) { try HostServicePairingLink(url: local, policy: .httpsOnly) }
        #expect(try HostServicePairingLink(url: local, policy: .allowsLocalTesting).address.port == 47820)
    }

    @Test("分享連結:httpsOnly 擋 http 與 loopback 位址")
    func shareLink() throws {
        var components = URLComponents(string: "purrdr://host")!
        let wire: [String: Any] = ["v": 1, "name": "x", "host": "h", "port": 443, "user": "", "method": "https", "url": "http://127.0.0.1:47820"]
        let data = try JSONSerialization.data(withJSONObject: wire)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.queryItems = [URLQueryItem(name: "d", value: encoded)]
        let url = components.url!
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(url, policy: .httpsOnly) }
        #expect(try HostShareLink.decode(url, policy: .allowsLocalTesting).hostService != nil)
    }
}
