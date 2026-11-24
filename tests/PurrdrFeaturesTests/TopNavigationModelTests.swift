import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

@MainActor
@Suite("iPhone 頂層導覽")
struct TopNavigationModelTests {
    @Test("深層連結 purrdr://settings 開帳號與設定 sheet,不換 tab(#503)")
    func settingsDeepLinkOpensAccountSheet() throws {
        let model = TopNavigationModel()
        model.tab = .files

        let handled = model.open(try #require(URL(string: "purrdr://settings")))

        #expect(handled)
        #expect(model.sheet == .member)
        #expect(model.tab == .files)
    }

    @Test("頂層有 4 個 tab:聊天、檔案、主機、流量(設定併進帳號,#503),預設停在聊天")
    func fourTabsStartOnChats() {
        #expect(TopLevelTab.allCases == [.chats, .files, .hosts, .traffic])
        #expect(TopNavigationModel().tab == .chats)
    }

    @Test("新增主機…:切到主機 tab 並直接進新增主機引導")
    func addHostSelectsHostsTab() {
        let model = TopNavigationModel()
        model.openAddHost()
        #expect(model.tab == .hosts)
        #expect(model.pendingAddHost)
    }

    @Test("深層連結 purrdr://plus 開啟 Purrdr Plus 付費牆 sheet")
    func plusDeepLinkOpensPaywall() throws {
        let model = TopNavigationModel()

        let handled = model.open(try #require(URL(string: "purrdr://plus")))

        #expect(handled)
        #expect(model.sheet == .plus)
    }

    @Test("UI 測試連結 purrdr://testing-content-size 換字級，只在開啟測試連結時生效")
    func testingContentSizeLinkChangesCategoryOnlyWhenAllowed() throws {
        let category = "UICTContentSizeCategoryAccessibilityXXXL"
        let link = try #require(URL(string: "purrdr://testing-content-size?category=\(category)"))
        let model = TopNavigationModel()

        #expect(!model.open(link))
        #expect(model.testingContentSizeCategory == nil)

        model.allowsTestingLinks = true
        #expect(model.open(link))
        #expect(model.testingContentSizeCategory == category)
        #expect(model.sheet == nil)

        // 沒帶 category 回到系統字級。
        #expect(model.open(try #require(URL(string: "purrdr://testing-content-size"))))
        #expect(model.testingContentSizeCategory == nil)
    }

    @Test("UI 測試連結 purrdr://testing-appearance 換淺色或深色，只在開啟測試連結時生效")
    func testingAppearanceLinkChangesStyleOnlyWhenAllowed() throws {
        let dark = try #require(URL(string: "purrdr://testing-appearance?style=dark"))
        let model = TopNavigationModel()

        #expect(!model.open(dark))
        #expect(model.testingAppearance == nil)

        model.allowsTestingLinks = true
        #expect(model.open(dark))
        #expect(model.testingAppearance == "dark")
        #expect(model.open(try #require(URL(string: "purrdr://testing-appearance"))))
        #expect(model.testingAppearance == nil)
    }

    @Test("主機分享連結(掃 QR code 或點連結)選主機 tab,並帶著要匯入的連結")
    func hostLinkOpensHostsForImport() throws {
        let model = TopNavigationModel()
        model.tab = .files
        let link = HostShareLink.url(for: HostConfiguration(name: "Box", endpoint: SSHEndpoint(host: "box", username: "ops")))

        let handled = model.open(link)

        #expect(handled)
        #expect(model.tab == .hosts)
        #expect(model.pendingHostImport == link)
    }

    @Test("點主機服務通知(#293):選主機 tab,帶著要開編輯頁的主機")
    func hostServiceNotificationOpensHostEditor() {
        let model = TopNavigationModel()
        model.tab = .files
        let hostID = UUID()

        model.openHostEditor(hostID)

        #expect(model.tab == .hosts)
        #expect(model.pendingHostEditor == hostID)
    }

    @Test(
        "不認得的連結不改變畫面，停在原本的 tab",
        arguments: ["purrdr://unknown", "https://settings", "otherapp://settings", "purrdr:settings"]
    )
    func unknownLinkKeepsCurrentSheet(link: String) throws {
        let model = TopNavigationModel()
        model.tab = .hosts

        let handled = model.open(try #require(URL(string: link)))

        #expect(!handled)
        #expect(model.tab == .hosts)
    }
}
