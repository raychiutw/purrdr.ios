import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 一個視窗的導覽狀態(#37 故事 21、#31):Agent 列表之上以 sheet 開啟的畫面、兩欄的選取、鍵盤快捷鍵。
///
/// 頂層是 4 個 tab(聊天、檔案、主機、流量,#376;設定併進帳號 sheet,#503);帳號、新增聊天、付費牆與歡迎頁是 sheet,一次只開一個。
/// iPad 多視窗時每個視窗各一份(由 `TopNavigationView` 持有);主機清單與選取中主機(`HostsModel`)是全 app 共用的。
/// 聊天 tab 導覽堆疊的目的地(#641):整個堆疊只註冊這一個型別的 `navigationDestination(for:)`。
package enum ChatsDestination: Hashable {
    case chat(ChatRoute)
    case layout(SpacesLayoutRoute)

    package var chatRoute: ChatRoute? {
        if case .chat(let route) = self { route } else { nil }
    }
}

extension ChatsDestination: HidesTabBarOnPush {
    /// 聊天(對話或 Pane 終端機)隱藏;版面圖保留 tab bar。
    /// 從聊天再推入的頁面(「⋯」的 Pane 終端機、Git 變更、顯示版面、Subagent)不在路徑上,靠路徑上的聊天一起隱藏。
    var hidesTabBar: Bool { chatRoute != nil }
}

/// 寬視窗列表欄的選取(`List(selection:)` 的值):聊天,或多 Pane Tab 的版面圖。兩者都顯示在對話欄。
enum SidebarSelection: Hashable {
    case chat(ChatRoute)
    case layout(SpacesLayoutRoute)
}

@MainActor
@Observable
public final class TopNavigationModel {
    /// 目前選的 tab。
    public var tab = TopLevelTab.chats
    /// 目前開著的 sheet;`nil` 表示沒有 sheet。
    public var sheet: TopLevelSheet?
    /// 這個 build 有提供 Purrdr Plus 嗎(#676)。`false` 時 `purrdr://plus` 不動作。
    public var offersPlus = true
    /// 新增聊天是不是推入在聊天 tab 上(#621:push,不是 sheet;左上「<」離開)。
    public var isNewChatOpen = false {
        didSet { if !isNewChatOpen { newChatPreselection = nil } }
    }
    /// 新增聊天要預先選好的位置(Spaces 的「在此新增聊天」,#537);新增聊天沒開著時為 `nil`。
    public var newChatPreselection: NewChatPreselection?
    /// 等著匯入的主機分享連結(`purrdr://host?d=…`)或主機配對連結(`purrdr://pair?…`)。主機 tab 出現時帶入新增主機編輯器，之後清掉。
    public var pendingHostImport: URL?
    /// 等著開編輯頁的主機(點了主機服務通知,#293)。主機 tab 出現時推入它的編輯器，之後清掉。
    public var pendingHostEditor: UUID?
    /// 等著開新增主機引導(Agent 列表沒有主機時的「新增主機」,#332)。主機 tab 出現時推入，之後清掉。
    public var pendingAddHost = false

    /// 對話欄顯示的 Agent(主機 + pane id,#39)。iPhone 與窄視窗時是推入的對話。
    public var selectedChat: ChatRoute? {
        // 一次只有一個詳細(行為規格 F20):換聊天時，前一個聊天推入的終端機收起。
        didSet {
            if selectedChat != oldValue { openedTerminal = nil }
            if selectedChat != nil, selectedLayout != nil { selectedLayout = nil }
            reconcilePathWithSelection()
        }
    }

    /// 寬視窗對話欄顯示的版面圖(列表欄選了多 Pane 的 Tab,系統選取,不是推入);與 `selectedChat` 互斥。
    var selectedLayout: SpacesLayoutRoute? {
        didSet { if selectedLayout != nil, selectedChat != nil { selectedChat = nil } }
    }

    /// 寬視窗列表欄選取的內容(聊天或版面圖)。
    var sidebarSelection: SidebarSelection? {
        get {
            if let selectedChat { return .chat(selectedChat) }
            if let selectedLayout { return .layout(selectedLayout) }
            return nil
        }
        set {
            switch newValue {
            case .chat(let route): selectedChat = route
            case .layout(let route): selectedLayout = route
            case nil: selectedChat = nil; selectedLayout = nil
            }
        }
    }

    /// 聊天 tab 導覽堆疊的路徑(#641):窄視窗是 `NavigationStack(path:)` 的路徑(聊天、版面圖);寬視窗只放列表欄推入的版面圖。
    /// 列的 `NavigationLink(value:)`、選單的「Show Layout」、返回都改這一個陣列,不再混用 `navigationDestination(item:)`。
    package var chatsPath: [ChatsDestination] = [] {
        didSet { if chatsPath != oldValue { chatsPathChanged() } }
    }

    /// 聊天是不是放進 `chatsPath` 推入(窄視窗 `true`;寬視窗聊天是列表欄的選取,路徑只放版面圖)。由畫面依 size class 設定。
    /// 為真時路徑與選取由 model 維持一致(#685):路徑上最後一個聊天就是選取的聊天(返回時清成 `nil`);
    /// 外部設定選取(推播、新增聊天、橫幅、版面圖選 Pane)時把聊天放進路徑。
    package var pushesChatsOnPath = false {
        didSet { if pushesChatsOnPath != oldValue { reconcilePathWithSelection() } }
    }

    private func chatsPathChanged() {
        guard pushesChatsOnPath else { return }
        let chat = chatsPath.last(where: { $0.chatRoute != nil })?.chatRoute
        if selectedChat != chat { selectedChat = chat }
    }

    /// 已經有聊天在路徑上時換聊天(橫幅、版面圖選 Pane)不動路徑,頁面自己換內容(`CompactChatPage`)。
    private func reconcilePathWithSelection() {
        guard pushesChatsOnPath else { return }
        let hasChat = chatsPath.contains { $0.chatRoute != nil }
        switch (selectedChat, hasChat) {
        case (nil, true): chatsPath = chatsPath.filter { $0.chatRoute == nil }
        case (let chat?, false): chatsPath.append(.chat(chat))
        default: break
        }
    }

    // MARK: - 導覽動作(#685)

    /// 開聊天:選取那個聊天(窄視窗放進路徑,寬視窗顯示在對話欄)。新增聊天、橫幅、版面圖選 Pane 都走這裡。
    public func openChat(_ route: ChatRoute) {
        selectedChat = route
    }

    /// 返回:窄視窗從路徑退一層(選取跟著對齊);寬視窗清掉對話欄的選取。
    public func back() {
        if pushesChatsOnPath, !chatsPath.isEmpty {
            chatsPath.removeLast()
        } else {
            selectedChat = nil
            selectedLayout = nil
        }
    }

    /// App 鎖:從 app 外部來的導航(深層連結、推播)鎖定中等解鎖後才執行,只留最後一個。
    private let appLock: AppLock?

    private func whenUnlocked(_ navigation: @escaping @MainActor () -> Void) {
        guard let appLock else { return navigation() }
        appLock.whenUnlocked(navigation)
    }

    /// 外部開啟的網址(冷啟動與背景都走這裡):鎖定中延後。
    public func openExternal(_ url: URL) {
        whenUnlocked { [self] in open(url) }
    }

    /// 點了推播通知:鎖定中延後;解鎖後收起 sheet,依主機 model 轉出的目的地開聊天或主機編輯頁。
    public func openPush(_ route: PushRoute, hosts: HostsModel) {
        whenUnlocked { [self] in openPushDestination(hosts.open(route)) }
    }

    /// 這個視窗已經回報給列表「開著」的聊天。列表的 `onChange(initial: true)` 在堆疊重建、路徑變動時會再觸發一次,
    /// 所以開著與離開的計次以這裡為準,同一個聊天只計一次(#641:否則返回後聊天被當成還開著,「需要你」段落少一列)。
    private var reportedChat: ChatRoute?

    /// 把選取的聊天回報給列表(冪等):換了才記上一個離開、新的出現。
    package func reportVisibleChat(_ chat: ChatRoute?, to list: MergedAgentListModel) {
        guard chat != reportedChat else { return }
        if let reportedChat { list.chatDisappeared(reportedChat) }
        if let chat { list.chatAppeared(chat) }
        reportedChat = chat
    }

    /// 搜尋欄是否有焦點(Command-F)。
    public var isSearchFocused = false
    /// 對話欄推入的 Pane 終端機(主機 + pane id)。
    public var openedTerminal: ChatRoute?

    /// UI 測試用:是否處理 `purrdr://testing-…` 測試連結。只有 `-uiTesting` 啟動時由 composition root 開啟,正式 app 一律忽略。
    public var allowsTestingLinks = false
    /// 測試連結指定的字級類別名稱(`UICTContentSizeCategory…`);`nil` 是系統字級。畫面把它套到視窗,讓 UI 測試不重啟就能換字級。
    public private(set) var testingContentSizeCategory: String?
    /// 測試連結指定的外觀(`light`／`dark`);`nil` 跟隨系統。
    public private(set) var testingAppearance: String?

    /// 聊天頂列用量環開的面板(#617)的開關要求次數:選單列快捷鍵(Option-Command-I)每按一次加一,
    /// 目前顯示的聊天畫面依次數變化切換面板;開關狀態本身是聊天畫面的暫時狀態(不存偏好、不會每開一個聊天就跳出)。
    public private(set) var conversationPanelToggleCount = 0

    public init(appLock: AppLock? = nil) {
        self.appLock = appLock
    }

    /// 要求目前的聊天開關面板(快捷鍵用)。
    public func toggleConversationPanel() {
        conversationPanelToggleCount += 1
    }

    /// 列表看得到的 Agent,依 Spaces 的畫面順序(段落、Tab)。鍵盤切換 Agent 用:只含單一 Pane 的 Agent Tab
    /// (終端機與多個 Pane 的 Tab 要先開版面圖選 Pane,沒有單一對話可選)。列表合併了所有主機(#39),所以含所有主機的 Agent。
    public func visibleAgents(_ sections: [SpacesSection]) -> [ChatRoute] {
        sections.flatMap(\.tabs).compactMap { tab in
            guard case .agent = tab.avatar, case .pane(let route) = tab.target else { return nil }
            return route
        }
    }

    /// 視窗出現了：第一次開啟 app 時開出歡迎頁(#34)。已經有 sheet(例如冷啟動的深層連結)時不蓋掉它。
    public func launched(welcome: WelcomeModel) {
        guard sheet == nil, welcome.takeFirstLaunch() else { return }
        sheet = .welcome
    }

    /// 從帳號與設定再看一次歡迎頁(換掉帳號 sheet,同一時間只開一個)。
    public func showWelcome() {
        sheet = .welcome
    }

    /// 歡迎頁的「Try the Demo」:進入 Demo 主機(空列表時才看得到)並回到聊天 tab。
    public func welcomeTryDemo(hosts: HostsModel) {
        hosts.enterDemo()
        tab = .chats
        sheet = nil
    }

    /// 歡迎頁的「新增主機」:收起歡迎頁、選主機 tab 並直接進新增主機引導(#332:各入口都走引導)。
    public func welcomeAddHost() {
        openAddHost()
    }

    /// 主機選單的「新增主機…」、Agent 列表空狀態的「新增主機」:選主機 tab 並直接進新增主機引導。
    public func openAddHost() {
        pendingAddHost = true
        tab = .hosts
        sheet = nil
    }

    /// 點了主機服務通知：選主機 tab 並推入那台主機的編輯頁(主機服務區塊在那裡)。
    public func openHostEditor(_ id: UUID) {
        pendingHostEditor = id
        tab = .hosts
        sheet = nil
    }

    /// 點了通知(#668):收起 sheet;聊天類通知(已開出聊天)一律切回聊天 tab,不論目前在哪個 tab;
    /// 主機服務通知開那台主機的編輯頁;每日上限通知開帳號頁(不換 tab);測試通知(`nil`)只收起 sheet、不換 tab。
    public func openPushDestination(_ destination: PushDestination?) {
        sheet = nil
        switch destination {
        case .chat(let route):
            tab = .chats
            openChat(route)
        case .hostEditor(let id): openHostEditor(id)
        case .accountNotifications: sheet = .member
        case nil: break
        }
    }

    /// 「＋」與快捷鍵:切到聊天 tab,把新增聊天推進來(#621)。
    public func openNewChat() {
        tab = .chats
        isNewChatOpen = true
    }

    /// Workspace 標題選單的「在此新增聊天」:推入新增聊天,預選那台主機與 Workspace。
    public func startNewChat(inWorkspace workspaceID: String, on host: HostSelection) {
        openNewChat()
        newChatPreselection = NewChatPreselection(host: host, workspaceID: workspaceID)
    }

    /// 執行鍵盤快捷鍵。`visibleAgents` 是列表目前看得到的 Agent,依畫面順序。
    public func perform(_ command: KeyboardCommand, visibleAgents: [ChatRoute]) {
        switch command {
        case .nextAgent: selectAdjacentAgent(offset: 1, in: visibleAgents)
        case .previousAgent: selectAdjacentAgent(offset: -1, in: visibleAgents)
        case .search: isSearchFocused = true
        case .openTerminal: if let selectedChat { openedTerminal = selectedChat }
        case .newChat: openNewChat()
        case .settings:
            // 設定併進帳號 sheet(#503)。
            sheet = .member
        case .showChats, .showFiles, .showHosts, .showTraffic:
            if let tab = command.tab { self.tab = tab }
        case .toggleConversationPanel: toggleConversationPanel()
        case .openInNewWindow:
            // 開視窗要 `openWindow`(畫面的環境值),由 `TopNavigationView` 的 `WindowCommands` 處理。
            break
        }
    }

    /// 依列表順序選上／下一個 Agent;到頭或到底就停住(不繞回)。選取的 Agent 不在列表上時，從頭(或尾)開始。
    private func selectAdjacentAgent(offset: Int, in agents: [ChatRoute]) {
        guard !agents.isEmpty else { return }
        guard let current = selectedChat.flatMap(agents.firstIndex(of:)) else {
            selectedChat = offset > 0 ? agents.first : agents.last
            return
        }
        selectedChat = agents[min(max(current + offset, 0), agents.count - 1)]
    }

    /// 處理深層連結。認得就開對應畫面並回傳 `true`;不認得的連結不改變畫面。
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.urlScheme else { return false }
        switch url.host()?.lowercased() {
        case "settings":
            // 設定併進帳號 sheet(#503):開帳號與設定,不換 tab。
            sheet = .member
        case "plus":
            // 付費牆(#246):未加入會員也能從連結看方案。Plus 關閉(#676)時什麼都不做。
            guard offersPlus else { return false }
            sheet = .plus
        case "testing-content-size":
            // UI 測試不重啟換 Dynamic Type:`purrdr://testing-content-size?category=<類別>`,沒帶就回到系統字級。
            guard allowsTestingLinks else { return false }
            testingContentSizeCategory = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "category" }?.value
        case "testing-appearance":
            guard allowsTestingLinks else { return false }
            testingAppearance = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "style" }?.value
        case "host", "pair":
            // 系統相機掃 QR code(主機分享連結，或主機配對指令的 `purrdr://pair?…`)或點連結都會走到這裡;
            // 內容在主機 tab 裡解析與說明。
            pendingHostImport = url
            sheet = nil
            tab = .hosts
        default:
            return false
        }
        return true
    }

    /// app 註冊的 URL scheme(app 的 Info.plist `CFBundleURLTypes` 要一致)。
    public static let urlScheme = "purrdr"
}

/// 頂層 tab(#376、#503):聊天、檔案、主機、流量。
public enum TopLevelTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chats, files, hosts, traffic

    public var id: String { rawValue }

    /// `TabView` 的選取一律要是可見的 tab(iOS 27 SDK 起選到不可見的 tab 可能 crash,#519):不在可見清單時退回第一個可見的,都沒有就是聊天。
    public static func visibleSelection(_ tab: TopLevelTab, visible: [TopLevelTab]) -> TopLevelTab {
        visible.contains(tab) ? tab : (visible.first ?? .chats)
    }
}

/// 以 sheet 開啟的畫面(不是 tab)。
public enum TopLevelSheet: String, Identifiable, Sendable {
    /// 帳號與設定頁(#246、#503;右上角帳號鈕):會員、Purrdr Plus 開通步驟、設定(外觀、App 鎖…)、登入方式、刪除會員。
    case member
    /// Purrdr Plus 的付費牆與訂閱摘要(#28)。
    case plus
    /// 第一次開啟的歡迎頁(#34)。
    case welcome

    public var id: String { rawValue }
}

/// 新增聊天預先選好的主機與既有 Workspace(#537)。
public struct NewChatPreselection: Equatable, Sendable {
    public var host: HostSelection
    public var workspaceID: String

    public init(host: HostSelection, workspaceID: String) {
        self.host = host
        self.workspaceID = workspaceID
    }
}
