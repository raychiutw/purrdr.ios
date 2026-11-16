#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 推播開關(行為規格 F14、ADR-0004):權限只在打開時請求、要有 Purrdr Plus、經 SSH 安裝外掛並建立推播配對，
/// 關閉時移除外掛與設定並撤銷配對。
///
/// Seam:主機是 `LocalShellHost`(暫存家目錄、真的 `/bin/sh`,herdr 換成 `FakeHerdrPluginCLI`);
/// 後台是 `HTTPStub`(回應依 backend/README.md 契約手寫);通知權限與 APNs token 是 `FakePushPlatform`。
@MainActor
@Suite("推播開關")
struct PushModelTests {
    static let endpoint = URL(string: "https://backend.test/v1/push")!
    static let token = Data([0xA1, 0xB2, 0xC3, 0xD4] + Array(repeating: 0x5E, count: 28))
    static let tokenHex = "a1b2c3d4" + String(repeating: "5e", count: 28)

    let host: LocalShellHost
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let platform = FakePushPlatform()
    let store = InMemoryPushPairingStore(deviceID: "0123456789abcdef")

    init() throws {
        host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        platform.token = Self.token
    }

    func service(plusActive: Bool = true) -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store,
            configuration: PushConfiguration(endpoint: Self.endpoint, environment: .production, pluginSource: "raychiutw/purrdr-host-plugin"),
            isPlusActive: { plusActive })
    }

    func model(_ service: PushService, hostID: String? = "studio", muted: Set<String> = []) -> PushModel {
        PushModel(service: service, hostID: hostID, channel: host, herdr: HerdrInstallation(), muted: { muted })
    }

    var pairingURL: URL { host.url(".purrdr/push-0123456789abcdef/pairing") }

    func pairingOnHost() throws -> PushPairingFile? {
        guard FileManager.default.fileExists(atPath: pairingURL.path) else { return nil }
        return PushPairingFile(contents: try Data(contentsOf: pairingURL))
    }

    /// 打開開關直到確認畫面，再確認。
    func turnOn(_ model: PushModel) async {
        await model.requestOn()
        await model.confirm()
    }

    // MARK: - 打開

    @Test("打開：請求權限、取 token、說明以哪個使用者安裝，確認後在主機寫配對並安裝外掛")
    func turningOnPairsHost() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let model = model(service())

        await model.requestOn()

        #expect(platform.authorizationRequests == 1)
        #expect(model.state == .confirming(user: NSUserName()))
        #expect(try pairingOnHost() == nil)

        await model.confirm()

        #expect(model.state == .on)
        #expect(model.problem == nil)
        let file = try #require(try pairingOnHost())
        #expect(file.endpoint == Self.endpoint)
        #expect(FakeHerdrPluginCLI.isPluginInstalled(on: host))
        #expect(store.keyHash(forHost: "studio") == file.key.hash)
    }

    @Test("後台只拿到配對密鑰的雜湊，密鑰本身不送出，app 也不保存")
    func backendGetsOnlyKeyHash() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let model = model(service())

        await turnOn(model)

        let file = try #require(try pairingOnHost())
        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first)
        #expect(request.json?["keyHash"] as? String == file.key.hash)
        #expect(request.json?["deviceToken"] as? String == Self.tokenHex)
        #expect(request.json?["environment"] as? String == "production")
        #expect(request.json?["platform"] as? String == "apns")
        #expect(!String(decoding: request.body, as: UTF8.self).contains(file.key.hex))
        #expect(store.keyHash(forHost: "studio") != file.key.hex)
    }

    @Test("配對檔帶入已靜音的聊天")
    func pairingCarriesMutedChats() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let model = model(service(), muted: ["session-1"])

        await turnOn(model)

        #expect(try pairingOnHost()?.muted == ["session-1"])
    }

    @Test("已授權時不再請求權限")
    func alreadyAuthorizedDoesNotAsk() async throws {
        platform.status = .authorized
        let model = model(service())

        await model.requestOn()

        #expect(platform.authorizationRequests == 0)
        #expect(model.state == .confirming(user: NSUserName()))
    }

    @Test("Demo 主機不能推播：說明，不請求權限")
    func demoHostCannotPush() async {
        let model = model(service(), hostID: nil)

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .demoHost)
        #expect(platform.authorizationRequests == 0)
    }

    @Test("沒有 Purrdr Plus:提示訂閱，不請求權限、不碰主機")
    func needsSubscription() async throws {
        let model = model(service(plusActive: false))

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .needsSubscription)
        #expect(platform.authorizationRequests == 0)
        #expect(try FakeHerdrPluginCLI.calls(on: host).isEmpty)
    }

    @Test("權限被拒：說明並提供打開 iOS 設定，不碰主機")
    func permissionDenied() async throws {
        platform.grants = false
        let model = model(service())

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .permissionDenied)
        #expect(try FakeHerdrPluginCLI.calls(on: host).isEmpty)
        model.openSystemSettings()
        #expect(platform.openedSettings == 1)
    }

    @Test("取不到 APNs token(模擬器、缺 entitlement):此裝置不支援，顯示原始錯誤")
    func tokenFailure() async {
        platform.token = nil
        let model = model(service())

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .unsupportedDevice("no aps-environment entitlement"))
    }

    @Test("後台說沒有有效訂閱(403):提示訂閱，主機不動")
    func backendRequiresSubscription() async throws {
        backend.on("POST", "/v1/members/me/push-pairings",
            .json(403, #"{"error":{"code":"subscription_required","message":"This needs an active Purrdr Plus subscription."}}"#))
        let before = try FakeHerdrPluginCLI.snapshot(of: host)
        let model = model(service())

        await turnOn(model)

        #expect(model.state == .off)
        #expect(model.problem == .needsSubscription)
        #expect(try FakeHerdrPluginCLI.snapshot(of: host) == before)
        #expect(store.keyHash(forHost: "studio") == nil)
    }

    @Test("主機上安裝外掛失敗：撤銷剛註冊的配對，主機回到原樣並說明")
    func hostFailureRevokesPairing() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        try host.write(Data(), to: "fake/install-fails")
        let before = try FakeHerdrPluginCLI.snapshot(of: host)
        let model = model(service())

        await turnOn(model)

        #expect(model.state == .off)
        guard case .failed(let message)? = model.problem else { Issue.record("沒有說明"); return }
        #expect(message.contains("git clone failed"))
        let hash = try #require(backend.requests(to: "/v1/members/me/push-pairings").first?.json?["keyHash"] as? String)
        #expect(backend.requests.contains { $0.method == "DELETE" && $0.path == "/v1/members/me/push-pairings/\(hash)" })
        #expect(try FakeHerdrPluginCLI.snapshot(of: host) == before)
        #expect(store.keyHash(forHost: "studio") == nil)
    }

    // MARK: - 關閉

    @Test("關閉：移除主機上的外掛與配對(與打開前完全相同)並撤銷後台的配對")
    func turningOffRemovesEverything() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let before = try FakeHerdrPluginCLI.snapshot(of: host)
        let service = service()
        let model = model(service)
        await turnOn(model)
        let hash = try #require(store.keyHash(forHost: "studio"))
        backend.on("DELETE", "/v1/members/me/push-pairings/\(hash)", .empty(204))

        await model.turnOff()

        #expect(model.state == .off)
        #expect(try FakeHerdrPluginCLI.snapshot(of: host) == before)
        #expect(!FakeHerdrPluginCLI.isPluginInstalled(on: host))
        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(hash)").count == 1)
        #expect(store.keyHash(forHost: "studio") == nil)
    }

    @Test("刪除主機時移除配對：用完另開的那條連線就關閉，不留著")
    func forgettingClosesItsChannel() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let service = service()
        await turnOn(model(service))
        let hash = try #require(store.keyHash(forHost: "studio"))
        backend.on("DELETE", "/v1/members/me/push-pairings/\(hash)", .empty(204))
        let channel = DisconnectCountingChannel(host)

        service.forget(hostID: "studio", channel: channel, herdr: HerdrInstallation())

        for _ in 0..<200 where await channel.disconnects == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await channel.disconnects == 1, "刪配對另開的連線沒有關閉")
        #expect(!FakeHerdrPluginCLI.isPluginInstalled(on: host))
    }

    @Test("已配對的主機重新建立 model 時是開著的")
    func pairedHostStartsOn() {
        store.setKeyHash(String(repeating: "0", count: 64), forHost: "studio")
        #expect(model(service()).state == .on)
        #expect(model(service(), hostID: "other").state == .off)
    }

    // MARK: - 靜音、token 輪替

    @Test("靜音聊天：改寫主機上這支裝置的靜音清單")
    func mutingRewritesHostList() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let model = model(service())
        await turnOn(model)

        await model.syncMuted(["session-9"])

        #expect(try pairingOnHost()?.muted == ["session-9"])
    }

    @Test("推播關著時靜音不碰主機")
    func mutingWhileOffDoesNothing() async throws {
        let model = model(service())

        await model.syncMuted(["session-9"])

        #expect(try FakeHerdrPluginCLI.calls(on: host).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("APNs token 換了：對每組配對向後台重新註冊(主機不用改)")
    func tokenRotationReRegisters() async throws {
        store.setKeyHash(String(repeating: "1", count: 64), forHost: "studio")
        store.setKeyHash(String(repeating: "2", count: 64), forHost: "linux")
        store.lastDeviceToken = "old"
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))

        await service().refreshRegistrations()

        let hashes = backend.requests(to: "/v1/members/me/push-pairings").compactMap { $0.json?["keyHash"] as? String }
        #expect(Set(hashes) == [String(repeating: "1", count: 64), String(repeating: "2", count: 64)])
        #expect(store.lastDeviceToken == Self.tokenHex)
        #expect(platform.authorizationRequests == 0)
    }

    @Test("啟動時 token 沒變：不送後台，也不請求權限")
    func unchangedTokenDoesNothing() async {
        store.setKeyHash(String(repeating: "1", count: 64), forHost: "studio")
        store.lastDeviceToken = Self.tokenHex
        platform.status = .authorized

        await service().refreshRegistrations()

        #expect(backend.requests(to: "/v1/members/me/push-pairings").isEmpty)
        #expect(platform.authorizationRequests == 0)
    }

    @Test("沒有任何配對時啟動不取 token、不請求權限")
    func noPairingsAtLaunch() async {
        await service().refreshRegistrations()

        #expect(platform.tokenRequests == 0)
        #expect(platform.authorizationRequests == 0)
    }
}

/// 點通知：依 payload 的 `pairing`(配對密鑰雜湊)找到主機，切換過去並開該 Agent 的聊天。
@MainActor
@Suite("點通知")
struct PushRouteTests {
    @Test("payload 只讀 pairing 與 pane")
    func parsesPayload() {
        let route = PushRoute(userInfo: ["aps": ["alert": ["title": "weather-app"]], "pairing": "abc", "pane": "w2:p1", "status": "blocked"])
        #expect(route == PushRoute(keyHash: "abc", paneID: "w2:p1"))
        #expect(PushRoute(userInfo: ["aps": [:]]) == nil)
    }

    @Test("開配對主機上該 Agent 的聊天;所有主機都在同一個列表，不切換選取中主機(#39)")
    func opensAgentOnPairedHost() {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore(deviceID: "0123456789abcdef")
        pairings.setKeyHash("abc", forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()
        model.select(.demo)

        model.open(PushRoute(keyHash: "abc", paneID: "w2:p1"), pairings: pairings)

        #expect(model.selection == .demo)
        #expect(model.agentList.openedChat == ChatRoute(host: .host(HostsModelTests.studio.id), paneID: "w2:p1"))
    }

    @Test("同一則通知(request id)只處理一次(冷啟動會收到兩次)")
    func routerDeduplicates() {
        let router = PushNotificationRouter()
        let route = PushRoute(keyHash: "abc", paneID: "w2:p1")

        router.receive(route, requestID: "n1")
        #expect(router.pending == route)
        router.pending = nil
        router.receive(route, requestID: "n1")
        #expect(router.pending == nil)
        router.receive(route, requestID: "n2")
        #expect(router.pending == route)
    }

    @Test("不認得的配對(主機已移除)不切換")
    func unknownPairingIsIgnored() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        model.open(PushRoute(keyHash: "nope", paneID: "w2:p1"), pairings: InMemoryPushPairingStore(deviceID: "a"))

        #expect(model.selection == .demo)
        #expect(model.agentList.openedChat == nil)
    }
}

/// 通知權限與 APNs token 的替身。
@MainActor
final class FakePushPlatform: PushPlatform {
    var status: PushAuthorization = .notDetermined
    var grants = true
    var token: Data?
    private(set) var authorizationRequests = 0
    private(set) var tokenRequests = 0
    private(set) var openedSettings = 0

    func authorization() async -> PushAuthorization { status }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func deviceToken() async throws -> Data {
        tokenRequests += 1
        guard let token else { throw FakePushPlatformError(message: "no aps-environment entitlement") }
        return token
    }

    func openSettings() { openedSettings += 1 }
}

struct FakePushPlatformError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// 轉給真正的通道，記下 `disconnect()` 的次數。
actor DisconnectCountingChannel: HostChannel {
    private let base: any HostChannel
    private(set) var disconnects = 0

    init(_ base: any HostChannel) {
        self.base = base
    }

    func execute(_ command: String) async throws -> any ExecSession { try await base.execute(command) }
    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
    func disconnect() async { disconnects += 1 }
}
#endif
