#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機名稱與圖示同步到後台(ADR-0016、#706):補傳、改名同步、失敗重試、欄位限制。
/// Seam:後台是 `HTTPStub`(回應依 purrdr.server#45 的契約手寫)。
@MainActor
@Suite("推播主機名稱與圖示同步")
struct PushHostProfileSyncTests {
    static let thisDevice = PushDevicesModelTests.thisDevice
    static let hash = PushDevicesModelTests.studioHash
    static let tokenHex = PushDevicesModelTests.tokenHex
    static let patchPath = "/v1/members/me/push-pairings/\(PushDevicesModelTests.studioHash)"
    static let studioIcon = PushHostIcon(symbol: "desktopcomputer", color: "#0B7A5C")!
    static let studio = PushHostProfile(name: "Studio Mac", icon: studioIcon)

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let platform = FakePushPlatform()
    let store = InMemoryPushPairingStore()

    init() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        platform.token = PushDevicesModelTests.token
        platform.status = .authorized
        store.setKeyHash(Self.hash, forHost: "studio")
        store.setRegisteredToken(Self.tokenHex, forKeyHash: Self.hash)
        backend.on("GET", "/v1/members/me/push-devices", PushDevicesModelTests.list(PushDevicesModelTests.currentPhone))
        backend.on("GET", "/v1/push-kinds", .json(404, #"{"error":{"code":"not_found","message":"x"}}"#))
    }

    func service() -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store, device: PushDevicesModelTests.identity,
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isSignedIn: { true })
    }

    /// 後台這組配對記的名稱與圖示。
    func backendHas(name: String?, icon: String = "null") {
        let name = name.map { "\"\($0)\"" } ?? "null"
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, """
            {"pairings":[{"keyHash":"\(Self.hash)","name":\(name),"icon":\(icon),"kinds":["blocked"]}]}
            """))
    }

    static let patched = HTTPStub.Reply.json(200, """
        {"pairing":{"keyHash":"\(PushDevicesModelTests.studioHash)","name":"x","icon":null,"kinds":["blocked"]}}
        """)

    @Test("升級後第一次啟動:後台還沒有名稱與圖示的配對補傳")
    func launchBackfillsMissing() async throws {
        backendHas(name: nil)
        backend.on("PATCH", Self.patchPath, Self.patched)
        let service = service()
        service.updateHostProfiles(["studio": Self.studio])

        await service.refreshAtLaunch()

        let patches = backend.requests(to: Self.patchPath)
        #expect(patches.count == 1)
        let body = try #require(patches.first?.json)
        #expect(body["name"] as? String == "Studio Mac")
        #expect(body["icon"] as? [String: String] == ["symbol": "desktopcomputer", "color": "#0B7A5C"])
        #expect(body["kinds"] == nil)
    }

    @Test("後台已經有一樣的名稱與圖示:啟動不重送")
    func launchSkipsWhatBackendHas() async {
        backendHas(name: "Studio Mac", icon: ##"{"symbol":"desktopcomputer","color":"#0b7a5c"}"##)
        let service = service()
        service.updateHostProfiles(["studio": Self.studio])

        await service.refreshAtLaunch()

        #expect(backend.requests(to: Self.patchPath).isEmpty)
    }

    @Test("在 app 改名:同步 PATCH 新名稱;沒變的圖示不影響")
    func renameSyncs() async throws {
        backendHas(name: "Studio Mac", icon: ##"{"symbol":"desktopcomputer","color":"#0B7A5C"}"##)
        backend.on("PATCH", Self.patchPath, Self.patched)
        let service = service()
        service.updateHostProfiles(["studio": Self.studio])
        await service.refreshAtLaunch()

        await service.updateHostProfiles(["studio": PushHostProfile(name: "Studio Mac Pro", icon: Self.studioIcon)])?.value

        let patches = backend.requests(to: Self.patchPath)
        #expect(patches.count == 1)
        #expect(patches.first?.json?["name"] as? String == "Studio Mac Pro")
    }

    @Test("換圖示:同步新圖示;換成「無」送 icon: null 清掉")
    func iconChangeSyncs() async throws {
        backendHas(name: "Studio Mac", icon: ##"{"symbol":"desktopcomputer","color":"#0B7A5C"}"##)
        backend.on("PATCH", Self.patchPath, Self.patched)
        let service = service()
        service.updateHostProfiles(["studio": Self.studio])
        await service.refreshAtLaunch()

        let laptop = PushHostIcon(symbol: "laptopcomputer", color: "#0B7A5C")
        await service.updateHostProfiles(["studio": PushHostProfile(name: "Studio Mac", icon: laptop)])?.value
        await service.updateHostProfiles(["studio": PushHostProfile(name: "Studio Mac", icon: nil)])?.value

        let patches = backend.requests(to: Self.patchPath)
        #expect(patches.count == 2)
        #expect(patches[0].json?["icon"] as? [String: String] == ["symbol": "laptopcomputer", "color": "#0B7A5C"])
        #expect(patches[1].json?["icon"] is NSNull)
    }

    @Test("離線:同步失敗不丟錯、不擋;網路恢復或下次啟動重送,送到後不再重送")
    func failureRetries() async {
        backendHas(name: "Old")
        backend.on("PATCH", Self.patchPath, .unreachable)
        let service = service()
        service.updateHostProfiles(["studio": PushHostProfile(name: "Old", icon: nil)])
        await service.refreshAtLaunch()

        await service.updateHostProfiles(["studio": PushHostProfile(name: "New", icon: nil)])?.value
        #expect(backend.requests(to: Self.patchPath).count == 1)

        // 網路恢復:再試一次,這次成功。
        backend.on("PATCH", Self.patchPath, Self.patched)
        await service.syncHostProfiles()
        #expect(backend.requests(to: Self.patchPath).count == 2)

        // 已送到:再同步不重送。
        await service.syncHostProfiles()
        #expect(backend.requests(to: Self.patchPath).count == 2)
    }

    @Test("離線時改的名稱,下次啟動(讀到後台舊名稱)補上")
    func failedChangeIsBackfilledNextLaunch() async {
        backendHas(name: "Old")
        backend.on("PATCH", Self.patchPath, .unreachable)
        let first = service()
        first.updateHostProfiles(["studio": PushHostProfile(name: "New", icon: nil)])
        await first.refreshAtLaunch()
        #expect(backend.requests(to: Self.patchPath).count == 1)

        backend.on("PATCH", Self.patchPath, Self.patched)
        let relaunched = service()
        relaunched.updateHostProfiles(["studio": PushHostProfile(name: "New", icon: nil)])
        await relaunched.refreshAtLaunch()

        #expect(backend.requests(to: Self.patchPath).count == 2)
    }

    @Test("欄位限制:名稱超過 64 字截到 64 再送;名稱空白不送 name")
    func nameLimit() async {
        backendHas(name: nil)
        backend.on("PATCH", Self.patchPath, Self.patched)
        let service = service()
        service.updateHostProfiles(["studio": PushHostProfile(name: String(repeating: "電", count: 100), icon: Self.studioIcon)])

        await service.refreshAtLaunch()

        let name = backend.requests(to: Self.patchPath).first?.json?["name"] as? String
        #expect(name?.unicodeScalars.count == 64)
    }

    @Test("圖示格式不合就沒有圖示:不送、不壞掉,名稱照送")
    func invalidIconIsNotSent() async {
        #expect(PushHostIcon(symbol: "bad symbol!", color: "blue") == nil)
        backendHas(name: nil)
        backend.on("PATCH", Self.patchPath, Self.patched)
        let service = service()
        service.updateHostProfiles(["studio": PushHostProfile(name: "Studio", icon: PushHostIcon(symbol: "bad symbol!", color: "blue"))])

        await service.refreshAtLaunch()

        let body = backend.requests(to: Self.patchPath).first?.json
        #expect(body?["name"] as? String == "Studio")
        // 後台沒有圖示、這邊也沒有:不需要清掉,但 PATCH 一律帶 icon(null)。
        #expect(body?["icon"] is NSNull)
    }

    @Test("沒向後台註冊過的配對(舊版 app)不 PATCH,補註冊時一併帶名稱與圖示")
    func unregisteredPairingIsRegisteredWithProfile() async {
        store.setRegisteredToken(nil, forKeyHash: Self.hash)
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        // 註冊成功後,後台的配對清單就是剛帶上去的值。
        backendHas(name: "Studio Mac", icon: ##"{"symbol":"desktopcomputer","color":"#0B7A5C"}"##)
        let service = service()
        service.updateHostProfiles(["studio": Self.studio])

        await service.refreshAtLaunch()

        let posts = backend.requests(to: "/v1/members/me/push-pairings").filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(posts.first?.json?["name"] as? String == "Studio Mac")
        #expect((posts.first?.json?["icon"] as? [String: String])?["symbol"] == "desktopcomputer")
        #expect(backend.requests(to: Self.patchPath).isEmpty)
    }

    @Test("沒有主機設定(Demo 或已刪除)的配對不送")
    func noProfileNoPatch() async {
        backendHas(name: nil)
        let service = service()

        await service.refreshAtLaunch()

        #expect(backend.requests(to: Self.patchPath).isEmpty)
    }

    @Test("主機清單:在 app 改名與換圖示,同步到那台主機的配對(HostsModel 接上推播服務)")
    func hostsModelPublishesRenameAndIcon() async throws {
        let studio = MultiHostTests.studio
        let hash = String(repeating: "7", count: 64)
        store.setKeyHash(hash, forHost: studio.id.uuidString)
        store.setRegisteredToken(Self.tokenHex, forKeyHash: hash)
        let path = "/v1/members/me/push-pairings/\(hash)"
        backend.on("GET", "/v1/members/me/push-pairings", .json(200, """
            {"pairings":[{"keyHash":"\(hash)","name":"\(studio.name)","icon":{"symbol":"desktopcomputer","color":"#0B7A5C"},"kinds":["blocked"]}]}
            """))
        backend.on("PATCH", path, Self.patched)
        let service = service()
        let hostStore = MemoryHostStore()
        hostStore.hosts = [studio]
        let hosts = HostsModel(store: hostStore, demoChannel: FakeHost(), push: service, makeChannel: ChannelsByAddress([:]).make)
        hosts.load()
        await service.refreshAtLaunch()
        #expect(backend.requests(to: path).isEmpty, "名稱與圖示都一樣,啟動不重送")

        try hosts.rename(studio.id, to: "Studio Pro")
        for _ in 0..<50 where backend.requests(to: path).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(backend.requests(to: path).last?.json?["name"] as? String == "Studio Pro")

        hosts.setIcon(.laptop, for: studio.id)
        for _ in 0..<50 where backend.requests(to: path).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect((backend.requests(to: path).last?.json?["icon"] as? [String: String])?["symbol"] == "laptopcomputer")
    }
}
#endif
