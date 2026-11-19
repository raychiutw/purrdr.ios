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
    private let sleep: Sleep

    /// 所在的主機(列的身分)。
    public let host: HostSelection

    /// - Parameter sleep: 退避用的等待;測試注入假的。
    public convenience init(
        client: HerdrClient, transcripts: TranscriptReader? = nil, host: HostSelection = .demo,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.init(updates: HostUpdates(client: client, sleep: sleep), transcripts: transcripts, host: host, sleep: sleep)
    }

    /// - Parameter sleep: 預覽定期更新的等待;測試注入假的。
    public init(updates: HostUpdates, transcripts: TranscriptReader? = nil, host: HostSelection = .demo, sleep: @escaping Sleep = Sleeping.task) {
        self.updates = updates
        self.transcripts = transcripts
        self.host = host
        self.sleep = sleep
    }

    public var phase: Phase { updates.phase }

    /// 最後一次成功讀到的 snapshot。讀取失敗時保留，列表不會變空。
    public var snapshot: HostSnapshot? { updates.snapshot }

    /// 即時更新與預覽，由所有顯示這份列表的視窗共用(#31)。
    @ObservationIgnored public private(set) lazy var liveUpdates = SharedRun { [weak self] in await self?.run() }

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

    /// 讀一次主機的 snapshot 並更新預覽。即時更新因取消 Tailscale 重新驗證而停著時，改為讓它重新開始。
    public func load() async {
        await updates.load()
        await refreshPreviews(namedPanes: [])
    }

    /// 即時更新(與聊天畫面共用主機更新來源)並跟著快照更新預覽，直到所在的 task 被取消。只在畫面可見、app 在前景時執行。
    /// 預覽在快照讀取之外讀(慢的預覽不延後下一份快照);讀取期間到的快照併成讀完後的下一次。
    public func run() async {
        let updates = updates
        guard transcripts != nil else {
            await updates.liveUpdates.attach()
            return
        }
        let previewsDue = WakeSignal(sleep: sleep)
        let snapshotReads = updates.snapshotReads()
        // 聊天畫面已經讓主機更新來源讀到快照：不等下一份。
        if updates.snapshot != nil {
            hasPendingSnapshot = true
            previewsDue.wake()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await updates.liveUpdates.attach() }
            group.addTask {
                for await namedPanes in snapshotReads {
                    await self.noteSnapshotRead(namedPanes: namedPanes)
                    previewsDue.wake()
                }
            }
            while !Task.isCancelled {
                do {
                    try await previewsDue.wait(atMost: Self.workingPreviewInterval)
                } catch {
                    break
                }
                if hasPendingSnapshot {
                    let namedPanes = pendingNamedPanes
                    hasPendingSnapshot = false
                    pendingNamedPanes = []
                    await refreshPreviews(namedPanes: namedPanes)
                } else {
                    await refreshWorkingPreviews()
                }
            }
            group.cancelAll()
        }
    }

    /// 讀到快照後還沒更新預覽。
    @ObservationIgnored private var hasPendingSnapshot = false
    /// 還沒更新預覽的快照讀取裡，事件指名的 pane。
    @ObservationIgnored private var pendingNamedPanes: Set<String> = []

    private func noteSnapshotRead(namedPanes: Set<String>) {
        hasPendingSnapshot = true
        pendingNamedPanes.formUnion(namedPanes)
    }

    /// 時間到(沒有新快照):工作中的 Agent 狀態事件不會來，合併成一個請求帶已知版本重讀，沒變主機只回 unchanged(#205)。
    private func refreshWorkingPreviews() async {
        guard let snapshot else { return }
        await refreshPreviews(namedPanes: Set(snapshot.agents.filter { $0.status == .working }.map(\.paneID)))
    }

    /// 工作中、狀態沒變的 Agent 預覽多久更新一次(列表可見時;狀態事件不會來)。
    package static let workingPreviewInterval: Duration = .seconds(30)

    /// 使用者按「重試」或網路恢復：正在退避就立刻重連。
    public func retryNow() { updates.retryNow() }

    /// 各 pane 的預覽是讀哪個 session 時取得的(R-I04);有值代表這個 session 讀過(即使沒有可讀訊息)。
    private var previewSessions: [String: String] = [:]
    /// 各 pane 讀預覽時的 Agent 狀態;狀態變了才重讀。
    private var previewStatuses: [String: AgentStatus] = [:]
    /// 各 pane 上次讀到的對話紀錄版本(下次讀預覽時帶回)。
    @ObservationIgnored private var previewVersions: [String: PreviewVersion] = [:]
    /// 已經成功讀過一次全部的預覽。
    private var hasReadAllPreviews = false

    /// 讀對話紀錄檔尾更新預覽與時間(行為規格 §4.7):第一次以一次往返讀全部可讀 agent;之後只讀狀態變了、
    /// 事件指名或還沒讀過這個 session 的 Agent,合併成一次往返(#164)。
    /// 預覽帶讀取時的 session:pane 離開或 session 改變(herdr 回收 pane 給新聊天)就丟(R-I04)。讀取失敗保留現有預覽。
    private func refreshPreviews(namedPanes: Set<String>) async {
        guard let transcripts, let snapshot else { return }
        let agents = snapshot.agents.filter { $0.transcriptTarget != nil }
        let sessions = Dictionary(
            agents.compactMap { agent in agent.transcriptTarget.map { (agent.paneID, $0.sessionKey) } },
            uniquingKeysWith: { first, _ in first }
        )
        let statuses = Dictionary(agents.map { ($0.paneID, $0.status) }, uniquingKeysWith: { first, _ in first })
        previewSessions = previewSessions.filter { sessions[$0.key] == $0.value }
        previews = previews.filter { previewSessions[$0.key] != nil }
        previewVersions = previewVersions.filter { previewSessions[$0.key] != nil }
        let requests = agents.compactMap { agent in
            agent.transcriptTarget.map { target in
                var request = PreviewRequest(key: agent.paneID, target: target)
                request.knownVersion = previewVersions[agent.paneID]
                return request
            }
        }
        guard !requests.isEmpty else { return }
        guard hasReadAllPreviews else {
            hasReadAllPreviews = await readPreviews(requests, using: transcripts, sessions: sessions, statuses: statuses)
            return
        }
        let stale = requests.filter { request in
            namedPanes.contains(request.key) || previewSessions[request.key] == nil || previewStatuses[request.key] != statuses[request.key]
        }
        guard !stale.isEmpty else { return }
        await readPreviews(stale, using: transcripts, sessions: sessions, statuses: statuses)
    }

    /// 讀一批預覽;成功時記下讀取時的 session、狀態與版本(沒有可讀訊息的也算讀過;沒變或新內容沒有可讀訊息時保留預覽)。
    @discardableResult
    private func readPreviews(
        _ requests: [PreviewRequest], using transcripts: TranscriptReader, sessions: [String: String], statuses: [String: AgentStatus]
    ) async -> Bool {
        guard let readings = try? await transcripts.previewReadings(of: requests) else { return false }
        for request in requests {
            if let reading = readings[request.key] {
                previews[request.key] = reading.preview ?? previews[request.key]
                previewVersions[request.key] = reading.version
            }
            previewSessions[request.key] = sessions[request.key]
            previewStatuses[request.key] = statuses[request.key]
        }
        return true
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
