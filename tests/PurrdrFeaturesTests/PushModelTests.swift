#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 推播開關(行為規格 F14、ADR-0004):權限只在打開時請求、要有 Purrdr Plus、經 SSH 安裝外掛並建立推播配對，
/// 關閉時移除這支裝置的配對並撤銷，最後一支裝置關閉才移除外掛(#264)。
///
/// Seam:主機是 `LocalShellHost`(暫存家目錄、真的 `/bin/sh`,herdr 換成 `FakeHerdrPluginCLI`);
/// 後台是 `HTTPStub`(回應依 raychiutw/purrdr.server 的 README.md 契約手寫);通知權限與 APNs token 是 `FakePushPlatform`。
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
    let store = InMemoryPushPairingStore()
    /// 這支裝置的推播 id(主機路徑與後台共用，0.45 以前的 16 位 hex 沿用)。
    static let deviceID = PushDeviceID(rawValue: "0123456789abcdef")!

    init() throws {
        host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        platform.token = Self.token
    }

    func service(
        plusActive: Bool = true, store: (any PushPairingStore)? = nil, deviceID: PushDeviceID = Self.deviceID
    ) -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store ?? self.store,
            device: PushDeviceIdentity(id: deviceID, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(endpoint: Self.endpoint, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isPlusActive: { plusActive })
    }

    func model(_ service: PushService, hostID: String? = "studio", muted: Set<String> = []) -> PushModel {
        PushModel(
            service: service, hostID: hostID, installer: service.sshInstaller(channel: host, herdr: HerdrInstallation()),
            muted: { muted })
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

        service.forget(hostID: "studio", installer: service.sshInstaller(channel: channel, herdr: HerdrInstallation())) {
            await channel.disconnect()
        }

        for _ in 0..<200 where await channel.disconnects == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await channel.disconnects == 1, "刪配對另開的連線沒有關閉")
        #expect(!FakeHerdrPluginCLI.isPluginInstalled(on: host))
    }

    // MARK: - 推播外掛安裝介面(假實作)

    func model(_ service: PushService, installer: any PushPluginInstalling) -> PushModel {
        PushModel(service: service, hostID: "studio", installer: installer, muted: { [] })
    }

    @Test("確認對話框帶推播外掛安裝回報的主機使用者")
    func confirmationNamesInstallerUser() async {
        platform.status = .authorized
        let pluginHost = FakePushPluginHost(user: "ray")
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))

        await model.requestOn()

        #expect(model.state == .confirming(user: "ray"))
        #expect(!pluginHost.pluginInstalled)
    }

    @Test("查不到外掛狀態(herdr 沒在跑):說明，維持關閉")
    func statusFailureIsExplained() async {
        platform.status = .authorized
        let pluginHost = FakePushPluginHost()
        pluginHost.setStatusFailure(.pluginListFailed("herdr server is not running"))
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))

        await model.requestOn()

        #expect(model.state == .off)
        guard case .failed(let message)? = model.problem else { Issue.record("沒有說明"); return }
        #expect(message.contains("herdr server is not running"))
    }

    @Test("開啟與關閉經推播外掛安裝：配對寫到這支裝置，最後一支關閉時外掛移除")
    func turningOnAndOffGoesThroughInstaller() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let pluginHost = FakePushPluginHost()
        let service = service()
        let model = model(service, installer: pluginHost.installer(deviceID: Self.deviceID))

        await turnOn(model)

        #expect(model.state == .on)
        let file = try #require(pluginHost.pairing(deviceID: Self.deviceID))
        #expect(store.keyHash(forHost: "studio") == file.key.hash)
        backend.on("DELETE", "/v1/members/me/push-pairings/\(file.key.hash)", .empty(204))

        await model.turnOff()

        #expect(model.state == .off)
        #expect(pluginHost.pairing(deviceID: Self.deviceID) == nil)
        #expect(!pluginHost.pluginInstalled)
    }

    // MARK: - 多支裝置共用一台主機(#264)

    /// 另一支裝置(自己的裝置 id 與配對紀錄)在同一台假主機上的開關。
    func otherDeviceModel(_ pluginHost: FakePushPluginHost, deviceID: PushDeviceID) -> PushModel {
        PushModel(
            service: service(store: InMemoryPushPairingStore(), deviceID: deviceID), hostID: "studio",
            installer: pluginHost.installer(deviceID: deviceID), muted: { [] })
    }

    static let padID = PushDeviceID(rawValue: "fedcba9876543210")!

    @Test("兩支裝置同主機都開：關一支另一支仍開、外掛還在;最後一支關閉外掛才移除")
    func twoDevicesShareOneHost() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))
        platform.status = .authorized
        let pluginHost = FakePushPluginHost()
        let phone = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))
        let pad = otherDeviceModel(pluginHost, deviceID: Self.padID)

        await turnOn(phone)
        await turnOn(pad)
        #expect(pluginHost.calls.filter { $0.hasPrefix("install") }.count == 2)

        await phone.turnOff()

        #expect(phone.state == .off)
        #expect(pad.state == .on)
        #expect(pluginHost.pairing(deviceID: Self.deviceID) == nil)
        #expect(pluginHost.pairing(deviceID: Self.padID) != nil)
        #expect(pluginHost.pluginInstalled)

        await pad.turnOff()

        #expect(!pluginHost.pluginInstalled)
    }

    @Test("關閉只撤銷這支裝置的後台配對")
    func turningOffRevokesOnlyThisDevicesPairing() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))
        platform.status = .authorized
        let pluginHost = FakePushPluginHost()
        let phone = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))
        let pad = otherDeviceModel(pluginHost, deviceID: Self.padID)
        await turnOn(phone)
        await turnOn(pad)
        let phoneHash = try #require(pluginHost.pairing(deviceID: Self.deviceID)?.key.hash)
        let padHash = try #require(pluginHost.pairing(deviceID: Self.padID)?.key.hash)
        backend.on("DELETE", "/v1/members/me/push-pairings/\(phoneHash)", .empty(204))

        await phone.turnOff()

        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(phoneHash)").count == 1)
        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(padHash)").isEmpty)
    }

    @Test("另一支裝置已開：查狀態後顯示另有幾支裝置，確認時知道外掛已裝")
    func showsOtherDevicesOnHost() async throws {
        platform.status = .authorized
        let pluginHost = FakePushPluginHost()
        try await pluginHost.installer(deviceID: Self.padID).install(
            PushPairingFile(endpoint: Self.endpoint, key: .generate(), muted: []))
        let phone = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))
        #expect(phone.otherDevices == 0)

        await phone.refreshStatus()
        #expect(phone.otherDevices == 1)

        await phone.requestOn()
        #expect(phone.state == .confirming(user: pluginHost.user))
        #expect(phone.pluginAlreadyInstalled)
    }

    @Test("查狀態失敗：維持原本的狀態，不顯示錯誤")
    func refreshStatusFailureIsQuiet() async {
        let pluginHost = FakePushPluginHost()
        pluginHost.setStatusFailure(.pluginListFailed("herdr server is not running"))
        let phone = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))

        await phone.refreshStatus()

        #expect(phone.otherDevices == 0)
        #expect(phone.problem == nil)
        #expect(phone.state == .off)
    }

    @Test("每台主機各自一個推播狀態，不綁選取中主機")
    func eachHostHasItsOwnPushState() {
        let hostStore = MemoryHostStore()
        hostStore.hosts = [MultiHostTests.studio, MultiHostTests.lab]
        store.setKeyHash(String(repeating: "0", count: 64), forHost: MultiHostTests.lab.id.uuidString)
        let hosts = HostsModel(store: hostStore, demoChannel: FakeHost(), push: service(), makeChannel: ChannelsByAddress([:]).make)
        hosts.load()
        hosts.select(.host(MultiHostTests.studio.id))

        #expect(hosts.hostPushes.map(\.host) == [.host(MultiHostTests.lab.id), .host(MultiHostTests.studio.id)])
        #expect(hosts.hostPushes.map(\.name) == ["Lab", "Studio"])
        #expect(hosts.hostPushes.map(\.model.state) == [.on, .off])
        #expect(hosts.push.state == .off)
    }

    @Test("帳號頁通知區塊：SSH 主機與版本未知的 HTTPS 主機可開，Demo 主機與示範主機不能通知")
    func hostPushesExplainUnsupportedHosts() {
        let hostStore = MemoryHostStore()
        let https = HostConfiguration(name: "Box", hostService: HostServiceAddress("box.tail1234.ts.net")!)
        hostStore.hosts = [MultiHostTests.studio, https]
        let companion = DemoCompanionHost(id: UUID(), name: "Studio Mac", icon: .macMini, channel: FakeHost())
        // 已在這支裝置配對(沒有權杖的是「需要先配對」,見 HostServiceUpdateTests)。
        let hosts = HostsModel(
            store: hostStore, demoChannel: FakeHost(), demoCompanions: [companion],
            hostService: HostServiceAccess(tokens: InMemoryDeviceTokenStore(tokens: [https.id: "token-saved"])), push: service(),
            makeChannel: ChannelsByAddress([:]).make)
        hosts.load()
        hosts.select(.demo)

        let supportByName = Dictionary(uniqueKeysWithValues: hosts.hostPushes.map { ($0.name, $0.support) })
        #expect(supportByName["Studio"] == .supported)
        #expect(supportByName["Box"] == .supported)
        #expect(supportByName["Demo"] == .demoHost)
        #expect(supportByName["Studio Mac"] == .demoHost)
        #expect(hosts.hostPushes.first { $0.name == "Studio Mac" }?.icon == .macMini)
    }

    @Test("HTTPS 主機取不到主機服務連線(例如替身連線):明確標成不支援，不是無聲失效")
    func httpsHostWithoutHostServiceConnectionIsUnsupported() {
        let hostStore = MemoryHostStore()
        let box = HostConfiguration(name: "Box", hostService: HostServiceAddress("box.tail1234.ts.net")!)
        hostStore.hosts = [box]
        let tokens = InMemoryDeviceTokenStore(tokens: [box.id: "token-saved"])
        let hosts = HostsModel(
            store: hostStore, demoChannel: FakeHost(), hostService: HostServiceAccess(tokens: tokens) { _, _ in FakeHostConnection() },
            push: service(), makeChannel: ChannelsByAddress([:]).make)
        hosts.load()

        #expect(hosts.hostPushes.first { $0.name == "Box" }?.support == .unsupported)
    }

    @Test("至少一台主機開啟就算開啟通知，列出開著的主機名稱")
    func notifyingHostsListsHostsThatAreOn() {
        let hostStore = MemoryHostStore()
        hostStore.hosts = [MultiHostTests.studio, MultiHostTests.lab]
        let hosts = HostsModel(store: hostStore, demoChannel: FakeHost(), push: service(), makeChannel: ChannelsByAddress([:]).make)
        hosts.load()
        #expect(hosts.notifyingHostNames.isEmpty)

        store.setKeyHash(String(repeating: "0", count: 64), forHost: MultiHostTests.studio.id.uuidString)
        let reloaded = HostsModel(store: hostStore, demoChannel: FakeHost(), push: service(), makeChannel: ChannelsByAddress([:]).make)
        reloaded.load()

        #expect(reloaded.notifyingHostNames == ["Studio"])
    }

    @Test("安裝失敗後點開關重試：維持未開啟並說明，再開一次可以成功")
    func failedInstallCanBeRetried() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let pluginHost = FakePushPluginHost()
        pluginHost.setInstallFailure("git not found")
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))

        await turnOn(model)
        #expect(model.state == .off)
        guard case .failed(let message)? = model.problem else { Issue.record("沒有說明失敗"); return }
        #expect(message.contains("git not found"))

        pluginHost.setInstallFailure(nil)
        await turnOn(model)

        #expect(model.state == .on)
        #expect(model.problem == nil)
    }

    @Test("主機服務太舊：維持未開啟，說明要更新主機服務並附更新指令")
    func outdatedHostServiceAsksForUpdate() async {
        let pluginHost = FakePushPluginHost()
        pluginHost.setStatusFailure(.hostServiceOutdated(installed: "0.5.0"))
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .hostServiceOutdated(HostServiceUpdates.commands(installed: "0.5.0")))
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

    @Test("改靜音失敗：維持開啟，在這台主機列說明;下次成功就清掉")
    func mutingFailureIsShownOnHostRow() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let pluginHost = FakePushPluginHost()
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))
        await turnOn(model)
        pluginHost.setUpdateMutedFailure(HostServiceError.connectionLost)

        await model.syncMuted(["session-9"])

        #expect(model.state == .on)
        guard case .mutedSyncFailed? = model.problem else { Issue.record("沒有說明：\(String(describing: model.problem))"); return }

        pluginHost.setUpdateMutedFailure(nil)
        await model.syncMuted(["session-9"])
        #expect(model.problem == nil)
    }

    @Test("主機上的配對被手動移除：改靜音時回到未開啟並撤銷後台配對，不重裝外掛")
    func mutingAfterPairingRemovedTurnsOff() async throws {
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let pluginHost = FakePushPluginHost()
        let model = model(service(), installer: pluginHost.installer(deviceID: Self.deviceID))
        await turnOn(model)
        let hash = try #require(store.keyHash(forHost: "studio"))
        backend.on("DELETE", "/v1/members/me/push-pairings/\(hash)", .empty(204))
        pluginHost.removePairingManually(deviceID: Self.deviceID)

        await model.syncMuted(["session-9"])

        #expect(model.state == .off)
        #expect(store.keyHash(forHost: "studio") == nil)
        for _ in 0..<200 where backend.requests(to: "/v1/members/me/push-pairings/\(hash)").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(hash)").count == 1)
        #expect(pluginHost.calls.filter { $0.hasPrefix("install") }.count == 1)
    }

    /// 測試裡的 Keychain 是否已解鎖。
    @MainActor
    final class KeychainLock {
        var isUnlocked = false
    }

    @Test("Keychain 讀不到這支裝置的 id(還沒第一次解鎖):說明並維持關閉，解鎖後可再開")
    func unreadableDeviceIDIsExplained() async {
        platform.status = .authorized
        let pluginHost = FakePushPluginHost()
        let keychain = KeychainLock()
        let service = PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: platform, store: store,
            loadDevice: {
                guard keychain.isUnlocked else { throw PushDeviceIDError.unreadable(status: -25308) }
                return PushDeviceIdentity(id: Self.deviceID, name: "iPhone", model: .iPhone)
            },
            configuration: PushConfiguration(endpoint: Self.endpoint, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isPlusActive: { true })
        let model = model(service, installer: pluginHost.installer(deviceID: Self.deviceID))

        await model.requestOn()

        #expect(model.state == .off)
        #expect(model.problem == .deviceIDUnavailable)
        #expect(pluginHost.calls.isEmpty)

        keychain.isUnlocked = true
        await model.requestOn()
        #expect(model.state == .confirming(user: pluginHost.user))
    }

    // MARK: - 測試通知(#328)

    struct TestSender: PushTestNotificationSending {
        var failure: (any Error)?
        let sent: Recorder
        func sendTest(hostID: String) async throws {
            await sent.record(hostID)
            if let failure { throw failure }
        }
    }

    actor Recorder {
        private(set) var hostIDs: [String] = []
        func record(_ id: String) { hostIDs.append(id) }
    }

    @Test("測試通知：沒有送出管道時不提供")
    func testNotificationUnavailableWithoutSender() {
        let model = model(service())

        #expect(!model.canSendTestNotification)
    }

    @Test("測試通知：通知開著才能送，成功記下結果")
    func testNotificationSentWhenOn() async throws {
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let recorder = Recorder()
        let service = service()
        service.testNotifications = TestSender(sent: recorder)
        let model = model(service)
        #expect(!model.canSendTestNotification, "通知還沒開不能送")
        await turnOn(model)

        #expect(model.canSendTestNotification)
        await model.sendTestNotification()

        #expect(model.testNotification == .sent)
        #expect(await recorder.hostIDs == ["studio"])
    }

    @Test("測試通知:這台主機自己的送出管道(SSH)讓按鈕出現")
    func perHostSenderEnablesTestNotification() async throws {
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let recorder = Recorder()
        let model = model(service())
        model.testSender = TestSender(sent: recorder)
        await turnOn(model)

        #expect(model.canSendTestNotification)
        await model.sendTestNotification()

        #expect(model.testNotification == .sent)
        #expect(await recorder.hostIDs == ["studio"])
    }

    @Test("測試通知：失敗時說明原因")
    func testNotificationFailureIsExplained() async throws {
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let service = service()
        service.testNotifications = TestSender(failure: BackendError.unreachable, sent: Recorder())
        let model = model(service)
        await turnOn(model)

        await model.sendTestNotification()

        guard case .failed(let message) = model.testNotification else {
            Issue.record("預期失敗,實際 \(model.testNotification)")
            return
        }
        #expect(!message.isEmpty)
    }

    struct InternalDetail: Error, LocalizedError {
        var errorDescription: String? { "SQLITE_CONSTRAINT: foreign key mismatch at 0x7fff" }
    }

    @Test("測試通知：看不懂的錯誤不把系統原文丟給使用者")
    func testNotificationFailureHidesTechnicalDetail() async throws {
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let service = service()
        service.testNotifications = TestSender(failure: InternalDetail(), sent: Recorder())
        let model = model(service)
        await turnOn(model)

        await model.sendTestNotification()

        guard case .failed(let message) = model.testNotification else {
            Issue.record("預期失敗,實際 \(model.testNotification)")
            return
        }
        #expect(!message.contains("SQLITE"))
        #expect(!message.isEmpty)
    }

    static let studioHash = String(repeating: "1", count: 64)
    static let linuxHash = String(repeating: "2", count: 64)

    @Test("APNs token 換了：對每組配對向後台重新註冊(主機不用改)")
    func tokenRotationReRegisters() async throws {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setKeyHash(Self.linuxHash, forHost: "linux")
        store.setRegisteredToken("old", forKeyHash: Self.studioHash)
        store.setRegisteredToken("old", forKeyHash: Self.linuxHash)
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))

        await service().refreshRegistrations()

        let hashes = backend.requests(to: "/v1/members/me/push-pairings").compactMap { $0.json?["keyHash"] as? String }
        #expect(Set(hashes) == [Self.studioHash, Self.linuxHash])
        #expect(store.registeredTokens == [Self.studioHash: Self.tokenHex, Self.linuxHash: Self.tokenHex])
        #expect(platform.authorizationRequests == 0)
    }

    @Test("啟動時 token 沒變：不送後台，也不請求權限")
    func unchangedTokenDoesNothing() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken(Self.tokenHex, forKeyHash: Self.studioHash)
        platform.status = .authorized

        await service().refreshRegistrations()

        #expect(backend.requests(to: "/v1/members/me/push-pairings").isEmpty)
        #expect(platform.authorizationRequests == 0)
    }

    @Test("部分註冊失敗：成功的那組記為已註冊，失敗的下次再試")
    func partialRegistrationIsRecordedPerPairing() async throws {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setKeyHash(Self.linuxHash, forHost: "linux")
        platform.status = .authorized
        backend.on(
            "POST", "/v1/members/me/push-pairings",
            .json(201, #"{"registered":true}"#), .json(500, #"{"error":{"code":"internal","message":"x"}}"#))

        await service().refreshRegistrations()

        let firstHash = try #require(backend.requests(to: "/v1/members/me/push-pairings").first?.json?["keyHash"] as? String)
        #expect(store.registeredTokens == [firstHash: Self.tokenHex])
    }

    @Test("啟動：先判斷遠端關閉再補註冊，被撤銷的配對不因 token 換了而復活")
    func launchChecksRevocationBeforeReRegistering() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken("old", forKeyHash: Self.studioHash)
        platform.status = .authorized
        backend.on("GET", "/v1/members/me/push-devices", .json(200, #"{"devices": []}"#))
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let service = service()
        let push = model(service)

        await service.refreshAtLaunch()

        #expect(backend.requests(to: "/v1/members/me/push-pairings").isEmpty)
        #expect(store.pairings.isEmpty)
        #expect(push.state == .off)
    }

    @Test("啟動時讀不到清單：不判斷，也不補註冊(避免復活被撤銷的配對)")
    func launchWithoutListSkipsReRegistering() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken("old", forKeyHash: Self.studioHash)
        platform.status = .authorized
        backend.on("GET", "/v1/members/me/push-devices", .unreachable)
        let service = service()

        await service.refreshAtLaunch()

        #expect(backend.requests(to: "/v1/members/me/push-pairings").isEmpty)
        #expect(store.keyHash(forHost: "studio") == Self.studioHash)
    }

    @Test("部分配對還沒註冊時，已註冊的仍比對清單(被關閉就清掉),還沒註冊的留著再補")
    func partiallyRegisteredDeviceIsStillReconciled() async {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setKeyHash(Self.linuxHash, forHost: "linux")
        store.setRegisteredToken(Self.tokenHex, forKeyHash: Self.studioHash)
        backend.on("GET", "/v1/members/me/push-devices", .json(200, #"{"devices": []}"#))

        await service().reconcileRemoteRevocation()

        #expect(store.keyHash(forHost: "studio") == nil)
        #expect(store.keyHash(forHost: "linux") == Self.linuxHash)
    }

    @Test("沒有任何配對時啟動不取 token、不請求權限")
    func noPairingsAtLaunch() async {
        await service().refreshRegistrations()

        #expect(platform.tokenRequests == 0)
        #expect(platform.authorizationRequests == 0)
    }

    // MARK: - 推播種類(#292)

    /// 以 `FakePushPluginHost` 開啟一台主機的通知。
    func turnedOnWithPluginHost() async -> PushModel {
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))
        let model = model(service(), installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        await turnOn(model)
        return model
    }

    @Test("新開啟的主機收「需要你」與「完成」,註冊時帶 kinds")
    func turningOnRegistersDefaultKinds() async throws {
        let model = await turnedOnWithPluginHost()

        #expect(model.state == .on)
        #expect(model.kinds == [.blocked, .done])
        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first)
        #expect(request.json?["kinds"] as? [String] == ["blocked", "done"])
    }

    @Test("關掉「完成」:以同一組配對重送註冊，只帶 blocked;重開 app 仍記得")
    func changingKindsReRegisters() async throws {
        let model = await turnedOnWithPluginHost()
        let keyHash = try #require(store.keyHash(forHost: "studio"))

        await model.setKind(.done, isOn: false)

        #expect(model.kinds == [.blocked])
        #expect(model.problem == nil)
        let requests = backend.requests(to: "/v1/members/me/push-pairings")
        #expect(requests.count == 2)
        #expect(requests.last?.json?["keyHash"] as? String == keyHash)
        #expect(requests.last?.json?["kinds"] as? [String] == ["blocked"])
        let reopened = self.model(service(), installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        #expect(reopened.kinds == [.blocked])
    }

    @Test("改種類失敗：維持原本的種類並說明")
    func failedKindsChangeKeepsPrevious() async throws {
        platform.status = .authorized
        backend.on(
            "POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#),
            .json(500, #"{"error":{"code":"internal","message":"boom"}}"#))
        let model = model(service(), installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        await turnOn(model)

        await model.setKind(.done, isOn: false)

        #expect(model.kinds == [.blocked, .done])
        guard case .kindsUpdateFailed = model.problem else {
            Issue.record("沒有說明改種類失敗:\(String(describing: model.problem))")
            return
        }
        #expect(model.state == .on)
    }

    @Test("不能把最後一個種類也關掉(要不收通知就關閉那台主機)")
    func lastKindCannotBeTurnedOff() async throws {
        let model = await turnedOnWithPluginHost()
        await model.setKind(.done, isOn: false)

        await model.setKind(.blocked, isOn: false)

        #expect(model.kinds == [.blocked])
        #expect(backend.requests(to: "/v1/members/me/push-pairings").count == 2)
    }

    @Test("舊版 app 開的配對沒記種類：視為只收「需要你」,補註冊不帶 kinds(後台保留原偏好)")
    func legacyPairingKeepsBackendKinds() async throws {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken("old", forKeyHash: Self.studioHash)
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))

        let model = model(service(), installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        await service().refreshRegistrations()

        #expect(model.kinds == [.blocked])
        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first)
        #expect(request.json?["kinds"] == nil)
    }

    @Test("token 換了補註冊時帶這組配對記得的種類")
    func tokenRotationCarriesStoredKinds() async throws {
        store.setKeyHash(Self.studioHash, forHost: "studio")
        store.setRegisteredToken("old", forKeyHash: Self.studioHash)
        store.setKinds([.blocked, .done], forKeyHash: Self.studioHash)
        platform.status = .authorized
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))

        await service().refreshRegistrations()

        let request = try #require(backend.requests(to: "/v1/members/me/push-pairings").first)
        #expect(request.json?["kinds"] as? [String] == ["blocked", "done"])
    }

    @Test("新開啟的主機預設不收「可能卡住」「仍在等你」(#311)")
    func stuckAndReminderAreOffByDefault() async {
        let model = await turnedOnWithPluginHost()

        #expect(!model.kinds.contains(.stuck))
        #expect(!model.kinds.contains(.reminder))
    }

    @Test("打開「可能卡住」「仍在等你」:重送註冊的 kinds 帶 stuck、reminder(#311)")
    func turningOnStuckAndReminderReRegisters() async throws {
        let model = await turnedOnWithPluginHost()
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#), .json(201, #"{"registered":true}"#))

        await model.setKind(.stuck, isOn: true)
        await model.setKind(.reminder, isOn: true)

        #expect(model.kinds == [.blocked, .done, .stuck, .reminder])
        let requests = backend.requests(to: "/v1/members/me/push-pairings")
        #expect(requests.last?.json?["kinds"] as? [String] == ["blocked", "done", "stuck", "reminder"])
        let reopened = self.model(service(), installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        #expect(reopened.kinds == [.blocked, .done, .stuck, .reminder])
    }

    @Test("關閉通知時一併忘記那組配對的種類")
    func turningOffForgetsKinds() async throws {
        let model = await turnedOnWithPluginHost()
        let keyHash = try #require(store.keyHash(forHost: "studio"))
        backend.on("DELETE", "/v1/members/me/push-pairings/\(keyHash)", .empty(204))

        await model.turnOff()

        #expect(store.kinds(forKeyHash: keyHash) == nil)
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
        let pairings = InMemoryPushPairingStore()
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

    @Test("點「完成」通知：payload 根層的 pairing 與 pane 一樣導到那個聊天")
    func doneNotificationRoutesToChat() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "api", "loc-key": "An agent finished."], "category": "AGENT_DONE"],
            "pairing": "abc", "pane": "w2:p1", "status": "done",
        ]

        #expect(PushRoute(userInfo: userInfo) == PushRoute(keyHash: "abc", paneID: "w2:p1"))
    }

    // MARK: - 主機服務通知(#293)

    @Test("主機服務通知的 payload:根層 pairing 與 event,沒有 pane")
    func parsesHostServiceEvent() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title-loc-key": "Host service", "loc-key": "Host service updated to %@.", "loc-args": ["0.7.0"]],
                    "category": "HOST_SERVICE_EVENT"],
            "pairing": "abc", "event": "host_service_updated", "version": "0.7.0",
        ]

        #expect(PushRoute(userInfo: userInfo) == PushRoute(keyHash: "abc", paneID: nil, event: "host_service_updated"))
    }

    @Test("點主機服務通知：回傳要開那台主機的編輯頁，不開聊天",
          arguments: ["host_service_update_available", "host_service_updated", "host_service_update_rolled_back"])
    func hostServiceEventOpensHostEditor(event: String) {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash("abc", forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()
        model.select(.demo)

        let destination = model.open(PushRoute(keyHash: "abc", paneID: nil, event: event), pairings: pairings)

        #expect(destination == .hostEditor(HostsModelTests.studio.id))
        #expect(model.agentList.openedChat == nil)
        #expect(model.selection == .demo)
    }

    @Test("主機服務通知的配對已不認得(主機已移除):不開任何畫面")
    func hostServiceEventForUnknownPairingOpensNothing() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        let destination = model.open(
            PushRoute(keyHash: "nope", paneID: nil, event: "host_service_updated"), pairings: InMemoryPushPairingStore())

        #expect(destination == nil)
    }

    @Test("測試通知的 payload:根層 pairing 與 event=test,沒有 pane")
    func parsesTestNotification() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title-loc-key": "Purrdr", "loc-key": "This is a test notification from Purrdr."]],
            "pairing": "abc", "event": "test",
        ]

        #expect(PushRoute(userInfo: userInfo) == PushRoute(keyHash: "abc", paneID: nil, event: "test"))
    }

    @Test("點測試通知:只開 app,不開主機編輯頁也不開聊天")
    func testNotificationOpensNothing() {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash("abc", forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()
        model.select(.demo)

        let destination = model.open(PushRoute(keyHash: "abc", paneID: nil, event: "test"), pairings: pairings)

        #expect(destination == nil)
        #expect(model.agentList.openedChat == nil)
        #expect(model.selection == .demo)
    }

    @Test("測試通知失敗:各種原因有各自的說明,需要 Plus 時說明要 Plus")
    func testNotificationFailuresAreExplainedSeparately() {
        let errors: [PushTestNotificationError] = [
            .notPaired, .subscriptionRequired, .rateLimited, .apnsFailed, .curlMissing,
            .backendUnreachable("curl: (7)"), .backendRejected(statusCode: 500), .failed("x"),
        ]
        let messages = errors.map { PushModel.describeTestFailure($0) }

        #expect(messages.allSatisfy { !$0.isEmpty && !$0.contains("curl: (7)") })
        #expect(Set(messages.prefix(5)).count == 5, "前五種各有專屬說明")
        #expect(messages[1].contains("Plus"))
    }

    @Test("Agent 通知仍回傳開了哪個聊天")
    func agentNotificationReportsChat() {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash("abc", forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()

        let destination = model.open(PushRoute(keyHash: "abc", paneID: "w2:p1"), pairings: pairings)

        #expect(destination == .chat(ChatRoute(host: .host(HostsModelTests.studio.id), paneID: "w2:p1")))
    }

    @Test("「主機服務」種類只給 HTTPS 主機選(SSH 主機沒有主機服務)")
    func hostServiceKindOnlyForHTTPSHosts() {
        #expect(PushKind.choices(installsViaHostService: false) == [.blocked, .done])
        #expect(PushKind.choices(installsViaHostService: true).contains(.hostService))
    }

    @Test("「可能卡住」「仍在等你」由主機服務的 Agent 觀察者偵測：只給 HTTPS 主機選(#311)")
    func stuckAndReminderOnlyForHTTPSHosts() {
        #expect(PushKind.choices(installsViaHostService: false) == [.blocked, .done])
        #expect(PushKind.choices(installsViaHostService: true) == [.blocked, .done, .stuck, .reminder, .hostService])
    }

    @Test("「可能卡住」「仍在等你」要主機服務 0.7.0;版本未知時不擋(#311)")
    func stuckAndReminderNeedHostService070() {
        #expect(PushKind.stuck.needsHostServiceUpdate(installedVersion: "0.6.0"))
        #expect(PushKind.reminder.needsHostServiceUpdate(installedVersion: "0.6.2"))
        #expect(!PushKind.stuck.needsHostServiceUpdate(installedVersion: "0.7.0"))
        #expect(!PushKind.reminder.needsHostServiceUpdate(installedVersion: nil))
        #expect(!PushKind.blocked.needsHostServiceUpdate(installedVersion: "0.6.0"))
        #expect(!PushKind.hostService.needsHostServiceUpdate(installedVersion: "0.6.0"))
    }

    @Test("點「可能卡住」「仍在等你」通知：依根層 pairing 與 pane 開那個聊天(#311)",
          arguments: [("stuck", "AGENT_STUCK", "An agent may be stuck."),
                      ("reminder", "AGENT_REMINDER", "An agent is still waiting for you.")])
    func stuckAndReminderNotificationsOpenChat(status: String, category: String, body: String) {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "api", "loc-key": body], "category": category],
            "pairing": "abc", "pane": "w2:p1", "status": status,
        ]
        let route = PushRoute(userInfo: userInfo)
        #expect(route == PushRoute(keyHash: "abc", paneID: "w2:p1"))

        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash("abc", forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()

        let destination = route.flatMap { model.open($0, pairings: pairings) }

        #expect(destination == .chat(ChatRoute(host: .host(HostsModelTests.studio.id), paneID: "w2:p1")))
    }

    @Test("不認得的配對(主機已移除)不切換")
    func unknownPairingIsIgnored() {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        model.open(PushRoute(keyHash: "nope", paneID: "w2:p1"), pairings: InMemoryPushPairingStore())

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
