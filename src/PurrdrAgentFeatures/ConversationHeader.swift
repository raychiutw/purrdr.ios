import Foundation
import PurrdrCore

/// 對話標題列(#270、#618):系統標題(Tab 名稱 `capsuleName`)加系統副標題(只有狀態文字 `subtitle`,不含主機名稱)。
/// 只依輸入推導，不記任何狀態;權限模式不在標題(在「⋯」選單與面板),截斷與無障礙交給系統標題。
public struct ConversationHeader: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case offline
        case working
        case needsYou
        case done
        /// 連得上、agent 閒置或狀態不明。
        case online
    }

    /// Workspace 名稱;還沒讀到 Agent 時是聊天標題。
    public var title: String
    public var status: Status
    /// 狀態之後的段落：主機名(有的話)。
    public var segments: [String]
    /// context 百分比與待辦進度(#307);空的時候不顯示。
    public var progress: AgentProgress
    /// Tab 名稱(#476,snapshot 的 Tab label;預設數字名稱是「Tab N」);還沒讀到 snapshot 是空字串。
    public var tabName: String

    public init(
        title: String, status: Status, segments: [String], progress: AgentProgress = AgentProgress(), tabName: String = ""
    ) {
        self.tabName = tabName
        self.title = title
        self.status = status
        self.segments = segments
        self.progress = progress
    }

    /// 對應列表那組 Agent 狀態符號;離線不是 Agent 狀態(畫 `wifi.slash`),所以是 `nil`。
    public var agentStatus: AgentStatus? {
        switch status {
        case .offline: nil
        case .working: .working
        case .needsYou: .blocked
        case .done: .done
        case .online: .idle
        }
    }

    /// 頂列一行尾端的 context 百分比(「62%」);沒有時為 `nil`。待辦只在狀態 sheet(#349,同一資訊只出現一處)。
    public var progressText: String? {
        progress.contextPercent.map { "\($0)%" }
    }

    /// 系統標題(#476、#618):Tab 名稱;還沒讀到 snapshot 時退回 Workspace 名稱。
    public var capsuleName: String { tabName.isEmpty ? title : tabName }

    /// 系統副標題(#618,使用者定案):只有狀態文字(離線是「Reconnecting…」);不含主機名稱、圓點與權限模式。
    public var subtitle: String { status.title }

    package init(agent: Agent?, title: String, status: AgentStatus?, isOffline: Bool, hostName: String?, progress: AgentProgress = AgentProgress(), tabName: String = "") {
        self.tabName = tabName
        self.progress = progress
        self.title = agent.map(AgentRowText.workspaceName) ?? title
        self.status = if isOffline {
            .offline
        } else {
            switch status {
            case .working: .working
            case .blocked: .needsYou
            case .done: .done
            case .idle, .unknown, nil: .online
            }
        }
        segments = hostName.flatMap { $0.isEmpty ? nil : [$0] } ?? []
    }
}

extension ConversationHeader.Status {
    public var title: String {
        switch self {
        case .offline: String(localized: "Reconnecting…")
        // 與列表共用 Agent 狀態的狀態字。
        case .working: String(localized: AgentStatus.working.title)
        case .needsYou: String(localized: AgentStatus.blocked.title)
        case .done: String(localized: AgentStatus.done.title)
        case .online: String(localized: "Online")
        }
    }
}

/// 工作中指示的經過時間：「12s」「11m 43s」「1h 5m」(行為規格 F5.11)。
public enum WorkingElapsed {
    public static func text(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

extension AgentPermissionMode {
    /// 權限模式的顯示名(面板選項、「⋯」選單、VoiceOver 共用)。
    public var displayName: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .acceptEdits: String(localized: "Accept Edits")
        case .plan: String(localized: "Plan")
        case .bypassPermissions: String(localized: "Bypass Permissions")
        case .auto: String(localized: "Auto")
        case .dontAsk: String(localized: "Don’t Ask")
        }
    }
}
