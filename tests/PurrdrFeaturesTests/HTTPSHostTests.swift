import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Security
import Testing

/// 假的配對與撤銷 HTTPS 請求：配對碼 `K7QM-2XPA` 換得 `token-paired`,`OLD0-CODE` 過期;記錄每個請求。
final class FakeHostServiceHTTP: HostServiceHTTPSending, @unchecked Sendable {
    struct Request: Equatable {
        var url: URL
        var bearerToken: String?
        var body: [String: String]?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse {
        let fields = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        lock.withLock { recorded.append(Request(url: url, bearerToken: bearerToken, body: fields)) }
        if url.path() == "/v1/revoke" { return HostServiceHTTPResponse(status: 204, body: Data()) }
        switch fields?["pairing_code"] {
        case "K7QM-2XPA":
            return HostServiceHTTPResponse(
                status: 200, body: Data(#"{"device_id":"d1","device_token":"token-paired","read_only":false}"#.utf8))
        case "OLD0-CODE":
            return HostServiceHTTPResponse(
                status: 401, body: Data(#"{"type":"error","code":"pairing_code_expired","message":"pairing code expired"}"#.utf8))
        default:
            return HostServiceHTTPResponse(
                status: 401, body: Data(#"{"type":"error","code":"pairing_code_invalid","message":"unknown"}"#.utf8))
        }
    }
}

/// 記錄建立了哪些 HTTPS 主機連線(位址與當時讀到的權杖),給出回放 snapshot 的假主機連線。
@MainActor
final class HostServiceConnections {
    private(set) var addresses: [HostServiceAddress] = []
    private(set) var tokens: [String?] = []
    var connections: [FakeHostConnection] = []

    func access(tokens store: any DeviceTokenStore = InMemoryDeviceTokenStore(), http: FakeHostServiceHTTP = FakeHostServiceHTTP())
        -> HostServiceAccess {
        HostServiceAccess(tokens: store, pairing: HostServicePairing(http: http), deviceName: "Ray 的 iPhone") { address, token in
            self.addresses.append(address)
            self.tokens.append(try? token())
            return self.connections.isEmpty ? FakeHostConnection() : self.connections.removeFirst()
        }
    }

    static func healthy() async -> FakeHostConnection {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        return connection
    }
}

@MainActor
@Suite("新增 HTTPS 主機")
struct HTTPSHostEditorTests {
    static let address = HostServiceAddress("studio.tail1234.ts.net")!

    static func fill(_ model: HostEditorModel, code: String = "K7QM-2XPA") {
        model.connectionMethod = .https
        model.name = "Studio"
        model.address = "studio.tail1234.ts.net"
        model.pairingCode = code
    }

    @Test("以配對碼換得裝置權杖，用它連上主機服務後才能儲存;權杖存在這支裝置，主機設定記 HTTPS 與位址")
    func pairsTestsAndSaves() async throws {
        let store = MemoryHostStore()
        let tokens = InMemoryDeviceTokenStore()
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let model = HostEditorModel(store: store, hostService: connections.access(tokens: tokens, http: http), makeChannel: ChannelFactory().make)
        Self.fill(model)

        await model.test()

        guard case .connected(let check) = model.phase else { Issue.record("沒有連上:\(model.phase)"); return }
        #expect(check.agentCount == 3)
        #expect(check.readOnly == false)
        #expect(http.requests.first?.url.absoluteString == "https://studio.tail1234.ts.net/v1/pair")
        #expect(http.requests.first?.body == ["pairing_code": "K7QM-2XPA", "device_name": "Ray 的 iPhone"])
        #expect(connections.addresses == [Self.address])
        #expect(connections.tokens == ["token-paired"])
        #expect(model.canSave)

        let saved = try #require(model.save())
        #expect(saved.connectionMethod == .https)
        #expect(saved.hostService == Self.address)
        #expect(store.hosts == [saved])
        #expect(try tokens.deviceToken(for: saved.id) == "token-paired")
    }

    @Test("配對碼只能用一次：再測一次沿用剛拿到的權杖，不再送配對")
    func pairingCodeUsedOnce() async throws {
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy(), await HostServiceConnections.healthy()]
        let model = HostEditorModel(store: MemoryHostStore(), hostService: connections.access(http: http), makeChannel: ChannelFactory().make)
        Self.fill(model)

        await model.test()
        await model.test()

        #expect(http.requests.count == 1)
        #expect(connections.tokens == ["token-paired", "token-paired"])
    }

    @Test(
        "配對碼過期或不對：說明原因，不能儲存",
        arguments: [("OLD0-CODE", HostServiceError.pairingCodeExpired), ("ZZZZ-ZZZZ", .pairingCodeInvalid)])
    func pairingFails(code: String, expected: HostServiceError) async throws {
        let model = HostEditorModel(store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make)
        Self.fill(model, code: code)

        await model.test()

        #expect(model.phase == .failed(HostErrorText.message(for: expected, connection: .https)))
        #expect(!model.canSave)
    }

    @Test("編輯已配對的 HTTPS 主機、沒輸入新的配對碼：用存著的權杖測試，不送配對")
    func editingUsesStoredToken() async throws {
        let existing = HostConfiguration(name: "Studio", hostService: Self.address)
        let tokens = InMemoryDeviceTokenStore(tokens: [existing.id: "token-saved"])
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let model = HostEditorModel(
            store: MemoryHostStore(), editing: existing, hostService: connections.access(tokens: tokens, http: http),
            makeChannel: ChannelFactory().make)
        #expect(model.connectionMethod == .https)
        #expect(model.address == "studio.tail1234.ts.net")

        model.name = "Studio Mac"
        await model.test()
        let saved = try #require(model.save())

        #expect(http.requests.isEmpty)
        #expect(connections.tokens == ["token-saved"])
        #expect(saved.id == existing.id)
        #expect(try tokens.deviceToken(for: existing.id) == "token-saved")
    }

    @Test("新的 HTTPS 主機沒有配對碼不能測試;位址不是 https 也不能")
    func needsCodeAndAddress() {
        let model = HostEditorModel(store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make)
        Self.fill(model, code: "")
        #expect(!model.canTest)

        model.pairingCode = "K7QM-2XPA"
        model.address = "http://studio.tail1234.ts.net"
        #expect(!model.canTest)

        model.address = "studio.tail1234.ts.net"
        #expect(model.canTest)
    }

    @Test("QR code 的配對連結帶入 HTTPS、位址與配對碼")
    func importsPairingLink() throws {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        let url = try #require(URL(string: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net&code=K7QM-2XPA"))

        let editor = try model.makeImportEditor(url)

        #expect(editor.connectionMethod == .https)
        #expect(editor.address == "studio.tail1234.ts.net")
        #expect(editor.pairingCode == "K7QM-2XPA")
        #expect(editor.name == "studio")
    }

    @Test("主機分享連結匯入 HTTPS 主機：帶入名稱與位址，要輸入這支裝置的配對碼才能測試")
    func importsHTTPSShareLink() throws {
        let model = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        let link = HostShareLink.url(for: HostConfiguration(name: "Studio", hostService: Self.address))

        let editor = try model.makeImportEditor(link)

        #expect(editor.connectionMethod == .https)
        #expect(editor.name == "Studio")
        #expect(editor.address == "studio.tail1234.ts.net")
        #expect(editor.pairingCode.isEmpty)
        #expect(editor.needsPairingCode)
        #expect(!editor.canTest)
        editor.pairingCode = "K7QM-2XPA"
        #expect(editor.canTest)
    }

    @Test("編輯沒有權杖的 HTTPS 主機(同步來的):要輸入配對碼才能測試，配對後存下權杖")
    func pairsSyncedHost() async throws {
        let synced = HostConfiguration(name: "Studio", hostService: Self.address)
        let tokens = InMemoryDeviceTokenStore()
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let model = HostEditorModel(
            store: MemoryHostStore(), editing: synced, hostService: connections.access(tokens: tokens, http: http),
            makeChannel: ChannelFactory().make)

        #expect(model.needsPairingCode)
        #expect(!model.canTest)
        model.pairingCode = "K7QM-2XPA"
        await model.test()
        let saved = try #require(model.save())

        #expect(saved.id == synced.id)
        #expect(try tokens.deviceToken(for: synced.id) == "token-paired")
    }

    @Test("herdr 低於 0.9.5:與 SSH 一樣顯示需要更新，不能儲存")
    func outdatedHerdrNeedsUpdate() async throws {
        let outdated = FakeHostConnection()
        let snapshot = String(decoding: Fixtures.data("session.snapshot.ndjson"), as: UTF8.self)
            .replacingOccurrences(of: #""version":"0.9.5""#, with: #""version":"0.9.4""#)
        await outdated.expect("session.snapshot", reply: Data(snapshot.utf8))
        let connections = HostServiceConnections()
        connections.connections = [outdated]
        let model = HostEditorModel(store: MemoryHostStore(), hostService: connections.access(), makeChannel: ChannelFactory().make)
        Self.fill(model)

        await model.test()

        #expect(model.phase == .needsUpdate(HerdrVersion(major: 0, minor: 9, patch: 4)))
        #expect(!model.canSave)
    }

    @Test("配對成功但沒儲存就取消：請主機撤銷剛拿到的權杖，主機不留沒用的權杖")
    func cancellingAfterPairingRevokesToken() async throws {
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let model = HostEditorModel(store: MemoryHostStore(), hostService: connections.access(http: http), makeChannel: ChannelFactory().make)
        Self.fill(model)
        await model.test()

        model.discardUnsavedPairing()

        try await waitUntil { http.requests.count == 2 }
        #expect(http.requests.last == .init(url: Self.address.revokeURL, bearerToken: "token-paired", body: nil))
    }

    @Test("改了位址再配對一次：前一台主機拿到、沒用到的權杖請它撤銷")
    func pairingAgainRevokesPreviousToken() async throws {
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy(), await HostServiceConnections.healthy()]
        let model = HostEditorModel(store: MemoryHostStore(), hostService: connections.access(http: http), makeChannel: ChannelFactory().make)
        Self.fill(model)
        await model.test()

        model.address = "box.tail1234.ts.net"
        await model.test()

        let revokeURL = Self.address.revokeURL
        try await waitUntil { http.requests.contains { $0.url == revokeURL } }
        #expect(http.requests.filter { $0.url == revokeURL }.map(\.bearerToken) == ["token-paired"])
    }

    @Test("配對後儲存：權杖在用，取消或離開編輯器都不撤銷")
    func savedPairingIsKept() async throws {
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let model = HostEditorModel(store: MemoryHostStore(), hostService: connections.access(http: http), makeChannel: ChannelFactory().make)
        Self.fill(model)
        await model.test()
        _ = try #require(model.save())

        model.discardUnsavedPairing()

        try await Task.sleep(for: .milliseconds(100))
        let revokeURL = Self.address.revokeURL
        #expect(http.requests.allSatisfy { $0.url != revokeURL })
    }

    @Test("編輯已配對的 HTTPS 主機不必輸入配對碼")
    func pairedHostNeedsNoCode() {
        let existing = HostConfiguration(name: "Studio", hostService: Self.address)
        let model = HostEditorModel(
            store: MemoryHostStore(), editing: existing,
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [existing.id: "token-saved"])),
            makeChannel: ChannelFactory().make)

        #expect(!model.needsPairingCode)
        #expect(model.canTest)
    }
}

@MainActor
@Suite("HTTPS 主機")
struct HTTPSHostsModelTests {
    static let address = HostServiceAddress("studio.tail1234.ts.net")!

    @Test("HTTPS 主機的 Agent 列表經主機服務讀取，帶這支裝置存的權杖;主機清單顯示位址")
    func agentListOverHTTPS() async throws {
        let host = HostConfiguration(name: "Studio", hostService: Self.address)
        let store = MemoryHostStore()
        store.hosts = [host]
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let channels = ChannelFactory()
        let model = HostsModel(
            store: store, demoChannel: FakeHost(),
            hostService: connections.access(tokens: InMemoryDeviceTokenStore(tokens: [host.id: "token-saved"])),
            makeChannel: channels.make)

        model.load()
        await model.agentList.load()

        #expect(connections.addresses == [Self.address])
        #expect(connections.tokens == ["token-saved"])
        #expect(channels.endpoints.isEmpty, "HTTPS 主機不應該開 SSH 連線")
        #expect(model.agentList.sections.flatMap(\.rows).count == 3)
        #expect(model.rows.first?.subtitle == "https://studio.tail1234.ts.net")
    }

    @Test("主機清單：沒有裝置權杖的 HTTPS 主機標示要配對;已配對的與 SSH 主機不標示")
    func rowsShowUnpairedHosts() {
        let unpaired = HostConfiguration(name: "Synced", hostService: Self.address)
        let paired = HostConfiguration(name: "Paired", hostService: HostServiceAddress("box.tail1234.ts.net")!)
        let ssh = HostConfiguration(name: "SSH", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
        let store = MemoryHostStore()
        store.hosts = [unpaired, paired, ssh]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(),
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [paired.id: "token-saved"])),
            makeChannel: ChannelFactory().make)

        model.load()

        let needsPairing = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.title, $0.needsPairing) })
        #expect(needsPairing == ["Synced": true, "Paired": false, "SSH": false])
    }

    @Test("配對完儲存後，主機清單不再標示要配對")
    func pairingClearsUnpairedRow() async throws {
        let synced = HostConfiguration(name: "Studio", hostService: Self.address)
        let store = MemoryHostStore()
        store.hosts = [synced]
        let tokens = InMemoryDeviceTokenStore()
        let connections = HostServiceConnections()
        // 第一條給列表上那台主機的連線，第二條給編輯器的連線測試。
        connections.connections = [await HostServiceConnections.healthy(), await HostServiceConnections.healthy()]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostService: connections.access(tokens: tokens), makeChannel: ChannelFactory().make)
        model.load()
        #expect(model.rows.first?.needsPairing == true)

        let editor = model.makeEditor(editing: synced)
        editor.pairingCode = "K7QM-2XPA"
        await editor.test()
        let saved = try #require(editor.save())
        model.didSave(saved)

        #expect(model.rows.first?.needsPairing == false)
    }

    @Test("HTTPS 主機的分享連結只帶名稱與位址，不含這支裝置的裝置權杖")
    func shareLinkHasNoDeviceToken() throws {
        let host = HostConfiguration(name: "Studio", hostService: Self.address)
        let store = MemoryHostStore()
        store.hosts = [host]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(),
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [host.id: "purrdr-device-token-secret"])),
            makeChannel: ChannelFactory().make)
        model.load()

        let link = try #require(model.shareLink(for: host.id))
        let payload = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let json = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)

        #expect(!json.contains("purrdr-device-token-secret"))
        #expect(!link.absoluteString.contains("purrdr-device-token-secret"))
        let shared = try HostShareLink.decode(link)
        #expect(shared.hostService == Self.address)
    }

    @Test("刪除 HTTPS 主機：請主機服務撤銷這支裝置的權杖，並刪掉這支裝置存的權杖")
    func deleteRevokesToken() async throws {
        let host = HostConfiguration(name: "Studio", hostService: Self.address)
        let store = MemoryHostStore()
        store.hosts = [host]
        let tokens = InMemoryDeviceTokenStore(tokens: [host.id: "token-saved"])
        let http = FakeHostServiceHTTP()
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostService: HostServiceConnections().access(tokens: tokens, http: http),
            makeChannel: ChannelFactory().make)
        model.load()

        try await model.delete(host.id)

        #expect(try tokens.deviceToken(for: host.id) == nil)
        #expect(store.hosts.isEmpty)
        try await waitUntil { !http.requests.isEmpty }
        #expect(http.requests == [.init(url: Self.address.revokeURL, bearerToken: "token-saved", body: nil)])
    }

    @Test("深層連結 purrdr://pair 開啟主機 sheet,帶著要配對的連結")
    func pairingLinkOpensHosts() throws {
        let navigation = TopNavigationModel()
        let link = try #require(URL(string: "purrdr://pair?address=studio.tail1234.ts.net&code=K7QM-2XPA"))

        #expect(navigation.open(link))
        #expect(navigation.sheet == .hosts)
        #expect(navigation.pendingHostImport == link)
    }
}

@MainActor
@Suite("HTTPS 主機的權杖失效")
struct HTTPSDeviceTokenRejectionTests {
    /// 每個請求都以權杖被撤銷失敗，並計數。
    actor RevokedConnection: HostConnection {
        private(set) var attempts = 0

        func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
            attempts += 1
            throw HostServiceError.deviceTokenRevoked
        }

        func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
            attempts += 1
            throw HostServiceError.deviceTokenRevoked
        }

        func readTranscript(_ request: TranscriptRequest) async throws -> Data { throw HostServiceError.deviceTokenRevoked }

        func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
            throw HostServiceError.deviceTokenRevoked
        }

        func disconnect() async {}
    }

    @Test("權杖被撤銷：列表說明要重新配對，即時更新停下來等使用者，不會一直重連")
    func revokedTokenStopsLiveUpdates() async throws {
        let connection = RevokedConnection()
        let model = AgentListModel(client: HerdrClient(connection: connection), sleep: { _ in })

        let run = Task { await model.run() }
        try await waitUntil { await model.isWaitingForRetry }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await connection.attempts == 1)
        #expect(model.phase == .failed(HostErrorText.message(for: HostServiceError.deviceTokenRevoked)))
        run.cancel()
    }

    @Test("權杖失效的說明引導重新配對")
    func messagesGuideToPairAgain() {
        for error in [HostServiceError.deviceTokenRevoked, .deviceTokenInvalid, .notPaired] {
            #expect(HostErrorText.message(for: error).contains("pair"), "\(error)")
        }
    }

    @Test("這支裝置不在 tailnet 時請使用者開 Tailscale;主機離線時請使用者確認主機醒著")
    func notOnTailnetAndHostOfflineReadDifferently() {
        let notOnTailnet = HostErrorText.message(for: HostServiceError.notOnTailnet)
        let hostOffline = HostErrorText.message(for: HostServiceError.unreachable)

        #expect(notOnTailnet == String(localized: "This device isn’t connected to your tailnet. Turn on Tailscale on this device, then try again."))
        #expect(hostOffline == String(localized: "The host didn’t answer. Make sure it’s awake and connected to Tailscale."))
    }

    @Test("協定版本不相容：說明要更新的是主機服務還是 Purrdr;herdr 太舊時說明更新 herdr")
    func updateMessagesNameWhatToUpdate() {
        let olderHostService = HostErrorText.message(for: HostServiceError.protocolVersionUnsupported(supported: [HostServiceProtocol.version - 1]))
        let newerHostService = HostErrorText.message(for: HostServiceError.protocolVersionUnsupported(supported: [HostServiceProtocol.version + 1]))
        let olderHerdr = HostErrorText.message(for: HostServiceError.herdrCapabilityMissing)

        #expect(olderHostService == String(localized: "The Purrdr host service on this host is older than this version of Purrdr. Update the host service on the host."))
        #expect(newerHostService == String(localized: "The Purrdr host service on this host is newer than this version of Purrdr. Update Purrdr."))
        #expect(olderHerdr.contains("Update herdr"))
    }
}

@Suite("裝置權杖存 Keychain")
struct DeviceTokenKeychainTests {
    @Test("權杖存成「解鎖時、僅此裝置」且不同步的項目;讀得回來，設成 nil 就刪除")
    func storedOnlyOnThisDevice() throws {
        let keychain = FakeKeychain()
        let store = KeychainDeviceTokenStore(keychain: keychain)
        let host = UUID()

        try store.setDeviceToken("token-paired", for: host)

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrService as String] as? String == "com.raychiu.purrdr.device-token")
        #expect(try store.deviceToken(for: host) == "token-paired")
        try store.setDeviceToken(nil, for: host)
        #expect(try store.deviceToken(for: host) == nil)
    }
}
