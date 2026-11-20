#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 帳號頁「通知裝置」(#266):列出會員所有收通知的裝置、遠端關閉、改名;這支裝置被遠端關閉時「通知」區塊回到關閉。
///
/// Seam:後台是 `HTTPStub`(回應依 raychiutw/purrdr.server 的 README.md「通知裝置」手寫);主機是 `FakePushPluginHost`;
/// 通知權限與 token 是 `PushModelTests` 的 `FakePushPlatform`(只在 macOS)。
@MainActor
@Suite("通知裝置")
struct PushDevicesModelTests {
    static let thisDevice = "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70"
    static let ipad = "1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    static let token = Data([0xA1, 0xB2, 0xC3, 0xD4] + Array(repeating: 0x5E, count: 28))
    static let tokenHex = "a1b2c3d4" + String(repeating: "5e", count: 28)
    static let identity = PushDeviceIdentity(id: PushDeviceID(rawValue: thisDevice)!, name: "iPhone", model: .iPhone)
    static let studioHash = String(repeating: "1", count: 64)

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let platform = FakePushPlatform()
    let store = InMemoryPushPairingStore()
    let host = FakePushPluginHost()

    init() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        platform.token = Self.token
        platform.status = .authorized
    }

    func service() -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store, device: Self.identity,
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isPlusActive: { true })
    }

    func hostPush(_ service: PushService) -> PushModel {
        PushModel(service: service, hostID: "studio", installer: host.installer(deviceID: Self.identity.id), muted: { [] })
    }

    /// 這支裝置已在 studio 開啟通知，且配對已帶裝置 id 註冊過。
    func pairedStudio() {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken(Self.tokenHex, forKeyHash: Self.studioHash)
    }

    static func device(_ id: String, name: String?, model: String?, hosts: Int, current: Bool) -> String {
        let name = name.map { "\"\($0)\"" } ?? "null"
        let model = model.map { "\"\($0)\"" } ?? "null"
        return #"{"deviceId": "\#(id)", "name": \#(name), "model": \#(model), "hostCount": \#(hosts), "lastRegisteredAt": 1794729600000, "current": \#(current)}"#
    }

    static func list(_ devices: String...) -> HTTPStub.Reply {
        .json(200, #"{"devices": [\#(devices.joined(separator: ","))]}"#)
    }

    static let currentPhone = device(thisDevice, name: "Ray’s iPhone", model: "iPhone", hosts: 1, current: true)
    static let studioIPad = device(ipad, name: "Studio iPad", model: "iPad", hosts: 2, current: false)

    // MARK: - 清單

    @Test("清單：帶這支裝置的 id,列出所有裝置並標出這支")
    func listsDevices() async throws {
        let legacy = Self.device("legacy-0123456789abcdef0123456789abcdef", name: nil, model: nil, hosts: 1, current: false)
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.currentPhone, Self.studioIPad, legacy))
        let devices = PushDevicesModel(service: service())

        await devices.load()

        #expect(backend.requests(to: "/v1/members/me/push-devices").first?.query["currentDeviceId"] == Self.thisDevice)
        #expect(devices.devices.map(\.id) == [Self.thisDevice, Self.ipad, "legacy-0123456789abcdef0123456789abcdef"])
        #expect(devices.devices.map(\.isCurrent) == [true, false, false])
        #expect(devices.devices.last?.name == nil)
        #expect(devices.problem == nil)
    }

    // MARK: - 關閉

    @Test("關閉別支裝置：送 DELETE、從清單拿掉，這支裝置的通知不動")
    func turningOffAnotherDevice() async throws {
        pairedStudio()
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.currentPhone, Self.studioIPad))
        backend.on("DELETE", "/v1/members/me/push-devices/\(Self.ipad)", .empty(204))
        let service = service()
        let push = hostPush(service)
        let devices = PushDevicesModel(service: service)
        await devices.load()

        await devices.turnOff(try #require(devices.devices.last))

        #expect(backend.requests(to: "/v1/members/me/push-devices/\(Self.ipad)").map(\.method) == ["DELETE"])
        #expect(devices.devices.map(\.id) == [Self.thisDevice])
        #expect(push.state == .on)
        #expect(store.keyHash(forHost: "studio") == Self.studioHash)
    }

    @Test("關閉這支裝置：後台撤銷後「通知」區塊的主機回到關閉")
    func turningOffThisDevice() async throws {
        pairedStudio()
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.currentPhone))
        backend.on("DELETE", "/v1/members/me/push-devices/\(Self.thisDevice)", .empty(204))
        let service = service()
        let push = hostPush(service)
        let devices = PushDevicesModel(service: service)
        await devices.load()

        await devices.turnOff(try #require(devices.devices.first))

        #expect(devices.devices.isEmpty)
        #expect(push.state == .off)
        #expect(store.pairings.isEmpty)
    }

    @Test("關閉時後台說裝置已沒有配對(404):當作已關閉，從清單拿掉")
    func turningOffMissingDevice() async throws {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        backend.on("DELETE", "/v1/members/me/push-devices/\(Self.ipad)", .json(404, #"{"error": {"code": "device_not_found", "message": "x"}}"#))
        let devices = PushDevicesModel(service: service())
        await devices.load()

        await devices.turnOff(try #require(devices.devices.first))

        #expect(devices.devices.isEmpty)
        #expect(devices.problem == nil)
    }

    // MARK: - 改名

    @Test("改名：去頭尾空白後送 PATCH,清單換成後台回的名稱")
    func renamesDevice() async throws {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.currentPhone, Self.studioIPad))
        backend.on("PATCH", "/v1/members/me/push-devices/\(Self.ipad)", .json(200, #"{"device": \#(Self.device(Self.ipad, name: "Desk iPad", model: "iPad", hosts: 2, current: false))}"#))
        let devices = PushDevicesModel(service: service())
        await devices.load()

        let renamed = await devices.rename(try #require(devices.devices.last), to: "  Desk iPad ")

        #expect(renamed)
        let request = try #require(backend.requests(to: "/v1/members/me/push-devices/\(Self.ipad)").first)
        #expect(request.method == "PATCH")
        #expect(request.json?["name"] as? String == "Desk iPad")
        #expect(request.query["currentDeviceId"] == Self.thisDevice)
        #expect(devices.devices.last?.name == "Desk iPad")
    }

    @Test("名稱空白或超過 64 字：不送出", arguments: ["   ", String(repeating: "a", count: 65)])
    func rejectsInvalidName(_ name: String) async throws {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        let devices = PushDevicesModel(service: service())
        await devices.load()

        let renamed = await devices.rename(try #require(devices.devices.first), to: name)

        #expect(!renamed)
        #expect(backend.requests.allSatisfy { $0.method != "PATCH" })
    }

    // MARK: - 錯誤

    @Test("訂閱到期：清單與關閉照常(遺失的裝置仍關得掉),改名提示要 Purrdr Plus")
    func expiredSubscriptionCanStillTurnOff() async throws {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        backend.on("PATCH", "/v1/members/me/push-devices/\(Self.ipad)", .json(403, #"{"error": {"code": "subscription_required", "message": "x"}}"#))
        backend.on("DELETE", "/v1/members/me/push-devices/\(Self.ipad)", .empty(204))
        let devices = PushDevicesModel(service: service())
        await devices.load()
        let ipad = try #require(devices.devices.first)

        #expect(await devices.rename(ipad, to: "Desk iPad") == false)
        #expect(devices.problem == .needsSubscription)
        #expect(devices.devices.map(\.id) == [Self.ipad])

        await devices.turnOff(ipad)

        #expect(devices.devices.isEmpty)
        #expect(devices.problem == nil)
    }

    @Test("連不上後台：說明，保留上次的清單")
    func unreachableKeepsList() async {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad), .unreachable)
        let devices = PushDevicesModel(service: service())
        await devices.load()

        await devices.load()

        #expect(devices.devices.map(\.id) == [Self.ipad])
        #expect(devices.problem == .failed(String(localized: "Couldn’t reach Purrdr’s server. Check your connection and try again.")))
    }

    @Test("改名失敗：說明，名稱不變")
    func renameFailure() async throws {
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        backend.on("PATCH", "/v1/members/me/push-devices/\(Self.ipad)", .unreachable)
        let devices = PushDevicesModel(service: service())
        await devices.load()

        let renamed = await devices.rename(try #require(devices.devices.first), to: "Desk iPad")

        #expect(!renamed)
        #expect(devices.devices.first?.name == "Studio iPad")
        #expect(devices.problem != nil)
    }

    // MARK: - 被遠端關閉

    @Test("啟動時發現這支裝置已被別支關閉：配對清掉，「通知」區塊的主機回到關閉")
    func remotelyRevokedAtLaunch() async {
        pairedStudio()
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        let service = service()
        let push = hostPush(service)

        await service.refreshAtLaunch()

        #expect(push.state == .off)
        #expect(store.pairings.isEmpty)
    }

    @Test("讀不到清單時不當成被關閉")
    func unreachableListKeepsPairings() async {
        pairedStudio()
        backend.on("GET", "/v1/members/me/push-devices", .unreachable)
        let service = service()
        let push = hostPush(service)

        await service.reconcileRemoteRevocation()

        #expect(push.state == .on)
        #expect(store.keyHash(forHost: "studio") == Self.studioHash)
    }

    @Test("舊版 app 註冊的配對(沒帶裝置 id):啟動時帶裝置欄位重新註冊，之後才比對清單")
    func legacyPairingsAreReRegisteredWithDevice() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let service = service()

        await service.refreshRegistrations()

        let request = backend.requests(to: "/v1/members/me/push-pairings").first
        #expect(request?.json?["deviceId"] as? String == Self.thisDevice)
        #expect(request?.json?["deviceName"] as? String == "iPhone")
        #expect(request?.json?["model"] as? String == "iPhone")
        #expect(store.registeredTokens == [Self.studioHash: Self.tokenHex])
    }

    @Test("舊配對還沒帶裝置 id 重新註冊成功前，不以清單判斷是否被關閉")
    func unregisteredDeviceIsNotReconciled() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        backend.on("GET", "/v1/members/me/push-devices", Self.list(Self.studioIPad))
        let service = service()

        await service.reconcileRemoteRevocation()

        #expect(store.keyHash(forHost: "studio") == Self.studioHash)
        #expect(backend.requests(to: "/v1/members/me/push-devices").isEmpty)
    }
}
#endif
