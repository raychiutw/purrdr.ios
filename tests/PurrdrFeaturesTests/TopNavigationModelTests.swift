import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

@MainActor
@Suite("iPhone 頂層導覽")
struct TopNavigationModelTests {
    @Test("深層連結 purrdr://settings 開啟設定 sheet")
    func settingsDeepLinkOpensSettings() throws {
        let model = TopNavigationModel()

        let handled = model.open(try #require(URL(string: "purrdr://settings")))

        #expect(handled)
        #expect(model.sheet == .settings)
    }

    @Test("深層連結 purrdr://plus 開啟 Purrdr Plus 付費牆 sheet")
    func plusDeepLinkOpensPaywall() throws {
        let model = TopNavigationModel()

        let handled = model.open(try #require(URL(string: "purrdr://plus")))

        #expect(handled)
        #expect(model.sheet == .plus)
    }

    @Test("主機分享連結(掃 QR code 或點連結)開啟主機 sheet,並帶著要匯入的連結")
    func hostLinkOpensHostsForImport() throws {
        let model = TopNavigationModel()
        model.sheet = .settings
        let link = HostShareLink.url(for: HostConfiguration(name: "Box", endpoint: SSHEndpoint(host: "box", username: "ops")))

        let handled = model.open(link)

        #expect(handled)
        #expect(model.sheet == .hosts)
        #expect(model.pendingHostImport == link)
    }

    @Test("點主機服務通知(#293):開主機 sheet,帶著要開編輯頁的主機")
    func hostServiceNotificationOpensHostEditor() {
        let model = TopNavigationModel()
        model.sheet = .settings
        let hostID = UUID()

        model.openHostEditor(hostID)

        #expect(model.sheet == .hosts)
        #expect(model.pendingHostEditor == hostID)
    }

    @Test(
        "不認得的連結不改變畫面，開著的主機 sheet 保持不動",
        arguments: ["purrdr://unknown", "https://settings", "otherapp://settings", "purrdr:settings"]
    )
    func unknownLinkKeepsCurrentSheet(link: String) throws {
        let model = TopNavigationModel()
        model.sheet = .hosts

        let handled = model.open(try #require(URL(string: link)))

        #expect(!handled)
        #expect(model.sheet == .hosts)
    }
}
