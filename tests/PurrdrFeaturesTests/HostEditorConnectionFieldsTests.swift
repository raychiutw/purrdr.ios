import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 加入主機頁(#250):先選連線方式才出現欄位、Port 預設、HTTPS 位址與 Port 分開、配對 QR code 掃描。
@MainActor
@Suite("加入主機：連線方式與欄位")
struct HostEditorConnectionFieldsTests {
    static func newEditor() -> HostEditorModel {
        HostEditorModel(store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make)
    }

    @Test("新主機還沒選連線方式：不出現連線欄位，也不能測試")
    func noFieldsBeforeChoosingMethod() {
        let model = Self.newEditor()
        model.name = "Studio"

        #expect(model.connectionMethod == nil)
        #expect(model.connectionFields.isEmpty)
        #expect(!model.canTest)
    }

    @Test(
        "每種連線方式只出現自己的欄位;Tailscale SSH 沒有登入方式(密碼),HTTPS 沒有帳號",
        arguments: [
            (.tailscaleSSH, [.address, .port, .username, .advanced]),
            (.openSSH, [.address, .port, .username, .signIn, .advanced]),
            (.https, [.address, .port, .pairingCode]),
        ] as [(HostConfiguration.ConnectionMethod, [HostEditorModel.ConnectionField])])
    func fieldsPerMethod(method: HostConfiguration.ConnectionMethod, expected: [HostEditorModel.ConnectionField]) {
        let model = Self.newEditor()

        model.connectionMethod = method

        #expect(model.connectionFields == expected)
    }

    @Test("Port 預設：Tailscale SSH、OpenSSH 是 22,HTTPS 是 443;沒手動改過時換方式跟著換")
    func portFollowsMethodDefault() {
        let model = Self.newEditor()

        model.connectionMethod = .tailscaleSSH
        #expect(model.port == "22")
        model.connectionMethod = .https
        #expect(model.port == "443")
        model.connectionMethod = .openSSH
        #expect(model.port == "22")
    }

    @Test("Port 手動改過：換連線方式不覆蓋")
    func editedPortIsKept() {
        let model = Self.newEditor()
        model.connectionMethod = .https

        model.port = "8443"
        model.connectionMethod = .openSSH

        #expect(model.port == "8443")
    }

    @Test("HTTPS 位址與 Port 分開填，存成帶埠的主機服務位址")
    func httpsPortIsSeparateField() async throws {
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let store = MemoryHostStore()
        let model = HostEditorModel(store: store, hostService: connections.access(), makeChannel: ChannelFactory().make)
        model.connectionMethod = .https
        model.name = "Studio"
        model.address = "studio.tail1234.ts.net"
        model.port = "8443"
        model.pairingCode = "K7QM-2XPA"

        await model.test()
        let saved = try #require(model.save())

        #expect(saved.hostService == HostServiceAddress("https://studio.tail1234.ts.net:8443"))
        #expect(connections.addresses == [HostServiceAddress("https://studio.tail1234.ts.net:8443")!])
    }

    @Test(
        "舊版 app 存在鑰匙圈的 HTTPS 位址(含埠或不含埠)拆成位址與 Port;不改就存回同一個位址",
        arguments: [
            ("https://studio.tail1234.ts.net:8443", "8443"),
            ("https://studio.tail1234.ts.net", "443"),
        ])
    func legacyKeychainAddressIsSplit(stored: String, port: String) throws {
        let id = UUID(uuidString: "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")!
        let legacyItem = """
            {"id":"\(id.uuidString)","name":"Studio HTTPS",\
            "endpoint":{"host":"studio.tail1234.ts.net","port":\(port),"username":""},"connectionMethod":"https",\
            "herdr":{"path":"herdr"},"hostService":"\(stored)"}
            """
        let keychain = FakeKeychain()
        keychain.items = [id.uuidString: Data(legacyItem.utf8)]
        let host = try #require(try KeychainHostStore(keychain: keychain).loadHosts().first)

        let model = HostEditorModel(
            store: MemoryHostStore(), editing: host,
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [id: "token-saved"])),
            makeChannel: ChannelFactory().make)

        #expect(model.connectionMethod == .https)
        #expect(model.address == "studio.tail1234.ts.net")
        #expect(model.port == port)
        #expect(!model.hasChanges)
    }

    @Test("編輯既有主機：直接顯示已選的方式與欄位")
    func editingShowsChosenMethod() {
        let existing = HostConfiguration(
            name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", port: 2222, username: "demo"), openSSH: .deviceKey)

        let model = HostEditorModel(store: MemoryHostStore(), editing: existing, makeChannel: ChannelFactory().make)

        #expect(model.connectionMethod == .openSSH)
        #expect(model.connectionFields == [.address, .port, .username, .signIn, .advanced])
        #expect(model.port == "2222")
    }

    // MARK: - 配對 QR code 掃描

    @Test("掃到配對 QR code:自動選 HTTPS,填好位址、Port、配對碼;名稱空白時用主機名稱第一段")
    func scannedPairingCodeFillsFields() {
        let model = Self.newEditor()
        model.connectionMethod = .tailscaleSSH

        let accepted = model.applyScannedCode("purrdr://pair?address=https%3A%2F%2Fraychiu-pc.tail2750c0.ts.net%3A8443&code=K7QM-2XPA")

        #expect(accepted)
        #expect(model.connectionMethod == .https)
        #expect(model.address == "raychiu-pc.tail2750c0.ts.net")
        #expect(model.port == "8443")
        #expect(model.pairingCode == "K7QM-2XPA")
        #expect(model.name == "raychiu-pc")
        #expect(model.canTest)
    }

    @Test("掃到配對 QR code 時已填的名稱保留")
    func scanKeepsName() {
        let model = Self.newEditor()
        model.name = "Office PC"

        _ = model.applyScannedCode("purrdr://pair?address=https%3A%2F%2Fraychiu-pc.tail2750c0.ts.net&code=K7QM-2XPA")

        #expect(model.name == "Office PC")
        #expect(model.port == "443")
    }

    @Test("掃到的不是配對 QR code:不採用、欄位不變", arguments: ["https://example.com", "purrdr://pair?code=K7QM-2XPA", "hello"])
    func nonPairingCodeIsIgnored(text: String) {
        let model = Self.newEditor()
        model.connectionMethod = .openSSH
        model.address = "studio-mac"

        #expect(!model.applyScannedCode(text))
        #expect(model.connectionMethod == .openSSH)
        #expect(model.address == "studio-mac")
        #expect(model.port == "22")
    }
}
