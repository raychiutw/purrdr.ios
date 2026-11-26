import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增主機引導的連線失敗提醒與最後一頁(#345):提醒依前面的選擇;最後一頁有 Plus 開通知、沒有就一行提示,SSH 主機另提主機服務。
@MainActor
@Suite("新增主機引導:失敗提醒與最後一頁")
struct AddHostGuideFailureAndNotificationTests {
    static func failingModel(
        system: HostOperatingSystem = .macOS, method: AddHostGuideModel.SSHMethod, location: AddHostGuideModel.Location? = nil
    ) async -> AddHostGuideModel {
        let broken = FakeHost()
        await broken.failConnection(with: SSHConnectionError.connectionLost)
        let model = AddHostGuideModel(store: MemoryHostStore(), makeChannel: ChannelFactory(broken).make)
        model.choose(.ssh)
        model.choose(system)
        model.choose(method)
        model.advance()
        if method == .native, let location {
            model.choose(location)
            model.address = "192.168.1.20"
        } else {
            model.address = "studio-mac"
        }
        model.username = "ray"
        if method == .native {
            model.advance()
            model.choose(authentication: .password)
            model.password = "secret"
        }
        model.advance()
        await model.testConnection()
        return model
    }

    static func texts(_ model: AddHostGuideModel) -> String { model.failureReminders.joined(separator: "\n") }

    @Test("Tailscale SSH 失敗:提醒兩邊開著 Tailscale、同一個帳號")
    func tailscaleSSH() async {
        let model = await Self.failingModel(method: .tailscale)
        guard case .failed = model.phase else { Issue.record("應該失敗:\(model.phase)"); return }
        #expect(model.failureReminders.count == 1)
        #expect(Self.texts(model).contains("Tailscale") && Self.texts(model).contains("same account"))
    }

    @Test("原生 SSH 只在家裡:提醒同一個 Wi-Fi,並建議在外面用 Tailscale")
    func nativeHome() async {
        let model = await Self.failingModel(method: .native, location: .home)
        #expect(Self.texts(model).contains("same Wi-Fi"))
        #expect(Self.texts(model).contains("Tailscale"))
    }

    @Test("原生 SSH 透過 Tailscale:提醒 Tailscale 兩邊開著、同帳號,不提路由器與 Wi-Fi")
    func nativeViaTailscale() async {
        let model = await Self.failingModel(method: .native, location: .viaTailscale)
        #expect(Self.texts(model).contains("same account"))
        #expect(!Self.texts(model).contains("router") && !Self.texts(model).contains("Wi-Fi"))
    }

    @Test("原生 SSH 對外位址:提醒對外位址與路由器,並建議改用 Tailscale")
    func nativeOutside() async {
        let model = await Self.failingModel(method: .native, location: .outside)
        #expect(Self.texts(model).contains("router"))
        #expect(Self.texts(model).contains("Tailscale"))
    }

    @Test("HTTPS 失敗:提醒 Tailscale 兩邊開著同帳號、主機服務有在跑")
    func https() async throws {
        let rig = try await AddHostGuideHTTPSTests.rig()
        AddHostGuideHTTPSTests.atInstall(rig.model)
        rig.model.advance()
        rig.model.pairAddress = "studio.tail1234.ts.net"
        rig.model.pairingCode = "ZZZZ-ZZZZ"
        rig.model.advance()
        await rig.model.testConnection()
        guard case .failed = rig.model.phase else { Issue.record("應該失敗:\(rig.model.phase)"); return }
        let text = Self.texts(rig.model)
        #expect(text.contains("same account") && text.contains("host service"))
    }

    @Test("沒失敗時沒有提醒;主機身分變了不是連線問題,也不提醒")
    func noReminderWithoutFailure() async {
        let model = AddHostGuideModel(store: MemoryHostStore(), makeChannel: ChannelFactory().make)
        #expect(model.failureReminders.isEmpty)
        let changed = FakeHost()
        await changed.failConnection(
            with: SSHConnectionError.hostKeyChanged(presented: AddHostGuideModelTests.fingerprint, pinned: HostEditorModelTests.otherFingerprint))
        let model2 = AddHostGuideModel(store: MemoryHostStore(), makeChannel: ChannelFactory(changed).make)
        model2.choose(.ssh)
        model2.choose(.macOS)
        model2.choose(.tailscale)
        model2.advance()
        model2.address = "studio-mac"
        model2.username = "ray"
        model2.advance()
        await model2.testConnection()
        #expect(model2.failureReminders.isEmpty)
    }

    // MARK: - 最後一頁

    static func saved(plus: Bool) async throws -> AddHostGuideModel {
        let model = AddHostGuideModel(
            store: MemoryHostStore(), isPlusActive: { plus }, makeChannel: ChannelFactory(await HostEditorModelTests.healthyHost()).make)
        model.choose(.ssh)
        model.choose(.macOS)
        model.choose(.tailscale)
        model.advance()
        model.address = "studio-mac"
        model.username = "ray"
        model.advance()
        await model.testConnection()
        _ = try #require(model.save())
        await model.loadNotificationOffer()
        return model
    }

    @Test("有 Purrdr Plus:最後一頁給這台主機的開啟通知開關")
    func plusOffersToggle() async throws {
        let model = try await Self.saved(plus: true)
        #expect(model.step == .finished)
        #expect(model.notificationOffer == .toggle)
    }

    @Test("沒有 Plus:一行加入提示,不擋完成")
    func noPlusOffersJoin() async throws {
        let model = try await Self.saved(plus: false)
        #expect(model.notificationOffer == .joinPlus)
        #expect(model.step == .finished)
        #expect(model.savedHost != nil)
    }

    @Test("SSH 主機提示可再裝主機服務;HTTPS 主機不提")
    func hostServiceHintOnlyForSSH() async throws {
        let ssh = try await Self.saved(plus: true)
        #expect(ssh.suggestsHostService)
        let rig = try await AddHostGuideHTTPSTests.rig(shortcut: .importLink(AddHostGuideHTTPSTests.pairingURL))
        await rig.model.testConnection()
        _ = try #require(rig.model.save())
        #expect(!rig.model.suggestsHostService)
    }

    @Test("最後一頁以前不提供通知選項")
    func noOfferBeforeFinish() async {
        let model = AddHostGuideModel(store: MemoryHostStore(), isPlusActive: { true }, makeChannel: ChannelFactory().make)
        await model.loadNotificationOffer()
        #expect(model.notificationOffer == nil)
        #expect(!model.suggestsHostService)
    }

    @Test("HostsModel 建的引導接上推播服務的 Plus 判斷:有 Plus 的會員在最後一頁看得到開關")
    func hostsModelGuideKnowsPlus() async throws {
        let hosts = HostsModel(
            store: MemoryHostStore(), demoChannel: FakeHost(), push: HostServiceUpdateTests.pushService(),
            makeChannel: ChannelFactory(await HostEditorModelTests.healthyHost()).make)
        let model = hosts.screens.makeAddHostGuide()
        model.choose(.ssh)
        model.choose(.macOS)
        model.choose(.tailscale)
        model.advance()
        model.address = "studio-mac"
        model.username = "ray"
        model.advance()
        await model.testConnection()
        _ = try #require(model.save())
        await model.loadNotificationOffer()
        #expect(model.notificationOffer == .toggle)
    }
}
