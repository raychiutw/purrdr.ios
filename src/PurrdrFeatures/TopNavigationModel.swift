import Foundation
import Observation
import PurrdrCore

/// 一個視窗的導覽狀態(#37 故事 21、#31):Agent 列表之上以 sheet 開啟的畫面、三欄的選取、鍵盤快捷鍵。
///
/// 不採 tab bar:列表工具列的「⋯」選單進入設定與主機，「+」新增對話;一次只開一個 sheet。
/// iPad 多視窗時每個視窗各一份(由 `TopNavigationView` 持有);主機清單與選取中主機(`HostsModel`)是全 app 共用的。
@MainActor
@Observable
public final class TopNavigationModel {
    /// 目前開著的 sheet;`nil` 表示停在 Agent 列表。
    public var sheet: TopLevelSheet?
    /// 等著匯入的主機分享連結(`purrdr://host?d=…`)。主機 sheet 開啟時帶入新增主機編輯器，之後清掉。
    public var pendingHostImport: URL?

    /// 對話欄顯示的 Agent(pane id)。iPhone 與窄視窗時是推入的對話。
    public var selectedChat: String? {
        // 一次只有一個詳細(行為規格 F20):換聊天時，前一個聊天推入的終端機收起。
        didSet { if selectedChat != oldValue { openedTerminal = nil } }
    }

    /// 搜尋欄是否有焦點(Command-F)。
    public var isSearchFocused = false
    /// 對話欄推入的 Pane 終端機(pane id)。
    public var openedTerminal: String?
    /// 側欄選的 workspace;`nil` 是所有 workspace。
    public var workspaceFilter: String?
    /// iPad 的版面圖浮動卡片。
    public let layoutCard = LayoutCardModel()

    public init() {}

    /// 套用側欄 workspace 篩選後的列表;空的分組不顯示。篩選的 workspace 已不在主機上時(被關掉了)顯示全部。
    public func visibleSections(_ sections: [AgentSection], snapshot: HostSnapshot?) -> [AgentSection] {
        guard let workspaceFilter, let snapshot, snapshot.workspaces.contains(where: { $0.id == workspaceFilter }) else {
            return sections
        }
        let panes = Set(snapshot.agents.filter { $0.workspaceID == workspaceFilter }.map(\.paneID))
        return sections.compactMap { section in
            let rows = section.rows.filter { panes.contains($0.id) }
            return rows.isEmpty ? nil : AgentSection(group: section.group, rows: rows)
        }
    }

    /// 列表看得到的 Agent(pane id),依畫面順序。鍵盤切換 Agent 用。
    public func visibleAgents(_ sections: [AgentSection], snapshot: HostSnapshot?) -> [String] {
        visibleSections(sections, snapshot: snapshot).flatMap { $0.rows.map(\.id) }
    }

    /// 換了選取中主機：這個視窗的篩選與選取都屬於前一台主機，清掉。
    public func hostChanged() {
        workspaceFilter = nil
        selectedChat = nil
        openedTerminal = nil
        layoutCard.close()
    }

    /// 執行鍵盤快捷鍵。`visibleAgents` 是列表目前看得到的 Agent(pane id),依畫面順序。
    public func perform(_ command: KeyboardCommand, visibleAgents: [String]) {
        switch command {
        case .nextAgent: selectAdjacentAgent(offset: 1, in: visibleAgents)
        case .previousAgent: selectAdjacentAgent(offset: -1, in: visibleAgents)
        case .search: isSearchFocused = true
        case .openTerminal: if let selectedChat { openedTerminal = selectedChat }
        case .newChat: sheet = .newChat
        case .settings: sheet = .settings
        }
    }

    /// 依列表順序選上／下一個 Agent;到頭或到底就停住(不繞回)。選取的 Agent 不在列表上時，從頭(或尾)開始。
    private func selectAdjacentAgent(offset: Int, in agents: [String]) {
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
            sheet = .settings
        case "host":
            // 系統相機掃 QR code 或點分享連結都會走到這裡;內容在主機 sheet 裡解析與說明。
            pendingHostImport = url
            sheet = .hosts
        default:
            return false
        }
        return true
    }

    /// app 註冊的 URL scheme(app 的 Info.plist `CFBundleURLTypes` 要一致)。
    public static let urlScheme = "purrdr"
}

/// 從 Agent 列表開啟的頂層 sheet。
public enum TopLevelSheet: String, Identifiable, Sendable {
    case settings
    case hosts
    case newChat
    /// 會員(登入、登入方式、刪除會員,#27)。設定頁(#32)做好後可改從設定進入。
    case member
    /// Purrdr Plus 的付費牆與訂閱摘要(#28)。
    case plus

    public var id: String { rawValue }
}
