import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增主機引導的 HTTPS 路徑與兩種捷徑(#344):匯入(分享連結、配對 QR code)直接到測試連線,
/// 同步來、這支裝置還沒配對的主機直接到配對。只驗外部行為——下一步、顯示的指令、完成時存了什麼。
@MainActor
@Suite("新增主機引導：HTTPS")
struct AddHostGuideHTTPSTests {
    static let address = HostServiceAddress("studio.tail1234.ts.net")!
    static let pairingURL = URL(string: "purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net&code=K7QM-2XPA")!

    struct Rig {
        var store = MemoryHostStore()
        var tokens = InMemoryDeviceTokenStore()
        var http = FakeHostServiceHTTP()
        var connections = HostServiceConnections()
        var model: AddHostGuideModel
    }

    static func rig(
        store: MemoryHostStore = MemoryHostStore(), tokens: InMemoryDeviceTokenStore = InMemoryDeviceTokenStore(),
        shortcut: AddHostGuideModel.Shortcut? = nil
    ) async throws -> Rig {
        let http = FakeHostServiceHTTP()
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let access = connections.access(tokens: tokens, http: http)
        let model: AddHostGuideModel
        if let shortcut {
            model = try AddHostGuideModel(store: store, hostService: access, makeChannel: ChannelFactory().make, shortcut: shortcut)
        } else {
            model = AddHostGuideModel(store: store, hostService: access, makeChannel: ChannelFactory().make)
        }
        return Rig(store: store, tokens: tokens, http: http, connections: connections, model: model)
    }

    static func atInstall(_ model: AddHostGuideModel, system: HostOperatingSystem = .macOS) {
        model.choose(.https)
        model.advance()
        model.choose(system)
    }

    @Test("選 HTTPS:先準備 Tailscale(App Store 與電腦下載頁，可分享)、再選系統、裝主機服務、配對")
    func httpsStepsInOrder() async throws {
        let model = try await Self.rig().model
        model.choose(.https)
        #expect(model.step == .tailscale)
        let links = model.tailscaleInstructions.compactMap(\.link)
        #expect(links.contains(AddHostGuideModel.tailscaleAppStore))
        #expect(links.contains(AddHostGuideModel.tailscaleDownload))
        #expect(model.canAdvance)
        model.advance()
        #expect(model.step == .system)
        model.choose(.macOS)
        #expect(model.step == .install)
        model.advance()
        #expect(model.step == .pair)
        #expect(model.pairInstructions.compactMap(\.command) == ["purrdr pair"])
        #expect(model.progress.total == 6)
        #expect(model.progress.position == 5)
    }

    @Test("安裝指令依系統:macOS／Linux 是 install.sh、Windows 是 install.ps1")
    func installCommandDependsOnSystem() async throws {
        let base = "https://github.com/raychiutw/purrdr.host/releases/latest/download/"
        for system in [HostOperatingSystem.macOS, .linux] {
            let model = try await Self.rig().model
            Self.atInstall(model, system: system)
            #expect(model.installInstructions.compactMap(\.command) == ["curl -fsSL \(base)install.sh | sh"])
        }
        let windows = try await Self.rig().model
        Self.atInstall(windows, system: .windows)
        #expect(windows.installInstructions.compactMap(\.command) == ["irm \(base)install.ps1 | iex"])
    }

    @Test("掃到配對 QR code:帶入位址與配對碼，直接測試連線;不是配對連結就不動")
    func scanningPairingCode() async throws {
        let model = try await Self.rig().model
        Self.atInstall(model)
        model.advance()
        #expect(!model.applyScannedCode("https://example.com"))
        #expect(model.step == .pair)
        #expect(model.applyScannedCode(Self.pairingURL.absoluteString))
        #expect(model.step == .test)
        #expect(model.pairAddress == "studio.tail1234.ts.net")
        #expect(model.pairingCode == "K7QM-2XPA")
    }

    @Test("手動輸入位址、Port 與配對碼:缺一個不能往下;Port 預設 443")
    func manualPairing() async throws {
        let model = try await Self.rig().model
        Self.atInstall(model)
        model.advance()
        #expect(model.pairPort == "443")
        #expect(!model.canAdvance)
        model.pairAddress = "studio.tail1234.ts.net"
        #expect(!model.canAdvance)
        model.pairingCode = "k7qm-2xpa"
        #expect(model.canAdvance)
        model.pairPort = "x"
        #expect(!model.canAdvance)
        model.pairPort = "8443"
        model.advance()
        #expect(model.step == .test)
    }

    @Test("走完 HTTPS:配對、測試、儲存;權杖存在這支裝置，主機設定記 HTTPS 與位址，名稱取主機名稱第一段")
    func httpsPathSavesHost() async throws {
        let rig = try await Self.rig()
        Self.atInstall(rig.model)
        rig.model.advance()
        rig.model.pairAddress = "studio.tail1234.ts.net"
        rig.model.pairingCode = "k7qm-2xpa"
        rig.model.advance()
        await rig.model.testConnection()
        guard case .connected = rig.model.phase else { Issue.record("沒有連上:\(rig.model.phase)"); return }
        #expect(rig.store.hosts.isEmpty)
        let saved = try #require(rig.model.save())
        #expect(rig.model.step == .finished)
        #expect(saved.hostService == Self.address)
        #expect(saved.name == "studio")
        #expect(rig.store.hosts == [saved])
        #expect(try rig.tokens.deviceToken(for: saved.id) == "token-paired")
        #expect(rig.http.requests.first?.body?["pairing_code"] == "K7QM-2XPA")
    }

    @Test("配對碼不對:說明原因、不能儲存;返回改配對碼")
    func wrongCodeFails() async throws {
        let rig = try await Self.rig()
        Self.atInstall(rig.model)
        rig.model.advance()
        rig.model.pairAddress = "studio.tail1234.ts.net"
        rig.model.pairingCode = "ZZZZ-ZZZZ"
        rig.model.advance()
        await rig.model.testConnection()
        #expect(rig.model.phase == .failed(HostErrorText.message(for: HostServiceError.pairingCodeInvalid, connection: .https)))
        #expect(rig.model.save() == nil)
        rig.model.back()
        #expect(rig.model.step == .pair)
    }

    @Test("取消時，配對換得但沒存的權杖請主機撤銷")
    func cancelRevokesUnsavedPairing() async throws {
        let rig = try await Self.rig(shortcut: .importLink(Self.pairingURL))
        await rig.model.testConnection()
        rig.model.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.http.requests.contains { $0.url.path() == "/v1/revoke" })
        #expect(rig.store.hosts.isEmpty)
    }

    // MARK: - 捷徑

    @Test("匯入配對 QR code 連結:直接到測試連線，測試通過後儲存")
    func pairingLinkGoesToTest() async throws {
        let rig = try await Self.rig(shortcut: .importLink(Self.pairingURL))
        #expect(rig.model.step == .test)
        #expect(rig.model.kind == .https)
        await rig.model.testConnection()
        let saved = try #require(rig.model.save())
        #expect(saved.hostService == Self.address)
        #expect(try rig.tokens.deviceToken(for: saved.id) == "token-paired")
    }

    @Test("新增主機時的配對與撤銷也計入數據用量:記在即將儲存的那台主機底下(#353)")
    func pairingAndRevokeAreMetered() async throws {
        let rig = try await Self.rig(shortcut: .importLink(Self.pairingURL))
        let meter = TrafficMeter(store: InMemoryTrafficStore())
        rig.model.attachTraffic { meter.recorder(for: $0.uuidString) }

        await rig.model.testConnection()
        let saved = try #require(rig.model.save())

        let usage = try #require(meter.today()[saved.id.uuidString]?[.other])
        #expect(usage.sent > 0 && usage.received > 0, "配對請求送出的與收到的位元組")
    }

    @Test("匯入 HTTPS 主機分享連結:沒有配對碼，到配對那一步，位址已帶入")
    func httpsShareLinkGoesToPair() async throws {
        let shared = SharedHost(
            name: "Studio Mac", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", username: ""), connectionMethod: .https,
            hostService: HostServiceAddress("studio.tail1234.ts.net:8443"))
        let rig = try await Self.rig(shortcut: .importLink(HostShareLink.url(for: shared)))
        #expect(rig.model.step == .pair)
        #expect(rig.model.pairAddress == "studio.tail1234.ts.net")
        #expect(rig.model.pairPort == "8443")
        #expect(!rig.model.canAdvance, "還沒有配對碼")
        rig.model.pairingCode = "K7QM-2XPA"
        rig.model.advance()
        #expect(rig.model.step == .test)
    }

    @Test("匯入 Tailscale SSH 主機分享連結:資料已齊，直接到測試連線;分享附的 host key 當 pin，名稱沿用")
    func tailscaleShareLinkGoesToTest() async throws {
        let pin = HostEditorModelTests.fingerprint
        let shared = SharedHost(
            name: "Studio Mac", endpoint: SSHEndpoint(host: "studio-mac", port: 22, username: "ray"), connectionMethod: .tailscaleSSH,
            hostKeyPin: pin)
        let store = MemoryHostStore()
        let model = try AddHostGuideModel(
            store: store, makeChannel: ChannelFactory(await HostEditorModelTests.healthyHost()).make,
            shortcut: .importLink(HostShareLink.url(for: shared)))
        #expect(model.step == .test)
        #expect(model.kind == .ssh)
        await model.testConnection()
        let saved = try #require(model.save())
        #expect(saved.name == "Studio Mac")
        #expect(saved.connectionMethod == .tailscaleSSH)
        #expect(saved.ssh?.hostKeyPin == pin)
        #expect(saved.ssh?.endpoint == SSHEndpoint(host: "studio-mac", port: 22, username: "ray"))
    }

    @Test("匯入原生 SSH 分享連結:位址、Port、帳號與名稱已帶入，問完電腦種類就到登入方式(不用重填，也不離開引導)")
    func openSSHShareLinkContinuesInGuide() async throws {
        let pin = HostEditorModelTests.fingerprint
        let shared = SharedHost(
            name: "Box", endpoint: SSHEndpoint(host: "box.example.com", port: 2222, username: "ray"), connectionMethod: .openSSH,
            hostKeyPin: pin)
        let store = MemoryHostStore()
        let model = try AddHostGuideModel(
            store: store, makeChannel: ChannelFactory(await HostEditorModelTests.healthyHost()).make,
            shortcut: .importLink(HostShareLink.url(for: shared)))

        #expect(model.step == .system)
        #expect(model.kind == .ssh)
        #expect(model.sshMethod == .native)
        #expect(model.address == "box.example.com")
        #expect(model.port == "2222")
        #expect(model.username == "ray")

        model.choose(.macOS)
        #expect(model.step == .login, "已知是原生 SSH，不再問連線方式與位址")
        model.choose(authentication: .password)
        model.password = "secret"
        model.advance()
        #expect(model.step == .test)
        await model.testConnection()
        let saved = try #require(model.save())
        #expect(saved.name == "Box")
        #expect(saved.connectionMethod == .openSSH)
        #expect(saved.ssh?.endpoint == SSHEndpoint(host: "box.example.com", port: 2222, username: "ray"))
        #expect(saved.ssh?.hostKeyPin == pin)
    }

    @Test("壞連結:引導接不了，丟錯")
    func unsupportedLinksThrow() async throws {
        #expect(throws: (any Error).self) {
            try AddHostGuideModel(
                store: MemoryHostStore(), makeChannel: ChannelFactory().make,
                shortcut: .importLink(URL(string: "https://example.com")!))
        }
    }

    @Test("同步來、這支裝置還沒配對的主機:直接到配對，位址已帶入;配對後存回同一台主機(id 與名稱不變)")
    func unpairedHostGoesToPair() async throws {
        let existing = HostConfiguration(name: "Synced Studio", hostService: Self.address)
        let store = MemoryHostStore()
        store.hosts = [existing]
        let rig = try await Self.rig(store: store, shortcut: .needsPairing(existing))
        #expect(rig.model.step == .pair)
        #expect(rig.model.pairAddress == "studio.tail1234.ts.net")
        #expect(!rig.model.canGoBack)
        rig.model.pairingCode = "K7QM-2XPA"
        rig.model.advance()
        await rig.model.testConnection()
        let saved = try #require(rig.model.save())
        #expect(saved.id == existing.id)
        #expect(saved.name == "Synced Studio")
        #expect(store.hosts == [saved])
        #expect(try rig.tokens.deviceToken(for: existing.id) == "token-paired")
    }

    @Test("需要配對的捷徑只收 HTTPS 主機")
    func needsPairingRequiresHTTPSHost() async throws {
        let ssh = HostConfiguration(name: "SSH", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
        #expect(throws: AddHostGuideModel.ShortcutError.needsEditor) {
            try AddHostGuideModel(store: MemoryHostStore(), makeChannel: ChannelFactory().make, shortcut: .needsPairing(ssh))
        }
    }
}
