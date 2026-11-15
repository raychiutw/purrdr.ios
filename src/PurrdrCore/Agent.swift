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
    /// 終端機標題(已去掉狀態符號)。Claude Code 會把 session 標題寫在這裡。
    public var terminalTitle: String?
    /// 所在 Workspace 的名稱。
    public var workspaceLabel: String?
    /// 工作目錄。
    public var cwd: String?

    public var id: String { paneID }

    public init(
        paneID: String, workspaceID: String, kind: String, status: AgentStatus,
        name: String? = nil, terminalTitle: String? = nil, workspaceLabel: String? = nil, cwd: String? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.kind = kind
        self.status = status
        self.name = name
        self.terminalTitle = terminalTitle
        self.workspaceLabel = workspaceLabel
        self.cwd = cwd
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

/// 一次 `session.snapshot` 的結果(目前只取 Agent 列表需要的部分)。
public struct HostSnapshot: Sendable, Equatable {
    /// herdr 伺服器版本。
    public var version: String
    public var agents: [Agent]

    public init(version: String, agents: [Agent]) {
        self.version = version
        self.agents = agents
    }
}
