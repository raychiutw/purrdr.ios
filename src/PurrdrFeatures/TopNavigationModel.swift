import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 一個視窗的導覽狀態(#37 故事 21、#31):Agent 列表之上以 sheet 開啟的畫面、三欄的選取、鍵盤快捷鍵。
///
/// 頂層是 5 個 tab(聊天、檔案、主機、流量、設定,#376);帳號、新增聊天、付費牆與歡迎頁是 sheet,一次只開一個。
/// iPad 多視窗時每個視窗各一份(由 `TopNavigationView` 持有);主機清單與選取中主機(`HostsModel`)是全 app 共用的。
@MainActor
@Observable
public final class TopNavigationModel {
    /// 目前選的 tab。
    public var tab = TopLevelTab.chats
    /// 目前開著的 sheet;`nil` 表示沒有 sheet。
    public var sheet: TopLevelSheet?
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
    /// 側欄選的 workspace(選取中主機上的);`nil` 是所有 workspace。
    public var workspaceFilter: String?
    /// iPad 的版面圖浮動卡片。
    public let layoutCard = LayoutCardModel()

    /// UI 測試用:是否處理 `purrdr://testing-…` 測試連結。只有 `-uiTesting` 啟動時由 composition root 開啟,正式 app 一律忽略。
    public var allowsTestingLinks = false
    /// 測試連結指定的字級類別名稱(`UICTContentSizeCategory…`);`nil` 是系統字級。畫面把它套到視窗,讓 UI 測試不重啟就能換字級。
    public private(set) var testingContentSizeCategory: String?
    /// 測試連結指定的外觀(`light`／`dark`);`nil` 跟隨系統。
    public private(set) var testingAppearance: String?

    public init() {}

    /// 套用側欄 workspace 篩選後的列表;空的分組不顯示。篩選的 workspace 已不在主機上時(被關掉了)顯示全部。
    ///
    /// 列表合併了所有主機(#39);workspace 屬於選取中主機(`host`,`snapshot` 是它的),篩選時只留那台主機上那個 workspace 的列。
    public func visibleSections(_ sections: [AgentSection], host: HostSelection, snapshot: HostSnapshot?) -> [AgentSection] {
        guard let workspaceFilter, let snapshot, snapshot.workspaces.contains(where: { $0.id == workspaceFilter }) else {
            return sections
        }
        let panes = Set(snapshot.agents.filter { $0.workspaceID == workspaceFilter }.map(\.paneID))
        return sections.compactMap { section in
            let rows = section.rows.filter { $0.host == host && panes.contains($0.paneID) }
            return rows.isEmpty ? nil : AgentSection(group: section.group, rows: rows)
        }
    }

    /// 列表看得到的 Agent,依畫面順序。鍵盤切換 Agent 用。
    public func visibleAgents(_ sections: [AgentSection], host: HostSelection, snapshot: HostSnapshot?) -> [ChatRoute] {
        visibleSections(sections, host: host, snapshot: snapshot).flatMap { $0.rows.map(\.route) }
    }

    /// 視窗出現了：第一次開啟 app 時開出歡迎頁(#34)。已經有 sheet(例如冷啟動的深層連結)時不蓋掉它。
    public func launched(welcome: WelcomeModel) {
        guard sheet == nil, welcome.takeFirstLaunch() else { return }
        sheet = .welcome
    }

    /// 從設定頁再看一次歡迎頁(換掉設定 sheet,同一時間只開一個)。
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

    /// 換了選取中主機：側欄的 workspace 篩選與版面圖卡片屬於前一台主機，清掉。
    /// 選取的聊天與它的終端機留著：列表合併了所有主機(#39),聊天帶著自己的主機，換選取中主機不影響它。
    public func hostChanged() {
        workspaceFilter = nil
        layoutCard.close()
    }

    /// 執行鍵盤快捷鍵。`visibleAgents` 是列表目前看得到的 Agent,依畫面順序。
    public func perform(_ command: KeyboardCommand, visibleAgents: [ChatRoute]) {
        switch command {
        case .nextAgent: selectAdjacentAgent(offset: 1, in: visibleAgents)
        case .previousAgent: selectAdjacentAgent(offset: -1, in: visibleAgents)
        case .search: isSearchFocused = true
        case .openTerminal: if let selectedChat { openedTerminal = selectedChat }
        case .newChat: sheet = .newChat
        case .settings:
            sheet = nil
            tab = .settings
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
            sheet = nil
            tab = .settings
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

/// 頂層 tab(#376):聊天、檔案、主機、流量、設定。
public enum TopLevelTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chats, files, hosts, traffic, settings

    public var id: String { rawValue }
}

/// 以 sheet 開啟的畫面(不是 tab)。
public enum TopLevelSheet: String, Identifiable, Sendable {
    case newChat
    /// 帳號頁(#246;右上角帳號鈕):會員、Purrdr Plus 開通步驟、登入方式、刪除會員。
    case member
    /// Purrdr Plus 的付費牆與訂閱摘要(#28)。
    case plus
    /// 第一次開啟的歡迎頁(#34)。
    case welcome

    public var id: String { rawValue }
}
