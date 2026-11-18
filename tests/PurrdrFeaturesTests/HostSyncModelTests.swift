import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機同步(#30、ADR-0007)的 model(Seam 2:後台用 `HTTPStub`,回應依 `backend/README.md` 的契約手寫)。
@MainActor
@Suite("主機同步")
struct HostSyncModelTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let hostStore = MemoryHostStore()
    let secrets = EphemeralHostSecretStore()
    let syncStore = InMemoryHostSyncStore()
    static let path = "/v1/members/me/hosts/sync"
    static let now = Date(timeIntervalSince1970: 1_794_729_600)  // 2026-11-15T08:00:00Z

    static let studio = HostConfiguration(
        id: UUID(uuidString: "6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "ray"), openSSH: .password,
        herdr: HerdrInstallation(path: "/opt/herdr/bin/herdr", session: "secret-project"), operatingSystem: .macOS,
        hostKeyPin: HostKeyFingerprint(stored: "nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"))

    /// 後台回應的一台主機(`hosts` 的一筆)。
    static func remoteStudio(name: String = "Studio Mac", modifiedAt: String = "2026-11-15T08:00:00.000Z") -> String {
        #"""
        {"id": "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70", "name": "\#(name)", "address": "studio-mac", "port": 22, "username": "ray",
         "connectionMethod": "openssh", "hostKeyFingerprint": "nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8", "modifiedAt": "\#(modifiedAt)"}
        """#
    }

    static func snapshot(hosts: [String] = [], deleted: [String] = []) -> String {
        #"{"hosts": [\#(hosts.joined(separator: ","))], "deletedHostIds": [\#(deleted.map { "\"\($0)\"" }.joined(separator: ","))]}"#
    }

    func makeModels(
        hosts: [HostConfiguration] = [studio], channels: Int = 4, deviceTokens: any DeviceTokenStore = InMemoryDeviceTokenStore(),
        now: @escaping @MainActor () -> Date = { Self.now }
    ) -> (HostSyncModel, HostsModel) {
        hostStore.hosts = hosts
        let factory = ChannelFactory()
        factory.hosts = (0..<channels).map { _ in FakeHost() }
        let hostsModel = HostsModel(
            store: hostStore, demoChannel: FakeHost(), credentials: HostCredentials(secrets: secrets, deviceKey: EphemeralDeviceKey()),
            hostService: HostServiceAccess(tokens: deviceTokens), makeChannel: factory.make)
        hostsModel.load()
        let session = MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        let plus = SubscriptionModel(session: session, store: FakePlusStore())
        let sync = HostSyncModel(session: session, plus: plus, hosts: hostsModel, store: syncStore, now: now)
        return (sync, hostsModel)
    }

    /// 已登入、有 Purrdr Plus 的會員。
    func subscribe(status: String = "active") throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.with(status: status)))
    }

    func sentChanges(_ index: Int = 0) -> [[String: Any]] {
        backend.requests(to: Self.path)[index].json?["changes"] as? [[String: Any]] ?? []
    }

    // MARK: - 需要 Purrdr Plus

    @Test("沒有 Purrdr Plus:不開啟、不送同步請求，提示訂閱")
    func enableWithoutPlusIsRefused() async throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        backend.on("GET", "/v1/members/me/subscription", .json(200, #"{"subscription": null}"#))
        let (sync, _) = makeModels()

        await sync.setEnabled(true)

        #expect(sync.isEnabled == false)
        #expect(sync.status == .needsPlus)
        #expect(backend.requests(to: Self.path).isEmpty)
        #expect(syncStore.isEnabled == false)
    }

    @Test("沒登入：不開啟、不送同步請求，提示訂閱(付費牆會請他登入)")
    func enableSignedOutIsRefused() async {
        let (sync, _) = makeModels()

        await sync.setEnabled(true)

        #expect(sync.isEnabled == false)
        #expect(sync.status == .needsPlus)
        #expect(backend.requests(to: Self.path).isEmpty)
    }

    @Test("開啟後訂閱到期：停止同步(不送請求),提示續訂;本機主機不動")
    func expiredSubscriptionStopsSync() async throws {
        try subscribe(status: "expired")
        syncStore.isEnabled = true
        let (sync, hosts) = makeModels()

        await sync.sync()

        #expect(sync.status == .needsPlus)
        #expect(backend.requests(to: Self.path).isEmpty)
        #expect(hosts.hosts == [Self.studio])
    }

    @Test("後台拒絕(403 subscription_required):提示續訂，本機主機不動")
    func backendRefusalShowsNeedsPlus() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(403, #"{"error": {"code": "subscription_required", "message": "Purrdr Plus required."}}"#))
        syncStore.isEnabled = true
        let (sync, hosts) = makeModels()

        await sync.sync()

        #expect(sync.status == .needsPlus)
        #expect(hosts.hosts == [Self.studio])
    }

    // MARK: - 上傳

    @Test("開啟同步：上傳這支裝置的主機，同步完成")
    func enableUploadsHosts() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])))
        let (sync, hosts) = makeModels()

        await sync.setEnabled(true)

        #expect(sync.isEnabled)
        #expect(syncStore.isEnabled)
        #expect(sync.status == .upToDate(Self.now))
        let changes = sentChanges()
        #expect(changes.count == 1)
        #expect(changes.first?["id"] as? String == Self.studio.id.uuidString)
        #expect(changes.first?["name"] as? String == "Studio Mac")
        #expect(changes.first?["address"] as? String == "studio-mac")
        #expect(changes.first?["port"] as? Int == 22)
        #expect(changes.first?["username"] as? String == "ray")
        #expect(changes.first?["connectionMethod"] as? String == "openssh")
        #expect(changes.first?["hostKeyFingerprint"] as? String == "nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8")
        #expect(changes.first?["modifiedAt"] as? String == "2026-11-15T08:00:00.000Z")
        #expect(hosts.hosts == [Self.studio], "後台回的就是同一份，本機不變")
    }

    @Test("隱私：上傳內容只有白名單欄位;密碼、私鑰、passphrase、登入方式、herdr 設定都不上傳")
    func uploadContainsNoSecrets() async throws {
        try subscribe()
        let linux = HostConfiguration(
            name: "Linux box", endpoint: SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops"),
            openSSH: .importedKey, herdr: HerdrInstallation(session: "ops-session"))
        try secrets.setSecret(.password("hunter2-password"), for: Self.studio.id)
        try secrets.setSecret(.privateKey("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE\n-----END OPENSSH PRIVATE KEY-----", passphrase: "pass-phrase-9"), for: linux.id)
        backend.on("POST", Self.path, .json(200, Self.snapshot()))
        let (sync, _) = makeModels(hosts: [Self.studio, linux])

        await sync.setEnabled(true)

        let request = try #require(backend.requests(to: Self.path).first)
        #expect(Set(request.json?.keys.map { $0 } ?? []) == ["changes", "connectionMethods"])
        let changes = sentChanges()
        #expect(changes.count == 2)
        for change in changes {
            #expect(Set(change.keys) == ["id", "name", "address", "port", "username", "connectionMethod", "hostKeyFingerprint", "modifiedAt"])
        }
        let body = String(decoding: request.body, as: UTF8.self)
        for secret in ["hunter2-password", "OPENSSH PRIVATE KEY", "b3BlbnNzaC1rZXktdjE", "pass-phrase-9", "secret-project", "ops-session", "/opt/herdr"] {
            #expect(!body.contains(secret), "不可上傳 \(secret)")
        }
    }

    // MARK: - HTTPS 主機(#63)

    static let httpsStudio = HostConfiguration(
        id: UUID(uuidString: "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("studio.tail1234.ts.net")!)

    static func remoteHTTPSStudio() -> String {
        #"""
        {"id": "1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f", "name": "Studio HTTPS", "address": "studio.tail1234.ts.net", "port": 443,
         "username": "", "connectionMethod": "https", "hostKeyFingerprint": null,
         "hostServiceAddress": "https://studio.tail1234.ts.net", "modifiedAt": "2026-11-15T08:00:00.000Z"}
        """#
    }

    @Test("HTTPS 主機上傳名稱、連線方式與主機服務位址;裝置權杖永不上傳。請求說明這支 app 看得懂 HTTPS")
    func uploadsHTTPSHostWithoutDeviceToken() async throws {
        try subscribe()
        let deviceTokens = InMemoryDeviceTokenStore(tokens: [Self.httpsStudio.id: "purrdr-device-token-secret"])
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteHTTPSStudio()])))
        let (sync, hosts) = makeModels(hosts: [Self.httpsStudio], deviceTokens: deviceTokens)

        await sync.setEnabled(true)

        let request = try #require(backend.requests(to: Self.path).first)
        #expect(request.json?["connectionMethods"] as? [String] == ["tailscale_ssh", "openssh", "https"])
        let change = try #require(sentChanges().first)
        #expect(Set(change.keys) == [
            "id", "name", "address", "port", "username", "connectionMethod", "hostKeyFingerprint", "hostServiceAddress", "modifiedAt",
        ])
        #expect(change["connectionMethod"] as? String == "https")
        #expect(change["hostServiceAddress"] as? String == "https://studio.tail1234.ts.net")
        #expect(change["address"] as? String == "studio.tail1234.ts.net")
        #expect(change["port"] as? Int == 443)
        #expect(change["username"] as? String == "")
        #expect(change["hostKeyFingerprint"] is NSNull)
        #expect(!String(decoding: request.body, as: UTF8.self).contains("purrdr-device-token-secret"), "裝置權杖不可上傳")
        #expect(hosts.hosts == [Self.httpsStudio])
        #expect(try deviceTokens.deviceToken(for: Self.httpsStudio.id) == "purrdr-device-token-secret")
    }

    @Test("SSH 主機的上傳內容不多出主機服務位址")
    func sshUploadHasNoHostServiceAddress() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])))
        let (sync, _) = makeModels()

        await sync.setEnabled(true)

        #expect(sentChanges().first?["hostServiceAddress"] == nil)
    }

    @Test("別台裝置新增的 HTTPS 主機：出現在這支裝置但沒有權杖，主機清單標示要配對")
    func remoteHTTPSHostNeedsPairing() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteHTTPSStudio()])))
        let deviceTokens = InMemoryDeviceTokenStore()
        let (sync, hosts) = makeModels(hosts: [], deviceTokens: deviceTokens)

        await sync.setEnabled(true)

        #expect(hosts.hosts == [Self.httpsStudio])
        #expect(try deviceTokens.deviceToken(for: Self.httpsStudio.id) == nil)
        #expect(hosts.rows.first?.needsPairing == true)
    }

    // MARK: - 衝突與刪除

    @Test("衝突：別台裝置較新的修改勝出(後台判定),本機改成後台的版本，登入方式與祕密留著")
    func newerRemoteChangeIsApplied() async throws {
        try subscribe()
        try secrets.setSecret(.password("hunter2"), for: Self.studio.id)
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio(name: "Renamed on iPad", modifiedAt: "2026-11-16T08:00:00.000Z")])))
        let (sync, hosts) = makeModels()

        await sync.setEnabled(true)

        var expected = Self.studio
        expected.name = "Renamed on iPad"
        #expect(hosts.hosts == [expected])
        #expect(hostStore.hosts == [expected])
        #expect(try secrets.secret(for: Self.studio.id) == .password("hunter2"))
    }

    @Test("別台裝置新增的主機出現在這支裝置")
    func remoteHostIsAdded() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])))
        let (sync, hosts) = makeModels(hosts: [])

        await sync.setEnabled(true)

        #expect(hosts.hosts.map(\.id) == [Self.studio.id])
        #expect(hosts.hosts.first?.ssh?.endpoint == Self.studio.ssh?.endpoint)
        #expect(hosts.hosts.first?.ssh?.hostKeyPin == Self.studio.ssh?.hostKeyPin)
        #expect(hosts.hosts.first?.authentication == .deviceKey, "祕密不同步：OpenSSH 先用這支裝置的金鑰")
    }

    @Test("別台裝置刪除的主機：這支裝置也刪(含祕密),下次同步不會傳回去")
    func remoteDeletionIsNotSyncedBack() async throws {
        try subscribe()
        try secrets.setSecret(.password("hunter2"), for: Self.studio.id)
        backend.on(
            "POST", Self.path, .json(200, Self.snapshot(deleted: [Self.studio.id.uuidString.lowercased()])),
            .json(200, Self.snapshot(deleted: [Self.studio.id.uuidString.lowercased()])))
        let (sync, hosts) = makeModels()

        await sync.setEnabled(true)
        #expect(hosts.hosts.isEmpty)
        #expect(hostStore.hosts.isEmpty)
        #expect(try secrets.secret(for: Self.studio.id) == nil)

        await sync.sync()
        #expect(sentChanges(1).isEmpty, "已刪除的主機不再上傳")
    }

    @Test("這支裝置刪除主機：上傳刪除")
    func localDeletionIsUploaded() async throws {
        try subscribe()
        backend.on(
            "POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])),
            .json(200, Self.snapshot(deleted: [Self.studio.id.uuidString.lowercased()])))
        let (sync, hosts) = makeModels()
        await sync.setEnabled(true)

        try await hosts.delete(Self.studio.id)
        try await waitUntil { await MainActor.run { backend.requests(to: Self.path).count == 2 } }
        try await waitUntil { await MainActor.run { sync.status == .upToDate(Self.now) } }

        let changes = sentChanges(1)
        #expect(changes.count == 1)
        #expect(changes.first?["id"] as? String == Self.studio.id.uuidString)
        #expect(changes.first?["deleted"] as? Bool == true)
        #expect(Set(changes.first?.keys.map { $0 } ?? []) == ["id", "deleted"])
    }

    @Test("開啟同步時重新命名主機：自動上傳新的名稱與修改時間")
    func renameIsUploaded() async throws {
        try subscribe()
        backend.on(
            "POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])),
            .json(200, Self.snapshot(hosts: [Self.remoteStudio(name: "Studio", modifiedAt: "2026-11-15T08:01:00.000Z")])))
        var clock = Self.now
        let (sync, hosts) = makeModels(now: { clock })
        await sync.setEnabled(true)

        clock = Self.now.addingTimeInterval(60)
        try hosts.rename(Self.studio.id, to: "Studio")
        try await waitUntil { await MainActor.run { backend.requests(to: Self.path).count == 2 } }
        try await waitUntil { await MainActor.run { sync.status == .upToDate(Self.now.addingTimeInterval(60)) } }

        #expect(sentChanges(1).first?["name"] as? String == "Studio")
        #expect(sentChanges(1).first?["modifiedAt"] as? String == "2026-11-15T08:01:00.000Z")
        #expect(hosts.hosts.first?.name == "Studio")
    }

    @Test("沒開啟同步：改主機不送任何請求")
    func disabledSendsNothing() async throws {
        try subscribe()
        let (_, hosts) = makeModels()

        try hosts.rename(Self.studio.id, to: "Studio")
        try await Task.sleep(for: .milliseconds(100))

        #expect(backend.requests.isEmpty)
    }

    @Test("關閉同步：不再送請求，狀態回到關閉")
    func disable() async throws {
        try subscribe()
        backend.on("POST", Self.path, .json(200, Self.snapshot(hosts: [Self.remoteStudio()])))
        let (sync, _) = makeModels()
        await sync.setEnabled(true)

        await sync.setEnabled(false)
        await sync.sync()

        #expect(sync.isEnabled == false)
        #expect(syncStore.isEnabled == false)
        #expect(sync.status == .off)
        #expect(backend.requests(to: Self.path).count == 1)
    }

    @Test("連不上後台：說明失敗，本機主機不動，下次再試")
    func unreachable() async throws {
        try subscribe()
        backend.on("POST", Self.path, .unreachable)
        syncStore.isEnabled = true
        let (sync, hosts) = makeModels()

        await sync.sync()

        guard case .failed = sync.status else {
            Issue.record("應該是失敗：\(sync.status)")
            return
        }
        #expect(hosts.hosts == [Self.studio])
    }
}
