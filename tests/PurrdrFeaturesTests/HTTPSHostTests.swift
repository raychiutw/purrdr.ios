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
        #expect(model.address == "https://studio.tail1234.ts.net")

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
        #expect(editor.address == "https://studio.tail1234.ts.net")
        #expect(editor.pairingCode == "K7QM-2XPA")
        #expect(editor.name == "studio")
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
        #expect(!model.selectedHostSupportsShell)
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
