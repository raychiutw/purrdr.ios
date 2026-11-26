import Foundation
import PurrdrCore
import PurrdrFeatures
import Security
import Testing

/// Keychain 的假實作(Seam 3):依 service + account 存資料，記錄每次新增時的屬性。
final class FakeKeychain: KeychainAPI, @unchecked Sendable {
    var items: [String: Data] = [:]
    var addedAttributes: [[String: Any]] = []
    var addStatus: OSStatus = errSecSuccess
    /// 有值時讀取一律回這個狀態(例如還沒第一次解鎖)。
    var copyStatus: OSStatus?
    /// 不是 `errSecSuccess` 時,更新一律回這個狀態(項目不變)。
    var updateStatus: OSStatus = errSecSuccess
    /// 被刪過的 account(依序)。
    var deletedAccounts: [String] = []

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard addStatus == errSecSuccess else { return addStatus }
        let account = attributes[kSecAttrAccount as String] as! String
        guard items[account] == nil else { return errSecDuplicateItem }
        addedAttributes.append(attributes)
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let account = query[kSecAttrAccount as String] as! String
        guard items[account] != nil else { return errSecItemNotFound }
        guard updateStatus == errSecSuccess else { return updateStatus }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    /// 每次 `copyMatching` 是否在主執行緒(#590:冷啟動讀取不在主執行緒)。
    private(set) var copiesOnMainThread: [Bool] = []

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        copiesOnMainThread.append(Thread.isMainThread)
        if let copyStatus { return (copyStatus, nil) }
        if query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String {
            let account = query[kSecAttrAccount as String] as! String
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as NSData)
        }
        guard !items.isEmpty else { return (errSecItemNotFound, nil) }
        let all = items.sorted { $0.key < $1.key }.map {
            [kSecValueData as String: $0.value, kSecAttrAccount as String: $0.key] as NSDictionary
        }
        return (errSecSuccess, all as NSArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let account = query[kSecAttrAccount as String] as! String
        deletedAccounts.append(account)
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@MainActor
@Suite("主機存 Keychain")
struct KeychainHostStoreTests {
    static let host = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"),
        herdr: HerdrInstallation(session: "work"), operatingSystem: .macOS,
        hostKeyPin: HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww"))

    @Test("主機與 pin 存成「解鎖時、僅此裝置」且不同步的 Keychain 項目")
    func storesOnlyOnThisDeviceWhenUnlocked() throws {
        let keychain = FakeKeychain()
        let store = KeychainHostStore(keychain: keychain)

        try store.save(Self.host)

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test("存了讀得回來;再存一次是更新，不是多一筆;刪除後就不在了")
    func roundTrip() throws {
        let store = KeychainHostStore(keychain: FakeKeychain())
        #expect(try store.loadHosts().isEmpty)

        try store.save(Self.host)
        var renamed = Self.host
        renamed.name = "Studio Mac"
        try store.save(renamed)
        #expect(try store.loadHosts() == [renamed])

        try store.delete(Self.host.id)
        #expect(try store.loadHosts().isEmpty)
    }

    @Test("冷啟動的背景讀取與同步讀取結果相同,而且不在主執行緒讀 Keychain(#590)")
    func backgroundLoadReadsOffMain() async throws {
        let keychain = FakeKeychain()
        let store = KeychainHostStore(keychain: keychain)
        try store.save(Self.host)
        let synchronous = try store.loadHosts()
        let before = keychain.copiesOnMainThread.count

        let background = try await store.loadHostsInBackground()

        #expect(background == synchronous)
        #expect(keychain.copiesOnMainThread.count == before + 1)
        #expect(keychain.copiesOnMainThread.last == false, "Keychain 讀取在主執行緒")
    }

    @Test("Keychain 拒絕寫入時丟出錯誤(畫面要留在編輯器說明)")
    func writeFailureThrows() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecMissingEntitlement
        let store = KeychainHostStore(keychain: keychain)

        #expect(throws: KeychainError.self) { try store.save(Self.host) }
    }
    // MARK: - 儲存格式遷移(#149)

    static let studioID = UUID(uuidString: "6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70")!
    static let boxID = UUID(uuidString: "7A2B3C4D-5E6F-4071-8A9B-0C1D2E3F4A5B")!
    static let httpsID = UUID(uuidString: "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")!
    static let pinText = "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww"

    /// 0.36 以前的 app 寫進 Keychain 的內容(所有欄位攤平在主機設定上)。
    static let legacyItems: [String: String] = [
        studioID.uuidString: """
        {"id":"\(studioID.uuidString)","name":"Studio","endpoint":{"host":"studio-mac","port":22,"username":"demo"},\
        "connectionMethod":"tailscaleSSH","herdr":{"path":"herdr","session":"work"},"operatingSystem":"macOS",\
        "hostKeyPin":"\(pinText)"}
        """,
        boxID.uuidString: """
        {"id":"\(boxID.uuidString)","name":"Linux box","endpoint":{"host":"100.64.0.9","port":2222,"username":"ops"},\
        "connectionMethod":"openSSH","authentication":"password","herdr":{"path":"/opt/herdr"},"operatingSystem":"linux"}
        """,
        httpsID.uuidString: """
        {"id":"\(httpsID.uuidString)","name":"Studio HTTPS",\
        "endpoint":{"host":"studio.tail1234.ts.net","port":443,"username":""},"connectionMethod":"https",\
        "herdr":{"path":"herdr"},"hostService":"https://studio.tail1234.ts.net"}
        """,
    ]

    static func keychain(with items: [String: String]) -> FakeKeychain {
        let keychain = FakeKeychain()
        keychain.items = items.mapValues { Data($0.utf8) }
        return keychain
    }

    static func storedObject(_ keychain: FakeKeychain, _ id: UUID) throws -> [String: Any] {
        let data = try #require(keychain.items[id.uuidString])
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("舊版存的 Tailscale SSH、OpenSSH 與 HTTPS 主機讀得回來")
    func loadsLegacyHosts() throws {
        let store = KeychainHostStore(keychain: Self.keychain(with: Self.legacyItems))

        let hosts = try store.loadHosts()

        let pin = try #require(HostKeyFingerprint(stored: Self.pinText))
        #expect(Set(hosts) == [
            HostConfiguration(
                id: Self.studioID, name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"),
                herdr: HerdrInstallation(session: "work"), operatingSystem: .macOS, hostKeyPin: pin),
            HostConfiguration(
                id: Self.boxID, name: "Linux box", endpoint: SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops"),
                openSSH: .password, herdr: HerdrInstallation(path: "/opt/herdr"),
                operatingSystem: .linux),
            HostConfiguration(id: Self.httpsID, name: "Studio HTTPS", hostService: try #require(HostServiceAddress("studio.tail1234.ts.net"))),
        ])
    }

    @Test("存回新格式：連線方式帶自己的欄位，HTTPS 主機只有主機服務位址")
    func savesConnectionInNewFormat() throws {
        let keychain = Self.keychain(with: Self.legacyItems)
        let store = KeychainHostStore(keychain: keychain)

        for host in try store.loadHosts() { try store.save(host) }

        let https = try #require(try Self.storedObject(keychain, Self.httpsID)["connection"] as? [String: String])
        #expect(https == ["method": "https", "hostService": "https://studio.tail1234.ts.net"])
        let box = try #require(try Self.storedObject(keychain, Self.boxID)["connection"] as? [String: Any])
        #expect(Set(box.keys) == ["method", "endpoint", "herdr", "authentication"])
        #expect(box["method"] as? String == "openSSH")
        #expect(box["authentication"] as? String == "password")
        let studio = try #require(try Self.storedObject(keychain, Self.studioID)["connection"] as? [String: Any])
        #expect(Set(studio.keys) == ["method", "endpoint", "herdr", "hostKeyPin"])
        #expect(studio["hostKeyPin"] as? String == Self.pinText)
    }

    @Test("新格式的連線方式優先於留給舊版 app 的欄位")
    func newFormatWinsOverLegacyFields() throws {
        let item = """
        {"id":"\(Self.boxID.uuidString)","name":"Linux box",\
        "connection":{"method":"openSSH","endpoint":{"host":"10.0.0.5","port":2200,"username":"admin"},\
        "herdr":{"path":"herdr"},"authentication":"importedKey"},\
        "endpoint":{"host":"100.64.0.9","port":22,"username":"ops"},"connectionMethod":"tailscaleSSH","herdr":{"path":"herdr"}}
        """
        let store = KeychainHostStore(keychain: Self.keychain(with: [Self.boxID.uuidString: item]))

        let hosts = try store.loadHosts()

        #expect(hosts == [
            HostConfiguration(
                id: Self.boxID, name: "Linux box", endpoint: SSHEndpoint(host: "10.0.0.5", port: 2200, username: "admin"),
                openSSH: .importedKey),
        ])
    }

    @Test("新格式仍寫出舊欄位，舊版 app(0.36)讀得懂新存的主機")
    func olderAppReadsNewFormat() throws {
        let keychain = Self.keychain(with: Self.legacyItems)
        let store = KeychainHostStore(keychain: keychain)
        let expected = try Self.legacyItems.mapValues { try JSONDecoder().decode(LegacyHostRecord.self, from: Data($0.utf8)) }

        for host in try store.loadHosts() { try store.save(host) }

        let reread = try keychain.items.mapValues { try JSONDecoder().decode(LegacyHostRecord.self, from: $0) }
        #expect(reread == expected)
    }

    @Test("讀不懂的主機不靜默略過：其他主機照常讀出，記入診斷紀錄，項目留在 Keychain")
    func unreadableHostIsLogged() throws {
        let missingAddress = """
        {"id":"\(Self.httpsID.uuidString)","name":"Studio HTTPS",\
        "endpoint":{"host":"studio.tail1234.ts.net","port":443,"username":""},"connectionMethod":"https","herdr":{"path":"herdr"}}
        """
        let keychain = Self.keychain(with: [
            Self.httpsID.uuidString: missingAddress, Self.studioID.uuidString: try #require(Self.legacyItems[Self.studioID.uuidString]),
        ])
        let log = RecordingDiagnosticLog()
        let store = KeychainHostStore(keychain: keychain, diagnostics: log.log)

        let hosts = try store.loadHosts()

        #expect(hosts.map(\.id) == [Self.studioID])
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains(Self.httpsID.uuidString) == true)
        #expect(keychain.items[Self.httpsID.uuidString] != nil)
    }
}

/// 0.36 的主機設定(合成的 Codable):模擬舊版 app 讀 Keychain。
private struct LegacyHostRecord: Decodable, Equatable {
    var id: UUID
    var name: String
    var endpoint: SSHEndpoint
    var connectionMethod: String
    var authentication: String?
    var herdr: HerdrInstallation
    var operatingSystem: String?
    var hostKeyPin: String?
    var hostService: String?
}

