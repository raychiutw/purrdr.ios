import Foundation
import Observation
import PurrdrCore

/// Agent 列表畫面的 model。快照與即時更新來自這台主機的主機更新來源(`HostUpdates`,#160)。
@MainActor
@Observable
public final class AgentListModel {
    public typealias Phase = HostUpdates.Phase

    /// 搜尋字串。空白時列出全部。
    public var query = ""
    /// 各 Agent(以 pane id)對話中最後一則訊息。來源是對話紀錄，由對話閱讀(#12)提供。
    public var previews: [String: MessagePreview] = [:]

    /// 這台主機的主機更新來源。
    public let updates: HostUpdates
    private let transcripts: TranscriptReader?

    /// 所在的主機(列的身分)。
    public let host: HostSelection

    /// - Parameter sleep: 退避用的等待;測試注入假的。
    public convenience init(
        client: HerdrClient, transcripts: TranscriptReader? = nil, host: HostSelection = .demo,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.init(updates: HostUpdates(client: client, sleep: sleep), transcripts: transcripts, host: host)
    }

    public init(updates: HostUpdates, transcripts: TranscriptReader? = nil, host: HostSelection = .demo) {
        self.updates = updates
        self.transcripts = transcripts
        self.host = host
        updates.afterSnapshot = { [weak self] in await self?.refreshPreviews() }
    }

    public var phase: Phase { updates.phase }

    /// 最後一次成功讀到的 snapshot。讀取失敗時保留，列表不會變空。
    public var snapshot: HostSnapshot? { updates.snapshot }

    /// 即時更新，由所有顯示這份列表的視窗共用(#31)。
    public var liveUpdates: SharedRun { updates.liveUpdates }

    /// 即時更新要不要訂閱版面事件(#40:只有 Spaces 檢視要)。
    public var subscribesToLayout: Bool {
        get { updates.subscribesToLayout }
        set { updates.subscribesToLayout = newValue }
    }

    /// 依「需要你／工作中／閒置」分組、套用搜尋後的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(snapshot: snapshot, query: query, previews: previews, host: host)
    }

    /// 列表裡 Claude Code 的 session id → pane id(「You should know」以完整 session id 配對聊天，#23)。
    public var claudeSessionPanes: [String: String] {
        Dictionary((snapshot?.agents ?? []).compactMap { agent in agent.claudeSessionID.map { ($0, agent.paneID) } }) { first, _ in first }
    }

    /// 列表看到的 pane 的 session 參照(id 或路徑;開對話時用來比對快取)。
    public func sessionID(ofPane paneID: String) -> String? {
        snapshot?.agents.first { $0.paneID == paneID }?.transcriptTarget?.sessionKey
    }

    /// 主機上有沒有任何 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { snapshot?.agents.isEmpty == false }

    /// 即時更新停著，等使用者按「再試一次」(取消了 Tailscale 重新驗證)。
    public var isWaitingForRetry: Bool { updates.isWaitingForRetry }

    /// 讀一次主機的 snapshot。即時更新因取消 Tailscale 重新驗證而停著時，改為讓它重新開始。
    public func load() async { await updates.load() }

    /// 即時更新，直到所在的 task 被取消。只在畫面可見、app 在前景時執行。
    public func run() async { await updates.run() }

    /// 使用者按「重試」或網路恢復：正在退避就立刻重連。
    public func retryNow() { updates.retryNow() }

    /// 各 pane 的預覽是讀哪個 session 時取得的(R-I04)。
    private var previewSessions: [String: String] = [:]

    /// 以一次往返讀所有可讀 agent(Claude、Grok、agy、Pi／OMP)對話紀錄的檔尾，更新預覽與時間(行為規格 §4.7)。
    /// 預覽帶讀取時的 session:pane 離開或 session 改變(herdr 回收 pane 給新聊天)就丟(R-I04)。讀取失敗保留現有預覽。
    private func refreshPreviews() async {
        guard let transcripts, let snapshot else { return }
        let sessions = Dictionary(
            snapshot.agents.compactMap { agent in agent.transcriptTarget.map { (agent.paneID, $0.sessionKey) } },
            uniquingKeysWith: { first, _ in first }
        )
        previews = previews.filter { sessions[$0.key] != nil && previewSessions[$0.key] == sessions[$0.key] }
        let requests = snapshot.agents.compactMap { agent in
            agent.transcriptTarget.map { PreviewRequest(key: agent.paneID, target: $0) }
        }
        guard !requests.isEmpty, let fresh = try? await transcripts.previews(of: requests) else { return }
        for (paneID, preview) in fresh {
            previews[paneID] = preview
            previewSessions[paneID] = sessions[paneID]
        }
    }
}

/// 列表的分組：依「已釘選／需要你／工作中／閒置」排列(行為規格 F2.2)。
/// 釘選優先於狀態：已釘選的列不因狀態改變而跳組;其餘最需要使用者處理的在最上面。
public enum AgentGroup: CaseIterable, Sendable {
    case pinned
    case needsYou
    case working
    case idle
}

public struct AgentSection: Identifiable, Equatable, Sendable {
    public var group: AgentGroup
    public var rows: [AgentRow]
    public var id: AgentGroup { group }

    public init(group: AgentGroup, rows: [AgentRow]) {
        self.group = group
        self.rows = rows
    }
}

/// 列表的一列。
public struct AgentRow: Identifiable, Equatable, Sendable {
    /// 所在的主機。
    public var host: HostSelection
    public var paneID: String
    /// agent 種類(herdr 原文);列左側的圖示依它。
    public var kind: String
    public var title: String
    /// 非選取中主機的列以主機名開頭(#37 故事 2)。
    public var subtitle: String
    /// 非選取中主機的列：主機名與圖示;選取中主機為 `nil`。
    public var hostLabel: HostLabel?
    public var preview: Preview
    public var time: Time?
    /// 列表上的狀態(`input_pending` 已折算成 `blocked`;未讀的回覆是 `done`、已讀是 `idle`,行為規格 F2.5)。
    public var status: AgentStatus
    /// 有還沒讀過的回覆(行為規格 F2.6)。
    public var isUnread: Bool
    /// 已釘選、已靜音(標題後的小圖示)。
    public var isPinned: Bool
    public var isMuted: Bool

    /// 主機身分 + pane id:不同主機的同一個 pane id 是不同的列(也是 UI 測試的 `agent.row.<id>`)。
    public var id: String { "\(host.storedValue)/\(paneID)" }
    public var route: ChatRoute { ChatRoute(host: host, paneID: paneID) }

    public init(
        host: HostSelection = .demo, paneID: String, kind: String = "claude", title: String, subtitle: String,
        hostLabel: HostLabel? = nil, preview: Preview, time: Time?, status: AgentStatus,
        isUnread: Bool = false, isPinned: Bool = false, isMuted: Bool = false
    ) {
        self.host = host
        self.paneID = paneID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.hostLabel = hostLabel
        self.preview = preview
        self.time = time
        self.status = status
        self.isUnread = isUnread
        self.isPinned = isPinned
        self.isMuted = isMuted
    }

    /// 預覽行(行為規格 F2.4)。
    public enum Preview: Equatable, Sendable {
        /// 「需要你」:等待你的輸入。
        case needsInput
        /// 最後一則訊息;`fromYou` 為使用者自己送出的。
        case message(String, fromYou: Bool)
        /// 沒有訊息：不顯示預覽行(狀態字已在列尾的狀態標籤，不重複，#35)。
        case none
    }

    /// 右欄時間。
    public enum Time: Equatable, Sendable {
        /// 工作中：「現在」。
        case now
        /// 最後一則訊息的時間。
        case date(Date)
    }
}
