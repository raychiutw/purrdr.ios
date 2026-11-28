import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
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

    @Test("在此新增聊天:推入新增聊天並記下預選的主機與 Workspace;離開就清掉(#537、#621)")
    func startNewChatInWorkspace() {
        let model = TopNavigationModel()
        let host = HostSelection.host(UUID())

        model.startNewChat(inWorkspace: "w2", on: host)

        #expect(model.isNewChatOpen)
        #expect(model.tab == .chats)
        #expect(model.sheet == nil, "新增聊天是 push,不是 sheet")
        #expect(model.newChatPreselection == NewChatPreselection(host: host, workspaceID: "w2"))

        model.isNewChatOpen = false
        #expect(model.newChatPreselection == nil)
    }

    @Test("一般的新增聊天(快捷鍵)沒有預選,並切到聊天 tab")
    func plainNewChatHasNoPreselection() {
        let model = TopNavigationModel()
        model.tab = .files
        model.perform(.newChat, visibleAgents: [])
        #expect(model.isNewChatOpen)
        #expect(model.tab == .chats)
        #expect(model.sheet == nil)
        #expect(model.newChatPreselection == nil)
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

    @Test("Plus 關閉(#676):purrdr://plus 不動作、不改任何狀態,也不當成已處理")
    func plusDeepLinkIsIgnoredWhenPlusIsOff() throws {
        let model = TopNavigationModel()
        model.offersPlus = false
        model.sheet = .member

        let handled = model.open(try #require(URL(string: "purrdr://plus")))

        #expect(!handled)
        #expect(model.sheet == .member)
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

    @Test("點聊天類通知(#668):不在聊天 tab 也切回聊天 tab、收起 sheet")
    func chatNotificationSelectsChatsTab() {
        let model = TopNavigationModel()
        model.tab = .files
        model.sheet = .member

        model.openPushDestination(.chat(ChatRoute(host: .demo, paneID: "w1:p1")))

        #expect(model.tab == .chats)
        #expect(model.sheet == nil)
    }

    @Test("點測試通知(沒有目的地)不換 tab,只收起 sheet(#668)")
    func testNotificationKeepsTab() {
        let model = TopNavigationModel()
        model.tab = .files
        model.sheet = .member

        model.openPushDestination(nil)

        #expect(model.tab == .files)
        #expect(model.sheet == nil)
    }

    @Test("點每日上限通知:收起 sheet 後開帳號頁,不換 tab")
    func dailyLimitNotificationOpensAccount() {
        let model = TopNavigationModel()
        model.tab = .files
        model.openPushDestination(.accountNotifications)
        #expect(model.tab == .files)
        #expect(model.sheet == .member)
        #expect(model.pendingHostEditor == nil)
    }

    @Test("點主機服務通知走主機編輯頁(#668 不變)")
    func hostServiceNotificationViaDestination() {
        let model = TopNavigationModel()
        let id = UUID()
        model.openPushDestination(.hostEditor(id))
        #expect(model.tab == .hosts)
        #expect(model.pendingHostEditor == id)
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

    @Test("同一個聊天重複回報只計一次,離開後不留在「開著」(#641:列表堆疊重建會再觸發一次 initial)")
    func reportingVisibleChatIsIdempotent() {
        let window = TopNavigationModel()
        let list = MergedAgentListModel()
        let chat = ChatRoute(host: .demo, paneID: "w3:p1")
        window.reportVisibleChat(chat, to: list)
        window.reportVisibleChat(chat, to: list)
        #expect(list.visibleChats == [chat])
        window.reportVisibleChat(nil, to: list)
        #expect(list.visibleChats.isEmpty, "重複回報不能讓離開後仍算開著")
    }

    // MARK: - 導覽動作(#685)

    private static let chatA = ChatRoute(host: .demo, paneID: "w1:p1")
    private static let chatB = ChatRoute(host: .demo, paneID: "w2:p1")

    @Test("窄視窗開聊天:放進路徑,路徑上最後一個聊天就是選取的聊天")
    func openChatPushesOntoPath() {
        let model = TopNavigationModel()
        model.pushesChatsOnPath = true

        model.openChat(Self.chatA)
        #expect(model.chatsPath == [.chat(Self.chatA)])

        model.openChat(Self.chatB)
        #expect(model.chatsPath == [.chat(Self.chatA)], "已有聊天在路徑上換聊天不動路徑")
        #expect(model.selectedChat == Self.chatB)
    }

    @Test("窄視窗返回:路徑退一層,選取清成 nil")
    func backClearsSelection() {
        let model = TopNavigationModel()
        model.pushesChatsOnPath = true
        model.openChat(Self.chatA)

        model.back()

        #expect(model.chatsPath.isEmpty)
        #expect(model.selectedChat == nil)
    }

    @Test("系統返回手勢(直接改路徑)也清掉選取")
    func systemPopClearsSelection() {
        let model = TopNavigationModel()
        model.pushesChatsOnPath = true
        model.openChat(Self.chatA)

        model.chatsPath = []

        #expect(model.selectedChat == nil)
    }

    @Test("寬視窗開聊天只改選取,不動路徑;返回清掉選取")
    func wideWindowKeepsPathEmpty() {
        let model = TopNavigationModel()

        model.openChat(Self.chatA)
        #expect(model.selectedChat == Self.chatA)
        #expect(model.chatsPath.isEmpty)

        model.back()
        #expect(model.selectedChat == nil)
    }

    @Test("視窗由寬變窄:已選的聊天補進路徑")
    func narrowingAddsSelectedChatToPath() {
        let model = TopNavigationModel()
        model.openChat(Self.chatA)

        model.pushesChatsOnPath = true

        #expect(model.chatsPath == [.chat(Self.chatA)])
    }

    @Test("推播的聊天目的地:切回聊天 tab 並選取該聊天(路徑跟著)")
    func pushChatSelectsChat() {
        let model = TopNavigationModel()
        model.pushesChatsOnPath = true
        model.tab = .traffic

        model.openPushDestination(.chat(Self.chatA))

        #expect(model.tab == .chats)
        #expect(model.selectedChat == Self.chatA)
        #expect(model.chatsPath == [.chat(Self.chatA)])
    }

    @Test("App 鎖定中收到的外部網址延到解鎖後才開,只留最後一個")
    func lockedExternalURLsWaitAndKeepLast() async {
        let lock = AppLock(authenticator: AppLockTests.ScriptedAuthenticator([.success]), defaults: AppLockTests.defaults(enabled: true))
        let model = TopNavigationModel(appLock: lock)

        model.openExternal(URL(string: "purrdr://plus")!)
        model.openExternal(URL(string: "purrdr://settings")!)
        #expect(model.sheet == nil, "鎖定中不該導航")

        await lock.unlock()
        #expect(model.sheet == .member)
    }

    @Test("App 鎖定中點推播:解鎖後才收起 sheet、執行導航;沒鎖定立即執行")
    func lockedPushWaitsForUnlock() async {
        let lock = AppLock(authenticator: AppLockTests.ScriptedAuthenticator([.success]), defaults: AppLockTests.defaults(enabled: true))
        let model = TopNavigationModel(appLock: lock)
        let hosts = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.sheet = .member

        model.openPush(PushRoute(keyHash: "abc", paneID: "w1:p1"), hosts: hosts)
        #expect(model.sheet == .member)

        await lock.unlock()
        #expect(model.sheet == nil)

        let open = TopNavigationModel()
        open.sheet = .member
        open.openPush(PushRoute(keyHash: "abc", paneID: "w1:p1"), hosts: hosts)
        #expect(open.sheet == nil)
    }
}
