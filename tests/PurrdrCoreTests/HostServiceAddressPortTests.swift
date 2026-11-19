import Foundation
import PurrdrCore
import Testing

/// 主機服務位址的「位址＋Port」組合與拆解(#250):編輯器、同步 wire 共用同一處規則。
@Suite("主機服務位址：位址與 Port")
struct HostServiceAddressPortTests {
    @Test(
        "主機名稱與 Port 組成位址：預設 443 不帶埠，其他埠帶上;loopback 是本機測試，用 http",
        arguments: [
            ("studio.tail1234.ts.net", 443, "https://studio.tail1234.ts.net"),
            ("studio.tail1234.ts.net", 8443, "https://studio.tail1234.ts.net:8443"),
            ("Studio.Tail1234.ts.net", 8443, "https://studio.tail1234.ts.net:8443"),
            ("127.0.0.1", 47820, "http://127.0.0.1:47820"),
        ])
    func composesFromHostAndPort(host: String, port: Int, expected: String) throws {
        let address = try #require(HostServiceAddress(host: host, port: port))
        #expect(address.description == expected)
        #expect(address.port == port)
    }

    @Test("組不出合法位址時是 nil", arguments: [("", 443), ("studio.ts.net", 0), ("studio.ts.net", 70_000), ("a b", 443), ("x/y", 443)])
    func rejectsInvalidHostOrPort(host: String, port: Int) {
        #expect(HostServiceAddress(host: host, port: port) == nil)
    }

    @Test(
        "舊資料(位址含埠或不含埠)拆成位址欄位與 Port 欄位，組回去是同一個位址",
        arguments: [
            ("https://studio.tail1234.ts.net:8443", "studio.tail1234.ts.net", 8443),
            ("https://studio.tail1234.ts.net", "studio.tail1234.ts.net", 443),
            ("http://127.0.0.1:47820", "127.0.0.1", 47820),
        ])
    func splitsLegacyAddress(stored: String, host: String, port: Int) throws {
        let address = try #require(HostServiceAddress(stored))
        #expect(address.hostName == host)
        #expect(address.port == port)
        #expect(HostServiceAddress(host: address.hostName, port: address.port) == address)
    }

    @Test(
        "編輯器欄位：位址欄位沒寫埠時用 Port 欄位;位址欄位自己寫了埠(舊習慣、貼上完整網址)以它為準",
        arguments: [
            ("studio.tail1234.ts.net", "8443", "https://studio.tail1234.ts.net:8443"),
            ("  studio.tail1234.ts.net ", " 443 ", "https://studio.tail1234.ts.net"),
            ("studio.tail1234.ts.net:8443", "443", "https://studio.tail1234.ts.net:8443"),
            ("https://studio.tail1234.ts.net:9443/", "443", "https://studio.tail1234.ts.net:9443"),
            ("127.0.0.1", "47820", "http://127.0.0.1:47820"),
        ])
    func composesFromEditorFields(addressField: String, portField: String, expected: String) throws {
        let address = try #require(HostServiceAddress(addressField: addressField, portField: portField))
        #expect(address.description == expected)
    }

    @Test("編輯器欄位不合法時是 nil", arguments: [("", "443"), ("studio.ts.net", ""), ("studio.ts.net", "abc"), ("studio.ts.net", "0")])
    func rejectsInvalidEditorFields(addressField: String, portField: String) {
        #expect(HostServiceAddress(addressField: addressField, portField: portField) == nil)
    }
}
