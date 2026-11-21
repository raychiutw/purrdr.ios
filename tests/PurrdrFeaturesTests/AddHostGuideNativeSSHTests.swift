import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增主機引導的原生 SSH／OpenSSH 路徑(#342)。只驗外部行為:下一步是什麼、顯示哪些指令、完成時存了什麼。
@MainActor
@Suite("新增主機引導:原生 SSH")
struct AddHostGuideNativeSSHTests {
    static func model(store: MemoryHostStore = MemoryHostStore(), factory: ChannelFactory = ChannelFactory()) -> AddHostGuideModel {
        AddHostGuideModel(store: store, makeChannel: factory.make)
    }

    /// 走到「讓電腦接受連線」(原生 SSH)。
    static func atEnable(_ model: AddHostGuideModel, system: HostOperatingSystem = .macOS) {
        model.choose(.ssh)
        model.choose(system)
        model.choose(.native)
    }

    /// 走到填主機那一步。
    static func atDetails(_ model: AddHostGuideModel, system: HostOperatingSystem = .macOS, location: AddHostGuideModel.Location = .home) {
        atEnable(model, system: system)
        model.advance()
        model.choose(location)
    }

    /// 填好主機與帳號,走到登入方式。
    static func atLogin(_ model: AddHostGuideModel, system: HostOperatingSystem = .macOS, location: AddHostGuideModel.Location = .home) {
        atDetails(model, system: system, location: location)
        model.address = "192.168.1.20"
        model.username = "ray"
        model.advance()
    }

    @Test("選原生 SSH 不再轉去編輯頁;先教開啟 SSH,再問在哪裡連")
    func nativeStaysInGuide() {
        let model = Self.model()
        Self.atEnable(model)
        #expect(model.handoff == nil)
        #expect(model.step == .enable)
        model.advance()
        #expect(model.step == .location)
        model.choose(.home)
        #expect(model.step == .details)
    }

    @Test("開啟 SSH 的步驟依系統:macOS 是遠端登入、Linux 與 Windows 帶可拷貝的指令")
    func enableInstructionsPerSystem() {
        let mac = Self.model()
        Self.atEnable(mac)
        #expect(mac.enableInstructions.contains { $0.text.contains("Remote Login") })
        #expect(mac.enableInstructions.allSatisfy { $0.command == nil })

        let linux = Self.model()
        Self.atEnable(linux, system: .linux)
        let linuxCommand = linux.enableInstructions.compactMap(\.command).joined()
        #expect(linuxCommand.contains("openssh-server") && linuxCommand.contains("systemctl enable --now"))

        let windows = Self.model()
        Self.atEnable(windows, system: .windows)
        let windowsCommand = windows.enableInstructions.compactMap(\.command).joined()
        #expect(windowsCommand.contains("OpenSSH.Server") && windowsCommand.contains("Start-Service sshd"))
        #expect(windows.enableInstructions.first?.text.contains("administrator") == true)
    }

    @Test("主機位址的怎麼查依在哪裡連:家裡查區域網路 IP、Tailscale 查 Tailscale IP、對外沒有指令但提醒路由器")
    func addressHelpDependsOnLocation() {
        let home = Self.model()
        Self.atDetails(home, location: .home)
        #expect(home.help(for: .address)?.command == "ipconfig getifaddr en0")
        #expect(home.detailsNotice == nil)

        let homeLinux = Self.model()
        Self.atDetails(homeLinux, system: .linux, location: .home)
        #expect(homeLinux.help(for: .address)?.command == "hostname -I")

        let homeWindows = Self.model()
        Self.atDetails(homeWindows, system: .windows, location: .home)
        #expect(homeWindows.help(for: .address)?.command?.contains("Get-NetIPAddress") == true)

        let tailscale = Self.model()
        Self.atDetails(tailscale, location: .viaTailscale)
        #expect(tailscale.help(for: .address)?.command == "tailscale ip -4")

        let outside = Self.model()
        Self.atDetails(outside, location: .outside)
        #expect(outside.help(for: .address)?.command == nil)
        #expect(outside.detailsNotice?.contains("router") == true)
    }

    @Test("填完主機之後問登入方式:密碼或金鑰;其他方式是匯入私鑰")
    func loginChoices() {
        let model = Self.model()
        Self.atLogin(model)
        #expect(model.step == .login)

        model.choose(authentication: .password)
        #expect(model.step == .credential)
        model.back()
        model.choose(authentication: .deviceKey)
        #expect(model.step == .keySetup)
        model.back()
        model.choose(authentication: .importedKey)
        #expect(model.step == .credential)
    }

    @Test("密碼路徑:要填密碼才能往下;存成 OpenSSH 密碼主機並把密碼存進 Keychain")
    func passwordPathSavesHost() async throws {
        let store = MemoryHostStore()
        let secrets = EphemeralHostSecretStore()
        let healthy = await HostEditorModelTests.healthyHost()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), healthy)
        let model = AddHostGuideModel(store: store, credentials: HostCredentials(secrets: secrets), makeChannel: factory.make)
        Self.atLogin(model)
        model.choose(authentication: .password)
        #expect(!model.canAdvance)
        model.password = "hunter2"
        #expect(model.canAdvance)
        model.advance()
        #expect(model.step == .test)

        await model.testConnection()
        // 第一次連線要確認主機身分(原生 SSH 不自動記住)。
        guard case .confirmHostKey = model.phase else { Issue.record("應該先問信任:\(model.phase)"); return }
        await model.trustHostKey()
        guard case .tested = model.phase else { Issue.record("信任後應該通過:\(model.phase)"); return }

        let saved = try #require(model.save())
        #expect(saved.connectionMethod == .openSSH)
        #expect(saved.authentication == .password)
        #expect(saved.ssh?.endpoint == SSHEndpoint(host: "192.168.1.20", port: 22, username: "ray"))
        #expect(try secrets.secret(for: saved.id) == .password("hunter2"))
    }

    @Test("金鑰路徑:取得這支裝置的公鑰,指令帶它;Windows 另附管理員帳號的指令")
    func deviceKeyInstructions() async throws {
        let model = Self.model()
        Self.atLogin(model)
        model.choose(authentication: .deviceKey)
        #expect(!model.canAdvance, "還沒取得公鑰")
        await model.loadDeviceKey()
        #expect(model.canAdvance)
        let key = try #require(model.devicePublicKey)
        let commands = model.keyInstructions.compactMap(\.command)
        #expect(commands.count == 1)
        #expect(commands[0].contains(key.openSSH) && commands[0].contains("authorized_keys"))

        let windows = Self.model()
        Self.atLogin(windows, system: .windows)
        windows.choose(authentication: .deviceKey)
        await windows.loadDeviceKey()
        let windowsCommands = windows.keyInstructions.compactMap(\.command)
        #expect(windowsCommands.count == 2)
        #expect(windowsCommands[1].contains("administrators_authorized_keys"))
    }

    private struct BrokenDeviceKey: DeviceKey {
        struct Failure: Error {}
        func publicKey() throws -> SSHPublicKey { throw Failure() }
        func signingKey() throws -> SSHPrivateKey { throw Failure() }
    }

    @Test("金鑰路徑:拿不到裝置金鑰時像編輯頁一樣說明原因,不是一直轉圈")
    func deviceKeyFailureIsExplained() async {
        let model = AddHostGuideModel(
            store: MemoryHostStore(), credentials: HostCredentials(deviceKey: BrokenDeviceKey()), makeChannel: ChannelFactory().make)
        Self.atLogin(model)
        model.choose(authentication: .deviceKey)
        await model.loadDeviceKey()
        #expect(model.devicePublicKey == nil)
        #expect(model.deviceKeyProblem != nil)
        #expect(!model.canAdvance)
    }

    @Test("給 Windows 複製的指令只含 ASCII:裝置名稱含中文時,引導與編輯頁的金鑰指令都一樣")
    func windowsKeyCommandsAreASCII() async throws {
        let credentials = HostCredentials(deviceKey: EphemeralDeviceKey(comment: "purrdr@我的 iPhone"))
        let guide = AddHostGuideModel(store: MemoryHostStore(), credentials: credentials, makeChannel: ChannelFactory().make)
        Self.atLogin(guide, system: .windows)
        guide.choose(authentication: .deviceKey)
        await guide.loadDeviceKey()
        let editor = HostEditorModel(store: MemoryHostStore(), credentials: credentials, makeChannel: ChannelFactory().make)
        await editor.loadDeviceKey()
        // 引導在 Windows 上的每一個指令(含啟用 SSH、金鑰、欄位說明)。
        let guideCommands = (guide.keyInstructions + guide.enableInstructions + [guide.help(for: .address), guide.help(for: .username)].compactMap { $0 })
            .compactMap(\.command)
        #expect(guideCommands.count >= 4)
        for command in guideCommands + editor.deviceKeySteps.compactMap(\.command).filter({ $0.contains("USERPROFILE") || $0.contains("ProgramData") }) {
            #expect(command.unicodeScalars.allSatisfy { $0.isASCII }, "\(command)")
        }
    }

    @Test("金鑰路徑存成裝置金鑰主機")
    func deviceKeyPathSavesHost() async throws {
        let store = MemoryHostStore()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), await HostEditorModelTests.healthyHost())
        let model = Self.model(store: store, factory: factory)
        Self.atLogin(model, location: .viaTailscale)
        model.choose(authentication: .deviceKey)
        await model.loadDeviceKey()
        model.advance()
        await model.testConnection()
        await model.trustHostKey()
        let saved = try #require(model.save())
        #expect(saved.authentication == .deviceKey)
    }

    @Test("匯入私鑰:貼上不是私鑰的文字不能往下")
    func importedKeyNeedsValidKey() {
        let model = Self.model()
        Self.atLogin(model)
        model.choose(authentication: .importedKey)
        model.privateKey = "not a key"
        #expect(!model.canAdvance)
    }

    @Test("密碼路徑的文字不出現「金鑰」(key)")
    func passwordPathMentionsNoKey() {
        let model = Self.model()
        Self.atLogin(model)
        model.choose(authentication: .password)
        #expect(model.credentialPrompt.lowercased().contains("key") == false)
    }

    @Test("進度總步數:Tailscale SSH 6 步,原生 SSH 9 步")
    func progressTotals() {
        let native = Self.model()
        Self.atEnable(native)
        #expect(native.progress.total == 9)
        let tailscale = Self.model()
        tailscale.choose(.ssh)
        tailscale.choose(.macOS)
        tailscale.choose(.tailscale)
        #expect(tailscale.progress.total == 6)
    }
}
