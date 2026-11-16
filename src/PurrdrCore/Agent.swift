import Foundation

/// 在某個 Pane 裡被 herdr 偵測到的 coding agent 程序(GLOSSARY「Agent」)。
public struct Agent: Sendable, Equatable, Identifiable {
    /// Pane id(例如 `w1:pA`)。同一台主機內唯一。
    public var paneID: String
    public var workspaceID: String
    /// agent 種類(`claude`、`codex`…),herdr 回報的原文。
    public var kind: String
    public var status: AgentStatus
    /// `herdr agent rename` 設的名稱。
    public var name: String?
    /// 終端機標題(已去掉狀態符號,`terminal_title_stripped`)。
    public var terminalTitle: String?
    /// session 自己的標題(snapshot 的 `title`)。哪個欄位才是真正的標題依 agent 種類而定(行為規格 F2.4)。
    public var sessionTitle: String?
    /// pane 上有選單在等按鍵，但 herdr 回報的狀態仍是 `idle`(行為規格 §3.5)。herdr 0.9.5 不會送這個欄位。
    public var inputPending: Bool
    /// 所在 Workspace 的名稱。
    public var workspaceLabel: String?
    /// 工作目錄。
    public var cwd: String?
    /// herdr integration 回報的 session 參照(snapshot 的 `agent_session`)。聊天的身分是它，不是 pane(行為規格 F5.1)。
    public var session: AgentSessionReference?
    /// 所在的 Tab。
    public var tabID: String?

    /// session 的值：本機的釘選、靜音以它為 key。沒有 session 時為 `nil`。
    public var sessionID: String? { session?.value }

    public var id: String { paneID }

    public init(
        paneID: String, workspaceID: String, kind: String, status: AgentStatus,
        name: String? = nil, terminalTitle: String? = nil, sessionTitle: String? = nil, inputPending: Bool = false,
        workspaceLabel: String? = nil, cwd: String? = nil, session: AgentSessionReference? = nil, tabID: String? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.kind = kind
        self.status = status
        self.name = name
        self.terminalTitle = terminalTitle
        self.sessionTitle = sessionTitle
        self.inputPending = inputPending
        self.workspaceLabel = workspaceLabel
        self.cwd = cwd
        self.session = session
        self.tabID = tabID
    }
}

/// herdr 回報的 agent session 參照(`agent_session`)。`kind` 為 `id` 時 `value` 是 agent 原生的 session id;
/// 為 `path` 時是對話紀錄的絕對路徑(行為規格 §4.0)。
public struct AgentSessionReference: Sendable, Equatable, Hashable, Codable {
    public var kind: String
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// herdr 回報的 Agent 狀態(GLOSSARY「Agent 狀態」)。不認得的值一律當 `unknown`。
public enum AgentStatus: String, Sendable, Equatable, CaseIterable {
    /// UI 上稱「需要你」。
    case blocked
    case working
    case done
    case idle
    case unknown
}

/// herdr 的 Workspace(GLOSSARY)。
public struct Workspace: Sendable, Equatable, Identifiable {
    /// Workspace id(例如 `w1`)。
    public var id: String
    /// 在主機上的順序(herdr 側欄由上而下)。
    public var number: Int
    public var label: String?
    /// 作用中的 Tab。
    public var activeTabID: String?

    public init(id: String, number: Int, label: String?, activeTabID: String? = nil) {
        self.id = id
        self.number = number
        self.label = label
        self.activeTabID = activeTabID
    }
}

/// 一次 `session.snapshot` 的結果(目前只取 Agent 列表與 Spaces 版面圖需要的部分)。
public struct HostSnapshot: Sendable, Equatable {
    /// herdr 伺服器版本。
    public var version: String
    public var workspaces: [Workspace]
    public var agents: [Agent]
    public var tabs: [Tab]
    /// 所有 pane,含 agent 以外的終端機。
    public var panes: [Pane]
    /// 各 tab 的版面。herdr 沒回報(欄位缺席)時為 `nil`,與「真的沒有」的空陣列不同。
    public var layouts: [TabLayout]?

    public init(
        version: String, workspaces: [Workspace] = [], agents: [Agent],
        tabs: [Tab] = [], panes: [Pane] = [], layouts: [TabLayout]? = nil
    ) {
        self.version = version
        self.workspaces = workspaces
        self.agents = agents
        self.tabs = tabs
        self.panes = panes
        self.layouts = layouts
    }
}

/// 一個 Agent 對話中最後一則訊息的摘要(列表的預覽行與時間)。來源是對話紀錄。
public struct MessagePreview: Sendable, Equatable {
    public var text: String
    /// 訊息時間。對話紀錄沒有時間時為 `nil`。
    public var date: Date?
    /// 是使用者自己送出的訊息。
    public var isFromUser: Bool

    public init(text: String, date: Date?, isFromUser: Bool) {
        self.text = text
        self.date = date
        self.isFromUser = isFromUser
    }
}

/// 新建的 workspace(`worktree.create` 的結果):之後在它的 root pane 開聊天或終端機。
public struct CreatedWorkspace: Sendable, Equatable {
    public var workspaceID: String
    public var rootPaneID: String

    public init(workspaceID: String, rootPaneID: String) {
        self.workspaceID = workspaceID
        self.rootPaneID = rootPaneID
    }
}
