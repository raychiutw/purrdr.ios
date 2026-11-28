import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 通知種類清單與配對的 wire(ADR-0016、purrdr.server#39/#45):照後台給的畫,向前相容,舊後台與壞資料不讓 app 壞掉。
@Suite("通知種類：後台清單的 wire")
struct PushKindCatalogWireTests {
    typealias Backend = MemberSessionPushDevicesTests.FakeBackend
    static let device = PushDeviceID(rawValue: MemberSessionPushDevicesTests.thisDevice)!

    func makeSession(_ backend: Backend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    static func ok(_ text: String) -> BackendResponse {
        MemberSessionPushDevicesTests.json(200, text)
    }

    static let kindsJSON = #"""
        {"kinds":[
          {"code":"usage_alert","name":{"en":"Plan usage running low","zh-Hant":"方案用量快用完"},
           "description":{"en":"At 80% and 95%.","zh-Hant":"到 80%、95% 時通知。"},
           "defaultOn":true,"transports":["ssh","https"],"minServiceVersion":null,"minPluginVersion":"0.3.0","order":60},
          {"code":"blocked","name":{"en":"Needs You","zh-Hant":"需要你"},"description":{"en":"Waiting.","zh-Hant":"在等你。"},
           "defaultOn":true,"transports":["ssh","https"],"minServiceVersion":null,"minPluginVersion":null,"order":10},
          {"code":"queue_paused","name":{"en":"Queued send paused","zh-Hant":"預約送出被暫停"},"description":{"en":"x"},
           "defaultOn":true,"transports":["https"],"minServiceVersion":"0.16.0","minPluginVersion":null,"order":55,"futureField":{"a":1}}
        ],"serverTime":"2026-11-28T00:00:00Z"}
        """#

    @Test("讀清單：依 order 排、名稱說明兩種語言、預設、連線方式與最低版本都帶進來")
    func parsesCatalog() async throws {
        let backend = Backend(["GET /v1/push-kinds": Self.ok(Self.kindsJSON)])
        let catalog = try await makeSession(backend).pushKinds()

        #expect(catalog.source == .backend)
        #expect(catalog.definitions.map(\.kind.rawValue) == ["blocked", "queue_paused", "usage_alert"])
        let queue = try #require(catalog.definition(for: PushKind("queue_paused")))
        #expect(queue.defaultOn)
        #expect(queue.transports == [.https])
        #expect(queue.minServiceVersion == HostServiceVersion(0, 16, 0))
        #expect(queue.name.resolved(preferredLanguages: ["zh-Hant-TW"]) == "預約送出被暫停")
        #expect(queue.name.resolved(preferredLanguages: ["en"]) == "Queued send paused")
        // 缺繁中就用英文
        #expect(queue.description.resolved(preferredLanguages: ["zh-Hant"]) == "x")
        let usage = try #require(catalog.definition(for: PushKind("usage_alert")))
        #expect(usage.minPluginVersion == HostServiceVersion(0, 3, 0))
        #expect(usage.transports == [.ssh, .https])
        #expect(backend.requests.first?.path == "/v1/push-kinds")
    }

    @Test("後台多給欄位、讀不懂的項目與沒見過的種類：不讓整份清單壞掉，新種類照樣列出")
    func tolerantOfExtraAndMalformed() async throws {
        let json = #"""
            {"kinds":[
              {"code":"brand_new_kind","name":{"en":"Brand New"},"order":5,"extra":[1,2,3]},
              {"name":{"en":"no code"}},
              "garbage",
              {"code":"blocked","name":{"en":"Needs You"},"order":10,"transports":["carrier-pigeon"]}
            ]}
            """#
        let backend = Backend(["GET /v1/push-kinds": Self.ok(json)])
        let catalog = try await makeSession(backend).pushKinds()

        #expect(catalog.definitions.map(\.kind.rawValue) == ["brand_new_kind", "blocked"])
        let new = try #require(catalog.definition(for: PushKind("brand_new_kind")))
        #expect(new.name.resolved(preferredLanguages: ["zh-Hant"]) == "Brand New")
        #expect(new.transports == nil)  // 沒給就是不限
        #expect(new.defaultOn == false)
        // 只給不認得的連線方式：兩種連線都用不了
        let blocked = try #require(catalog.definition(for: .blocked))
        #expect(blocked.transports == [])
        #expect(blocked.availability(installsViaHostService: true, hostServiceVersion: nil) == .unsupportedConnection)
    }

    @Test("連線方式與版本：SSH 看不到只給 https 的、版本不足要更新、版本未知不擋")
    func availabilityRules() {
        let https = PushKindDefinition(
            kind: PushKind("queue_paused"), name: .init(english: "q"), description: .init(english: ""), defaultOn: true,
            transports: [.https], minServiceVersion: HostServiceVersion(0, 16, 0), order: 1)
        #expect(https.availability(installsViaHostService: false, hostServiceVersion: nil) == .needsHostService)
        #expect(https.availability(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 15, 9))
            == .needsHostServiceUpdate(minimum: HostServiceVersion(0, 16, 0)))
        #expect(https.availability(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 16, 0)) == .available)
        #expect(https.availability(installsViaHostService: true, hostServiceVersion: nil) == .available)
        let plugin = PushKindDefinition(
            kind: PushKind("long_work_done"), name: .init(english: "l"), description: .init(english: ""), defaultOn: false,
            minPluginVersion: HostServiceVersion(0, 3, 0), order: 2)
        #expect(plugin.availability(installsViaHostService: false, hostServiceVersion: nil, pluginVersion: HostServiceVersion(0, 2, 0))
            == .needsPluginUpdate(minimum: HostServiceVersion(0, 3, 0)))
        #expect(plugin.availability(installsViaHostService: false, hostServiceVersion: nil, pluginVersion: nil) == .available)
        #expect(plugin.availability(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 1, 0)) == .available)
    }

    @Test("語言：繁中系統用繁中,其餘(含簡中)用英文")
    func languageResolution() {
        let text = PushLocalizedText(english: "Finished", traditionalChinese: "完成")
        #expect(text.resolved(preferredLanguages: ["zh-Hant"]) == "完成")
        #expect(text.resolved(preferredLanguages: ["zh-Hant-TW", "en"]) == "完成")
        #expect(text.resolved(preferredLanguages: ["zh-TW"]) == "完成")
        #expect(text.resolved(preferredLanguages: ["en"]) == "Finished")
        #expect(text.resolved(preferredLanguages: ["zh-Hans"]) == "Finished")
        #expect(text.resolved(preferredLanguages: []) == "Finished")
    }

    @Test("讀這支裝置的配對：帶 deviceId、種類原樣保留(含沒見過的)、多給的欄位與缺 kinds 的項目不影響")
    func parsesPairings() async throws {
        let json = #"""
            {"pairings":[
              {"keyHash":"h1","name":"Studio Mac","icon":{"symbol":"desktopcomputer","color":"blue"},"kinds":["blocked","brand_new_kind"]},
              {"keyHash":"h2","name":null,"icon":null,"kinds":[]},
              {"keyHash":"h3","name":"no kinds"}
            ]}
            """#
        let backend = Backend(["GET /v1/members/me/push-pairings": Self.ok(json)])
        let pairings = try await makeSession(backend).pushPairings(deviceID: Self.device)

        #expect(pairings.map(\.keyHash) == ["h1", "h2"])
        #expect(pairings[0].kinds == [.blocked, PushKind("brand_new_kind")])
        #expect(pairings[0].name == "Studio Mac")
        #expect(pairings[1].kinds == [])
        let request = try #require(backend.requests.first)
        #expect(request.query.first { $0.name == "deviceId" }?.value == Self.device.backendValue)
    }

    @Test("改配對的種類：PATCH 帶排序過的 kinds,回傳後台記的值")
    func patchesPairingKinds() async throws {
        let backend = Backend([
            "PATCH /v1/members/me/push-pairings/h1": Self.ok(
                #"{"pairing":{"keyHash":"h1","name":null,"icon":null,"kinds":["blocked","usage_alert"]}}"#)
        ])
        let saved = try await makeSession(backend).updatePushPairing(keyHash: "h1", kinds: [PushKind("usage_alert"), .blocked])

        #expect(saved.kinds == [.blocked, PushKind("usage_alert")])
        let request = try #require(backend.requests.first)
        #expect(request.method == "PATCH")
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kinds"] as? [String] == ["blocked", "usage_alert"])
        #expect(json.keys.sorted() == ["kinds"])
    }

    @Test("後台回 400(未知或停用的種類)：丟出後台錯誤")
    func patchRejection() async throws {
        let backend = Backend([
            "PATCH /v1/members/me/push-pairings/h1": MemberSessionPushDevicesTests.json(
                400, #"{"error":{"code":"invalid_kind","message":"x"}}"#)
        ])
        let session = try makeSession(backend)
        await #expect(throws: BackendError.self) {
            try await session.updatePushPairing(keyHash: "h1", kinds: [PushKind("gone")])
        }
    }
}
