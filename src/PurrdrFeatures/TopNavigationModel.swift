import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 一個視窗的導覽狀態(#37 故事 21、#31):Agent 列表之上以 sheet 開啟的畫面、兩欄的選取、鍵盤快捷鍵。
///
/// 頂層是 4 個 tab(聊天、檔案、主機、流量,#376;設定併進帳號 sheet,#503);帳號、新增聊天、付費牆與歡迎頁是 sheet,一次只開一個。
/// iPad 多視窗時每個視窗各一份(由 `TopNavigationView` 持有);主機清單與選取中主機(`HostsModel`)是全 app 共用的。
@MainActor
@Observable
public final class TopNavigationModel {
    /// 目前選的 tab。
    public var tab = TopLevelTab.chats
    /// 目前開著的 sheet;`nil` 表示沒有 sheet。
    public var sheet: TopLevelSheet?
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
        didSet { if selectedChat != oldValue { openedTerminal = nil } }
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

    public init() {}

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
            // 付費牆(#246):未加入會員也能從連結看方案。
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
