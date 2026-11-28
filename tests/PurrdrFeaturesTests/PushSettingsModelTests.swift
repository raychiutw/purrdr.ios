#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 通知設定(ADR-0016、#705):照後台的種類清單畫每台主機的開關,配對的種類以後台為準;
/// 讀不到、舊後台或壞資料時退回內建備援,不擋住整頁。後台以 `HTTPStub` 擋。
@MainActor
@Suite("通知設定：後台的種類清單與配對")
struct PushSettingsModelTests {
    static let deviceID = PushDeviceID(rawValue: "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70")!
    static let hashA = String(repeating: "a", count: 64)
    static let hashB = String(repeating: "b", count: 64)
    static let paired = #"{"registered":true}"#

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let platform = FakePushPlatform()
    let store = InMemoryPushPairingStore()
    /// 通知設定只弱引用 service,測試自己留著。
    let pushService: PushService

    init() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        platform.token = Data(repeating: 0x5E, count: 32)
        platform.status = .authorized
        pushService = Self.makeService(backend: backend, tokens: tokens, platform: platform, store: store)
    }

    func service() -> PushService { pushService }

    static func makeService(backend: HTTPStub, tokens: InMemoryTokenStore, platform: FakePushPlatform, store: InMemoryPushPairingStore) -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store, device: PushDeviceIdentity(id: Self.deviceID, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isSignedIn: { true })
    }

    func settings(languages: [String] = ["en"]) -> PushSettingsModel {
        let settings = service().settings
        settings.preferredLanguages = { languages }
        return settings
    }

    static let catalogJSON = #"""
        {"kinds":[
          {"code":"blocked","name":{"en":"Needs You","zh-Hant":"需要你"},"description":{"en":"Waiting for you.","zh-Hant":"在等你。"},
           "defaultOn":true,"transports":["ssh","https"],"order":10},
          {"code":"done","name":{"en":"Finished","zh-Hant":"完成"},"description":{"en":"Done.","zh-Hant":"做完了。"},
           "defaultOn":false,"transports":["ssh","https"],"order":20},
          {"code":"queue_paused","name":{"en":"Queued send paused","zh-Hant":"預約送出被暫停"},"description":{"en":"Paused.","zh-Hant":"暫停了。"},
           "defaultOn":true,"transports":["https"],"minServiceVersion":"0.16.0","order":30},
          {"code":"daily_limit_reached","name":{"en":"Daily limit reached","zh-Hant":"每日上限已達"},"description":{"en":"Limit.","zh-Hant":"上限。"},
           "defaultOn":true,"transports":["ssh","https"],"order":90},
          {"code":"tomorrow_kind","name":{"en":"Added next month","zh-Hant":"下個月新增"},"description":{"en":"New.","zh-Hant":"新的。"},
           "defaultOn":false,"order":95,"somethingNew":true}
        ]}
        """#

    // MARK: - 照清單畫開關

    @Test("照後台清單畫開關:順序、名稱與說明依手機語言(英文)")
    func choicesFollowBackendCatalogInEnglish() async {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings()
        await settings.load()

        let choices = settings.choices(for: PushKindContext(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 16, 0)))
        #expect(choices.map(\.kind.rawValue) == ["blocked", "done", "queue_paused", "daily_limit_reached", "tomorrow_kind"])
        #expect(choices.map(\.title) == ["Needs You", "Finished", "Queued send paused", "Daily limit reached", "Added next month"])
        #expect(choices[0].details == "Waiting for you.")
        #expect(choices.allSatisfy { $0.availability == .available })
    }

    @Test("繁中系統顯示後台的繁中名稱與說明")
    func choicesInTraditionalChinese() async {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings(languages: ["zh-Hant"])
        await settings.load()

        let choices = settings.choices(for: .ssh)
        #expect(choices.first?.title == "需要你")
        #expect(choices.first?.details == "在等你。")
    }

    @Test("後台新增、app 沒見過的種類照樣顯示,而且可以開關(「每日上限已達」也在清單裡)")
    func unknownKindsAreShown() async {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings()
        await settings.load()

        let choices = settings.choices(for: .ssh)
        #expect(choices.contains { $0.kind == PushKind("tomorrow_kind") && $0.availability == .available })
        #expect(choices.contains { $0.kind == .dailyLimitReached && $0.availability == .available })
    }

    // MARK: - 停用條件

    @Test("SSH 主機:只給 https 的種類停用並說明要主機服務;其餘可開")
    func httpsOnlyKindDisabledOnSSHHost() async throws {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings()
        await settings.load()

        let queue = try #require(settings.choices(for: .ssh).first { $0.kind.rawValue == "queue_paused" })
        #expect(queue.availability == .needsHostService)
    }

    @Test("HTTPS 主機:主機服務太舊停用並說明最低版本;版本未知時不擋")
    func outdatedHostServiceDisabled() async throws {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings()
        await settings.load()

        let old = try #require(settings.choices(for: PushKindContext(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 15, 0)))
            .first { $0.kind.rawValue == "queue_paused" })
        #expect(old.availability == .needsHostServiceUpdate(minimum: HostServiceVersion(0, 16, 0)))
        let unknown = try #require(settings.choices(for: PushKindContext(installsViaHostService: true)).first { $0.kind.rawValue == "queue_paused" })
        #expect(unknown.availability == .available)
    }

    @Test("新配對預設收清單預設開、而且這台主機現在就能用的:SSH 沒有 queue_paused")
    func defaultKindsFollowCatalogAndHost() async {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        let settings = settings()
        await settings.load()

        #expect(settings.defaultKinds(for: .ssh) == [.blocked, .dailyLimitReached])
        #expect(settings.defaultKinds(for: PushKindContext(installsViaHostService: true, hostServiceVersion: HostServiceVersion(0, 16, 0)))
            == [.blocked, PushKind("queue_paused"), .dailyLimitReached])
    }

    // MARK: - 讀不到:退回內建

    @Test("離線:退回內建的五種,整頁不空白、不丟錯")
    func offlineFallsBackToBuiltIn() async {
        backend.on("GET", "/v1/push-kinds", .unreachable)
        let settings = settings()
        await settings.load()

        #expect(settings.catalog.source == .builtIn)
        #expect(settings.choices(for: PushKindContext(installsViaHostService: true)).map(\.kind.rawValue)
            == ["blocked", "done", "stuck", "reminder", "host_service"])
        // SSH 主機:只給 HTTPS 的三種仍列出,但停用並說明要裝主機服務
        let ssh = settings.choices(for: .ssh)
        #expect(ssh.map(\.kind.rawValue) == ["blocked", "done", "stuck", "reminder", "host_service"])
        #expect(ssh.map(\.availability) == [.available, .available, .needsHostService, .needsHostService, .needsHostService])
        #expect(settings.defaultKinds(for: .ssh) == [.blocked, .done])
        #expect(!settings.usesBackendKinds)
    }

    @Test("舊後台(沒有清單 API,404):退回內建的五種")
    func oldBackendFallsBackToBuiltIn() async {
        backend.on("GET", "/v1/push-kinds", .json(404, #"{"error":{"code":"not_found","message":"x"}}"#))
        let settings = settings()
        await settings.load()

        #expect(settings.catalog.source == .builtIn)
        #expect(settings.catalog.definitions.count == 5)
    }

    @Test("後台回空清單或壞資料:仍用內建備援,不會整頁空白")
    func emptyOrGarbageFallsBackToBuiltIn() async {
        backend.on("GET", "/v1/push-kinds", .json(200, #"{"kinds":[]}"#))
        let empty = settings()
        await empty.load()
        #expect(empty.catalog.source == .builtIn)

        backend.on("GET", "/v1/push-kinds", .json(200, "not json"))
        let garbage = settings()
        await garbage.load()
        #expect(garbage.catalog.source == .builtIn)
        #expect(!garbage.choices(for: .ssh).isEmpty)
    }

    @Test("讀到清單後再離線:維持上次讀到的清單,不退回內建")
    func keepsLastLoadedCatalogWhenOffline() async {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON), .unreachable)
        let settings = settings()
        await settings.load()
        await settings.load()

        #expect(settings.catalog.source == .backend)
        #expect(settings.catalog.definitions.count == 5)
    }

    @Test("內建備援的名稱也依語言(繁中)")
    func builtInRespectsLanguage() {
        let settings = settings(languages: ["zh-Hant"])
        #expect(settings.choices(for: .ssh).map(\.title) == ["需要你", "完成", "可能卡住", "仍在等你", "主機服務"])
    }

    // MARK: - 配對以後台為準

    @Test("讀到後台的配對:種類寫回本機紀錄(後台為準),已開著的主機開關跟著更新")
    func pairingKindsComeFromBackend() async throws {
        store.setKeyHash(Self.hashA, forHost: "studio")
        store.setKinds([.blocked], forKeyHash: Self.hashA)
        let service = service()
        let model = PushModel(service: service, hostID: "studio", installer: FakePushPluginHost().installer(deviceID: Self.deviceID), muted: { [] })
        #expect(model.kinds == [.blocked])
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        backend.on(
            "GET", "/v1/members/me/push-pairings",
            .json(200, #"{"pairings":[{"keyHash":"\#(Self.hashA)","name":"Studio","icon":null,"kinds":["blocked","daily_limit_reached","tomorrow_kind"]},{"keyHash":"\#(Self.hashB)","kinds":["done"]}]}"#))

        await service.settings.load()

        #expect(store.kinds(forKeyHash: Self.hashA) == [.blocked, .dailyLimitReached, PushKind("tomorrow_kind")])
        #expect(model.kinds == [.blocked, .dailyLimitReached, PushKind("tomorrow_kind")])
        // 這支裝置沒有的配對(本機沒有紀錄)不寫入
        #expect(store.kinds(forKeyHash: Self.hashB) == nil)
        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first)
        #expect(request.query["deviceId"] == Self.deviceID.backendValue)
    }

    @Test("升級遷移:舊版 app 開的配對(本機沒記種類)後台沒給種類時,維持視為只收「需要你」,不被重設")
    func legacyPairingIsNotResetByEmptyBackendKinds() async {
        store.setKeyHash(Self.hashA, forHost: "studio")
        let service = service()
        let model = PushModel(service: service, hostID: "studio", installer: FakePushPluginHost().installer(deviceID: Self.deviceID), muted: { [] })
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, #"{"pairings":[{"keyHash":"\#(Self.hashA)","kinds":[]}]}"#))

        await service.settings.load()

        #expect(model.kinds == [.blocked])
        #expect(store.kinds(forKeyHash: Self.hashA) == nil)
    }

    @Test("讀不到配對(舊後台 404、離線):維持本機記錄,沒有重設")
    func localKindsKeptWhenPairingsUnavailable() async {
        store.setKeyHash(Self.hashA, forHost: "studio")
        store.setKinds([.blocked, .done], forKeyHash: Self.hashA)
        let service = service()
        let model = PushModel(service: service, hostID: "studio", installer: FakePushPluginHost().installer(deviceID: Self.deviceID), muted: { [] })
        backend.on("GET", "/v1/push-kinds", .json(404, #"{"error":{"code":"not_found","message":"x"}}"#))
        backend.on("GET", "/v1/members/me/push-pairings", .unreachable)

        await service.settings.load()

        #expect(model.kinds == [.blocked, .done])
        #expect(store.kinds(forKeyHash: Self.hashA) == [.blocked, .done])
    }

    // MARK: - 讀寫配對種類

    func turnedOn(_ service: PushService, context: PushKindContext = .ssh) async -> PushModel {
        let model = PushModel(service: service, hostID: "studio", installer: FakePushPluginHost().installer(deviceID: Self.deviceID), muted: { [] })
        await model.requestOn()
        await model.confirm(kindContext: context)
        return model
    }

    @Test("新開啟:註冊配對帶清單的預設種類(這台主機能用的)")
    func turningOnRegistersCatalogDefaults() async throws {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, #"{"pairings":[]}"#))
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, Self.paired))
        let service = service()
        await service.settings.load()

        let model = await turnedOn(service)

        #expect(model.state == .on)
        #expect(model.kinds == [.blocked, .dailyLimitReached])
        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first { $0.method == "POST" })
        #expect(request.json?["kinds"] as? [String] == ["blocked", "daily_limit_reached"])
    }

    @Test("後台清單在用時改種類走 PATCH:只送清單有的代號,回來的值寫進本機;「每日上限已達」可以關")
    func settingKindPatchesPairing() async throws {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, #"{"pairings":[]}"#))
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, Self.paired))
        let service = service()
        await service.settings.load()
        let model = await turnedOn(service)
        let keyHash = try #require(store.keyHash(forHost: "studio"))
        // 本機另外留著一個清單已經沒有的代號(後台停用了)
        store.setKinds([.blocked, .dailyLimitReached, PushKind("retired")], forKeyHash: keyHash)
        model.reloadKinds()
        backend.on(
            "PATCH", "/v1/members/me/push-pairings/\(keyHash)",
            .json(200, #"{"pairing":{"keyHash":"\#(keyHash)","name":null,"icon":null,"kinds":["blocked"]}}"#))

        await model.setKind(.dailyLimitReached, isOn: false)

        let patch = try #require(backend.requests(to: "/v1/members/me/push-pairings/\(keyHash)").first)
        #expect(patch.method == "PATCH")
        #expect(patch.json?["kinds"] as? [String] == ["blocked"])
        #expect(model.kinds == [.blocked])
        #expect(store.kinds(forKeyHash: keyHash) == [.blocked])
        #expect(model.problem == nil)
        // 沒有重送註冊(只有開啟時的那一次 POST)
        #expect(backend.requests(to: "/v1/members/me/push-pairings").filter { $0.method == "POST" }.count == 1)
    }

    @Test("PATCH 被後台拒絕(400):維持原本的種類並說明")
    func patchFailureKeepsKinds() async throws {
        backend.on("GET", "/v1/push-kinds", .json(200, Self.catalogJSON))
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, #"{"pairings":[]}"#))
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, Self.paired))
        let service = service()
        await service.settings.load()
        let model = await turnedOn(service)
        let keyHash = try #require(store.keyHash(forHost: "studio"))
        backend.on("PATCH", "/v1/members/me/push-pairings/\(keyHash)", .json(400, #"{"error":{"code":"invalid_kind","message":"x"}}"#))

        await model.setKind(PushKind("tomorrow_kind"), isOn: true)

        #expect(model.kinds == [.blocked, .dailyLimitReached])
        guard case .kindsUpdateFailed = model.problem else {
            Issue.record("沒有說明改種類失敗:\(String(describing: model.problem))")
            return
        }
    }

    @Test("讀不到清單(內建備援)時改種類仍走原本的重送註冊,不打 PATCH")
    func builtInCatalogStillReRegisters() async throws {
        backend.on("GET", "/v1/push-kinds", .unreachable)
        backend.on("GET", "/v1/members/me/push-pairings", .unreachable)
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, Self.paired), .json(201, Self.paired))
        let service = service()
        await service.settings.load()
        let model = await turnedOn(service)
        #expect(model.kinds == [.blocked, .done])

        await model.setKind(.done, isOn: false)

        #expect(model.kinds == [.blocked])
        let posts = backend.requests(to: "/v1/members/me/push-pairings").filter { $0.method == "POST" }
        #expect(posts.last?.json?["kinds"] as? [String] == ["blocked"])
        #expect(backend.requests.allSatisfy { $0.method != "PATCH" })
    }
}
#endif
