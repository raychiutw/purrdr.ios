import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增主機引導(#341):一頁一件事的狀態機。這裡只驗外部行為——下一步是什麼、顯示哪些指令、完成時存了什麼主機設定。
@MainActor
@Suite("新增主機引導")
struct AddHostGuideModelTests {
    static let fingerprint = HostEditorModelTests.fingerprint

    static func model(store: MemoryHostStore = MemoryHostStore(), factory: ChannelFactory = ChannelFactory()) -> AddHostGuideModel {
        AddHostGuideModel(store: store, makeChannel: factory.make)
    }

    /// 走到「開啟 SSH」那一步(Tailscale SSH)。
    static func atEnable(_ model: AddHostGuideModel, system: HostOperatingSystem = .macOS) {
        model.choose(.ssh)
        model.choose(system)
        model.choose(.tailscale)
    }

    /// 走到填主機的那一步並填好。
    static func atDetails(_ model: AddHostGuideModel, address: String = "studio-mac", username: String = "ray") {
        atEnable(model)
        model.advance()
        model.address = address
        model.username = username
    }

    @Test("第一頁預設推薦 SSH;選了 SSH 下一頁問電腦的作業系統")
    func startsWithSSHRecommended() {
        let model = Self.model()
        #expect(model.step == .kind)
        #expect(model.kind == .ssh)
        #expect(!model.canGoBack)
        model.choose(.ssh)
        #expect(model.step == .system)
    }

    @Test("Mac 與 Linux 可選 Tailscale SSH 或原生 SSH;Windows 只有 OpenSSH")
    func sshMethodsDependOnSystem() {
        for system in [HostOperatingSystem.macOS, .linux] {
            let model = Self.model()
            model.choose(.ssh)
            model.choose(system)
            #expect(model.step == .sshMethod)
            #expect(model.availableSSHMethods == [.tailscale, .native])
        }
        let windows = Self.model()
        windows.choose(.ssh)
        windows.choose(.windows)
        #expect(windows.availableSSHMethods == [.native])
    }

    @Test("Tailscale SSH:開啟 SSH 的步驟帶可拷貝的 `tailscale set --ssh`")
    func tailscaleEnableSteps() {
        let model = Self.model()
        Self.atEnable(model)
        #expect(model.step == .enable)
        let commands = model.enableInstructions.compactMap(\.command)
        #expect(commands == ["tailscale set --ssh"])
        #expect(model.enableInstructions.contains { $0.link != nil }, "要有 Tailscale 下載頁")
    }

    @Test("按「我已經開好了」進到填主機;Port 預設 22,不填主機與帳號就不能往下")
    func detailsRequireHostAndUsername() {
        let model = Self.model()
        Self.atEnable(model)
        model.advance()
        #expect(model.step == .details)
        #expect(model.port == "22")
        #expect(!model.canAdvance)
        model.address = "studio-mac"
        #expect(!model.canAdvance)
        model.username = "ray"
        #expect(model.canAdvance)
        model.port = "70000"
        #expect(!model.canAdvance, "Port 超出範圍")
    }

    @Test("每個欄位附怎麼查的指令:帳號 macOS／Linux 是 whoami、Windows 是 $env:USERNAME;Tailscale 的主機用 tailscale ip -4")
    func fieldHelpCommands() {
        let mac = Self.model()
        Self.atEnable(mac)
        #expect(mac.help(for: .username)?.command == "whoami")
        #expect(mac.help(for: .address)?.command == "tailscale ip -4")

        let linux = Self.model()
        Self.atEnable(linux, system: .linux)
        #expect(linux.help(for: .username)?.command == "whoami")

        let windows = Self.model()
        windows.choose(.ssh)
        windows.choose(.windows)
        windows.choose(.native)
        #expect(windows.help(for: .username)?.command == "$env:USERNAME")
    }

    @Test("可以返回上一步，答案還在;第一頁不能返回")
    func backKeepsAnswers() {
        let model = Self.model()
        Self.atEnable(model)
        model.advance()
        model.address = "studio-mac"
        model.back()
        #expect(model.step == .enable)
        model.back()
        #expect(model.step == .sshMethod)
        #expect(model.sshMethod == .tailscale)
        model.back()
        model.back()
        #expect(model.step == .kind)
        model.back()
        #expect(model.step == .kind)
        #expect(model.address == "studio-mac")
    }

    @Test("走完 Tailscale SSH:測試連線、第一次連線只問信任、信任後通過並儲存成 Tailscale SSH 主機")
    func tailscalePathSavesHost() async throws {
        let store = MemoryHostStore()
        let healthy = await HostEditorModelTests.healthyHost()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), healthy)
        let model = Self.model(store: store, factory: factory)
        Self.atDetails(model)

        await model.testConnection()
        #expect(model.step == .test)
        #expect(model.phase == .confirmHostKey(Self.fingerprint))
        #expect(store.hosts.isEmpty)

        await model.trustHostKey()
        guard case .tested = model.phase else { Issue.record("應該通過測試:\(model.phase)"); return }

        let saved = try #require(model.save())
        #expect(model.step == .finished)
        #expect(store.hosts == [saved])
        #expect(saved.connectionMethod == .tailscaleSSH)
        #expect(saved.ssh?.endpoint == SSHEndpoint(host: "studio-mac", port: 22, username: "ray"))
        #expect(saved.ssh?.hostKeyPin == Self.fingerprint)
        #expect(saved.operatingSystem == .macOS)
        #expect(saved.name == "studio-mac", "名稱預設取主機名稱第一段")
        #expect(model.savedHost == saved)
    }

    @Test("主機名稱帶網域時，名稱取第一段")
    func defaultName() async throws {
        let store = MemoryHostStore()
        let model = Self.model(store: store, factory: ChannelFactory(await HostEditorModelTests.healthyHost()))
        Self.atDetails(model, address: "studio.tail1234.ts.net")
        await model.testConnection()
        #expect(try #require(model.save()).name == "studio")
    }

    @Test("沒通過測試不能儲存;返回回到填主機，不留下主機")
    func notTestedLeavesNothing() async {
        let store = MemoryHostStore()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost())
        let model = Self.model(store: store, factory: factory)
        Self.atDetails(model)
        await model.testConnection()
        #expect(model.save() == nil)
        model.back()
        #expect(model.step == .details)
        #expect(model.phase == .editing)
        #expect(store.hosts.isEmpty)
    }

    @Test("測試之後改了主機就要重測才能儲存")
    func editingAfterTestBlocksSave() async {
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(factory: factory)
        Self.atDetails(model)
        await model.testConnection()
        model.address = "other-mac"
        #expect(model.save() == nil)
    }

    @Test("原生 SSH 與 HTTPS 目前交給主機編輯頁(後續票接手)")
    func otherPathsHandOffToEditor() {
        let native = Self.model()
        native.choose(.ssh)
        native.choose(.macOS)
        native.choose(.native)
        #expect(native.handoff == .editor(.openSSH))

        let https = Self.model()
        https.choose(.https)
        #expect(https.handoff == .editor(.https))
    }
}
