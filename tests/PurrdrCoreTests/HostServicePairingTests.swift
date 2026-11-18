import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 連線配對(ADR-0010):QR code 的連結、主機服務位址，以及以配對碼換裝置權杖、撤銷自己的權杖。
@Suite("連線配對")
struct HostServicePairingTests {
    @Test(
        "主機服務位址：沒寫 scheme 補 https,去掉結尾斜線;只有本機位址可以用 http",
        arguments: [
            ("studio.tail1234.ts.net", "https://studio.tail1234.ts.net"),
            ("https://Studio.tail1234.ts.net/", "https://studio.tail1234.ts.net"),
            ("  https://studio.tail1234.ts.net:8443  ", "https://studio.tail1234.ts.net:8443"),
            ("http://127.0.0.1:47820", "http://127.0.0.1:47820"),
        ])
    func addressNormalization(text: String, expected: String) throws {
        let address = try #require(HostServiceAddress(text))

        #expect(address.description == expected)
    }

    @Test(
        "不接受的主機服務位址",
        arguments: ["", "http://studio.tail1234.ts.net", "ftp://studio", "https://studio.ts.net/v1/ws", "https://user@studio.ts.net",
                    "https://studio.ts.net?x=1"])
    func rejectedAddresses(text: String) {
        #expect(HostServiceAddress(text) == nil)
    }

    @Test("WebSocket、配對、撤銷的網址")
    func endpoints() throws {
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let local = try #require(HostServiceAddress("http://127.0.0.1:47820"))

        #expect(address.webSocketURL.absoluteString == "wss://studio.tail1234.ts.net/v1/ws")
        #expect(address.pairURL.absoluteString == "https://studio.tail1234.ts.net/v1/pair")
        #expect(address.revokeURL.absoluteString == "https://studio.tail1234.ts.net/v1/revoke")
        #expect(local.webSocketURL.absoluteString == "ws://127.0.0.1:47820/v1/ws")
        #expect(address.hostName == "studio.tail1234.ts.net")
        #expect(address.port == 443)
    }

    @Test("QR code 的配對連結 purrdr://pair?address=…&code=…")
    func pairingLink() throws {
        let url = try #require(URL(string: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net&code=K7QM-2XPA"))

        let link = try HostServicePairingLink(url: url)

        #expect(link.address == HostServiceAddress("https://studio.tail1234.ts.net"))
        #expect(link.pairingCode == "K7QM-2XPA")
        #expect(HostServicePairingLink.isPairingLink(url))
    }

    @Test(
        "不合法的配對連結",
        arguments: [
            ("purrdr://host?d=abc", HostServicePairingLinkError.notAPairingLink),
            ("purrdr://pair?address=https%3A%2F%2Fstudio.ts.net", .malformed),
            ("purrdr://pair?code=K7QM-2XPA", .malformed),
            ("purrdr://pair?address=http%3A%2F%2Fstudio.ts.net&code=K7QM-2XPA", .malformed),
        ])
    func malformedPairingLink(text: String, expected: HostServicePairingLinkError) throws {
        let url = try #require(URL(string: text))

        #expect(throws: expected) { try HostServicePairingLink(url: url) }
    }

    @Test("主機設定記得 HTTPS 連線方式與位址，存檔再讀回不變;SSH 主機沒有位址")
    func hostConfigurationRoundTrip() throws {
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let host = HostConfiguration(name: "Studio Mac", hostService: address)

        let decoded = try JSONDecoder().decode(HostConfiguration.self, from: JSONEncoder().encode(host))

        #expect(decoded == host)
        #expect(decoded.connectionMethod == .https)
        #expect(decoded.hostService == address)
        #expect(decoded.endpoint.host == "studio.tail1234.ts.net")
        #expect(HostConfiguration(name: "Box", endpoint: SSHEndpoint(host: "box", username: "ops"), hostService: address).hostService == nil)
    }

    @Test("以配對碼換得裝置權杖")
    func pairs() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let paired = try await HostServicePairing().pair(address: service.address, pairingCode: "K7QM-2XPA", deviceName: "Ray 的 iPhone")

        #expect(paired == PairedDevice(deviceID: "5f3a9c2e81d04b7a", deviceToken: "token-paired", readOnly: false))
        let body = try #require(service.log.pairRequests.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["pairing_code": "K7QM-2XPA", "device_name": "Ray 的 iPhone"])
    }

    @Test(
        "配對碼過期或不對：錯誤種類分開",
        arguments: [("OLD0-CODE", HostServiceError.pairingCodeExpired), ("ZZZZ-ZZZZ", .pairingCodeInvalid)])
    func pairingFailures(code: String, expected: HostServiceError) async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        await #expect(throws: expected) {
            _ = try await HostServicePairing().pair(address: service.address, pairingCode: code, deviceName: "iPhone")
        }
    }

    @Test("撤銷自己的權杖：帶 Bearer 權杖;權杖已經失效也算完成")
    func revokes() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        try await HostServicePairing().revoke(address: service.address, deviceToken: "token-ok")
        try await HostServicePairing().revoke(address: service.address, deviceToken: "token-ok")

        #expect(service.log.revokeAuthorizations == ["Bearer token-ok", "Bearer token-ok"])
    }

    @Test("連不上主機服務：錯誤種類是 unreachable")
    func unreachable() async throws {
        let service = try await FakeHostService.start()
        let address = service.address
        await service.stop()

        await #expect(throws: HostServiceError.unreachable) {
            _ = try await HostServicePairing().pair(address: address, pairingCode: "K7QM-2XPA", deviceName: "iPhone")
        }
    }
}
