/// `events.subscribe` 的一筆訂閱(行為規格 §3.7)。
///
/// 型別只能是 herdr 認得的:任何一個未知型別(或不存在的 pane)會讓 herdr 拒絕整個請求，
/// 所以型別是列舉，不接受任意字串。
public struct EventSubscription: Sendable, Equatable, Hashable {
    public var type: EventType
    /// `pane.agent_status_changed` 必填(沒有萬用字元);其他型別不帶。
    public var paneID: String?

    public init(_ type: EventType, paneID: String? = nil) {
        self.type = type
        self.paneID = paneID
    }

    /// 某個 pane 的 Agent 狀態改變。
    public static func agentStatusChanged(paneID: String) -> EventSubscription {
        EventSubscription(.paneAgentStatusChanged, paneID: paneID)
    }

    /// 不分 pane、整台主機的事件:workspace 的建立／關閉／改名／更新，偵測到新 agent、pane 結束。
    public static let hostWide: [EventSubscription] = [
        .init(.workspaceCreated), .init(.workspaceClosed), .init(.workspaceRenamed), .init(.workspaceUpdated),
        .init(.paneAgentDetected), .init(.paneExited),
    ]

    /// herdr protocol 22 可訂閱的事件型別(實測 `herdr api schema --json`)。目前只列用得到的。
    public enum EventType: String, Sendable, Hashable {
        case workspaceCreated = "workspace.created"
        case workspaceClosed = "workspace.closed"
        case workspaceRenamed = "workspace.renamed"
        case workspaceUpdated = "workspace.updated"
        case paneAgentDetected = "pane.agent_detected"
        case paneExited = "pane.exited"
        case paneAgentStatusChanged = "pane.agent_status_changed"
    }
}

/// 訂閱串流中的一項。事件只當「該重讀了」的訊號，不把內容套到快取上(行為規格 §3.7)。
public enum HerdrEvent: Sendable, Equatable {
    /// herdr 接受了訂閱。此後的事件才看得到;之前發生的要靠重讀 snapshot。
    case subscriptionStarted
    /// 一個事件。`name` 是 wire 上的名稱(例如 `pane_agent_status_changed`);`paneID` 有指名 pane 時才有。
    case event(name: String, paneID: String?)
}
