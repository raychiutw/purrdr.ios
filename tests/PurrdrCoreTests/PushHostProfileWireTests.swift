import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 推播主機的名稱與圖示(ADR-0016、#706、purrdr.server#45):欄位限制、PATCH/POST 的 body、通知裝置的 `hosts`。
@Suite("推播主機名稱與圖示:欄位限制與 wire")
struct PushHostProfileWireTests {
    typealias Backend = MemberSessionPushDevicesTests.FakeBackend
    static let device = PushDeviceID(rawValue: MemberSessionPushDevicesTests.thisDevice)!

    func makeSession(_ backend: Backend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    static func json(_ body: Data?) throws -> [String: Any] {
        let data = try #require(body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 欄位限制

    @Test("名稱:去頭尾空白、超過 64 字截到 64(不切壞字)、空白或全是控制字元不送")
    func nameLimits() {
        #expect(PushHostProfile.sanitizedName("  Studio Mac ") == "Studio Mac")
        #expect(PushHostProfile.sanitizedName(String(repeating: "a", count: 80))?.unicodeScalars.count == 64)
        let emoji = String(repeating: "👨‍👩‍👧", count: 30)
        let cut = PushHostProfile.sanitizedName(emoji)
        #expect((cut?.unicodeScalars.count ?? 99) <= 64)
        #expect(cut.map { emoji.hasPrefix($0) } == true)
        #expect(PushHostProfile.sanitizedName("   ") == nil)
        #expect(PushHostProfile.sanitizedName("\u{0007}\n") == nil)
        #expect(PushHostProfile.sanitizedName("a\u{0007}b") == "ab")
    }

    @Test("圖示:symbol 要 [A-Za-z0-9.]{1,64},color 要 #RRGGBB 或字母開頭最長 32 的短名稱;不合就沒有圖示")
    func iconLimits() {
        #expect(PushHostIcon(symbol: "server.rack", color: "#0B7A5C") != nil)
        #expect(PushHostIcon(symbol: "desktopcomputer", color: "blue") != nil)
        #expect(PushHostIcon(symbol: "", color: "blue") == nil)
        #expect(PushHostIcon(symbol: "bad symbol", color: "blue") == nil)
        #expect(PushHostIcon(symbol: "a/b", color: "blue") == nil)
        #expect(PushHostIcon(symbol: String(repeating: "a", count: 65), color: "blue") == nil)
        #expect(PushHostIcon(symbol: "cpu", color: "#12345") == nil)
        #expect(PushHostIcon(symbol: "cpu", color: "#GGGGGG") == nil)
        #expect(PushHostIcon(symbol: "cpu", color: "1blue") == nil)
        #expect(PushHostIcon(symbol: "cpu", color: String(repeating: "a", count: 33)) == nil)
        #expect(PushHostIcon(symbol: "cpu", color: "") == nil)
    }

    // MARK: - 註冊

    @Test("註冊配對:帶名稱與圖示(沒帶 profile 時兩個欄位都不送)")
    func registrationCarriesProfile() async throws {
        let backend = Backend(["POST /v1/members/me/push-pairings": MemberSessionPushDevicesTests.json(201, #"{"registered":true}"#)])
        let session = try makeSession(backend)
        let identity = PushDeviceIdentity(id: Self.device, name: "iPhone", model: .iPhone)
        let profile = PushHostProfile(name: "Studio Mac", icon: PushHostIcon(symbol: "desktopcomputer", color: "#0B7A5C"))

        try await session.registerPushPairing(keyHash: "h1", deviceToken: "aa", environment: .production, device: identity, profile: profile)
        try await session.registerPushPairing(keyHash: "h2", deviceToken: "aa", environment: .production, device: identity)

        let first = try Self.json(backend.requests[0].body)
        #expect(first["name"] as? String == "Studio Mac")
        let icon = try #require(first["icon"] as? [String: String])
        #expect(icon == ["symbol": "desktopcomputer", "color": "#0B7A5C"])
        let second = try Self.json(backend.requests[1].body)
        #expect(second["name"] == nil)
        #expect(second["icon"] == nil)
    }

    // MARK: - PATCH

    @Test("PATCH 名稱與圖示:兩者都帶,icon 兩個欄位都在;不帶 kinds")
    func patchesNameAndIcon() async throws {
        let backend = Backend(["PATCH /v1/members/me/push-pairings/h1": MemberSessionPushDevicesTests.json(
            200, ##"{"pairing":{"keyHash":"h1","name":"Studio","icon":{"symbol":"cpu","color":"#0B7A5C"},"kinds":["blocked"]}}"##)])
        let profile = PushHostProfile(name: "Studio", icon: PushHostIcon(symbol: "cpu", color: "#0B7A5C"))

        let saved = try await makeSession(backend).updatePushPairing(keyHash: "h1", profile: profile)

        #expect(saved.name == "Studio")
        #expect(saved.icon == PushHostIcon(symbol: "cpu", color: "#0B7A5C"))
        let body = try Self.json(backend.requests[0].body)
        #expect(body["name"] as? String == "Studio")
        #expect((body["icon"] as? [String: String]) == ["symbol": "cpu", "color": "#0B7A5C"])
        #expect(body["kinds"] == nil)
    }

    @Test("沒有圖示(選了「無」)時 PATCH 帶 icon: null 清掉;沒有名稱就不帶 name")
    func clearsIconWithNull() async throws {
        let backend = Backend(["PATCH /v1/members/me/push-pairings/h1": MemberSessionPushDevicesTests.json(
            200, #"{"pairing":{"keyHash":"h1","name":null,"icon":null,"kinds":["blocked"]}}"#)])

        try await makeSession(backend).updatePushPairing(keyHash: "h1", profile: PushHostProfile(name: nil, icon: nil))

        let body = try Self.json(backend.requests[0].body)
        #expect(body["icon"] is NSNull)
        #expect(body["name"] == nil)
    }

    @Test("讀配對:icon 不合格式(後台新格式)當作沒有圖示,不讓整組壞掉")
    func pairingWithUnreadableIcon() async throws {
        let backend = Backend(["GET /v1/members/me/push-pairings": MemberSessionPushDevicesTests.json(200, #"""
            {"pairings":[{"keyHash":"h1","name":"A","icon":{"symbol":"x y","color":"blue"},"kinds":["blocked"]},
                         {"keyHash":"h2","name":"B","icon":{"symbol":"cpu","color":"blue"},"kinds":["blocked"]}]}
            """#)])

        let pairings = try await makeSession(backend).pushPairings(deviceID: Self.device)

        #expect(pairings.map(\.name) == ["A", "B"])
        #expect(pairings[0].icon == nil)
        #expect(pairings[1].icon == PushHostIcon(symbol: "cpu", color: "blue"))
    }

    // MARK: - 通知裝置的主機

    @Test("通知裝置:每支裝置的 hosts(名稱、圖示)讀進來;舊後台沒有 hosts 是空;壞項目略過")
    func devicesCarryHosts() async throws {
        let json = #"""
            {"devices":[
              {"deviceId":"d1","name":"iPad","model":"iPad","hostCount":2,"lastRegisteredAt":1794729600000,"current":false,
               "hosts":[{"keyHash":"k1","name":"Studio Mac","icon":{"symbol":"desktopcomputer","color":"blue"}},
                        {"keyHash":"k2","name":null,"icon":null},
                        {"name":"no key"}]},
              {"deviceId":"d2","name":null,"model":null,"hostCount":1,"lastRegisteredAt":1794729600000,"current":true}
            ]}
            """#
        let backend = Backend(["GET /v1/members/me/push-devices": MemberSessionPushDevicesTests.json(200, json)])

        let devices = try await makeSession(backend).pushDevices(currentDeviceID: "d2")

        #expect(devices[0].hosts.map(\.name) == ["Studio Mac", nil])
        #expect(devices[0].hosts[0].icon == PushHostIcon(symbol: "desktopcomputer", color: "blue"))
        #expect(devices[0].hosts[1].icon == nil)
        #expect(devices[1].hosts.isEmpty)
    }
}
