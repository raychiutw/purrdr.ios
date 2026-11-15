import Foundation
import Observation
import PurrdrCore

/// Agent 列表畫面的 model。
@MainActor
@Observable
public final class AgentListModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// 搜尋字串。空白時列出全部。
    public var query = ""
    /// 各 Agent(以 pane id)對話中最後一則訊息。來源是對話紀錄，由對話閱讀(#12)提供。
    public var previews: [String: MessagePreview] = [:]

    /// 最後一次成功讀到的 snapshot。讀取失敗時保留，列表不會變空。
    public private(set) var snapshot: HostSnapshot?
    private let client: HerdrClient
    private let transcripts: TranscriptReader?
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter sleep: 退避與去抖用的等待;測試注入假的。
    public init(
        client: HerdrClient, transcripts: TranscriptReader? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.transcripts = transcripts
        self.sleep = sleep
    }

    /// 依「需要你／工作中／閒置」分組、套用搜尋後的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(snapshot: snapshot, query: query, previews: previews)
    }

    /// 列表看到的 pane 的 session 參照(id 或路徑;開對話時用來比對快取)。
    public func sessionID(ofPane paneID: String) -> String? {
        snapshot?.agents.first { $0.paneID == paneID }?.transcriptTarget?.sessionKey
    }

    /// 主機上有沒有任何 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { snapshot?.agents.isEmpty == false }

    /// 讀一次主機的 snapshot。
    public func load() async {
        do {
            try await refresh()
        } catch {
            fail(with: error)
        }
    }

    /// 即時更新，直到所在的 task 被取消(行為規格 §3.7)。只在畫面可見、app 在前景時執行。
    ///
    /// - 先讀 snapshot 得知有哪些 Agent pane,再訂閱每個 pane 的狀態改變與全主機事件。
    /// - 事件不重播，所以訂閱開始(ack)時重讀一次對帳;之後事件只當「重讀」的觸發，不把內容套到列表上。
    ///   事件是依序處理的，重讀進行中到達的事件會在讀完後再觸發一次。
    /// - `events_lost`:快取已過期，立刻重新訂閱並重讀。
    /// - 重讀後 Agent pane 的集合變了：訂閱不能修改，關掉舊的、用新集合重新訂閱。
    /// - 其他失敗(含訂閱在 ack 前就結束):退避 1 秒起倍增、上限 30 秒;收到 ack 即歸零。
    public func run() async {
        var failures = 0
        var needsSnapshot = true
        while !Task.isCancelled {
            var resubscribeNow = false
            do {
                if needsSnapshot { try await refresh() }
                needsSnapshot = false
                let panes = agentPaneIDs
                let events = try await client.subscribe(panes.map(EventSubscription.agentStatusChanged) + EventSubscription.hostWide)
                for try await event in events {
                    if case .event = event { try await sleep(Self.debounce) }
                    if event == .subscriptionStarted { failures = 0 }
                    try await refresh()
                    if Set(agentPaneIDs) != Set(panes) {
                        resubscribeNow = true
                        break
                    }
                }
            } catch HerdrError.herdr(code: "events_lost", _) {
                needsSnapshot = true
                resubscribeNow = true
            } catch {
                if Task.isCancelled { return }
                fail(with: error)
                needsSnapshot = true
            }
            if Task.isCancelled { return }
            guard !resubscribeNow else { continue }
            // 主機那端結束了串流，或失敗:退避後重連。
            failures += 1
            needsSnapshot = true
            do {
                try await sleep(Self.backoff(afterFailures: failures))
            } catch {
                return
            }
        }
    }

    /// 事件去抖：連續的事件只觸發一次重讀的機會變大，也不會讓列表跳動得太頻繁。
    static let debounce: Duration = .milliseconds(250)

    /// 1 秒起倍增、上限 30 秒。
    static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(failures - 1, 5)))
    }

    private var agentPaneIDs: [String] { snapshot?.agents.map(\.paneID) ?? [] }

    private func refresh() async throws {
        snapshot = try await client.snapshot()
        phase = .loaded
        await refreshPreviews()
    }

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

    private func fail(with error: any Error) {
        switch error {
        case HerdrError.herdr(_, let message):
            // 未知碼保留 herdr 原文(行為規格 §3.8)。
            phase = .failed(message)
        default:
            phase = .failed(String(localized: "Couldn’t read this host’s herdr status."))
        }
    }
}

/// 列表的分組：依「需要你／工作中／閒置」排列，最需要使用者處理的在最上面。
public enum AgentGroup: CaseIterable, Sendable {
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
    /// Pane id。
    public var id: String
    public var title: String
    public var subtitle: String
    public var preview: Preview
    public var time: Time?
    /// 列表上的狀態(`input_pending` 已折算成 `blocked`)。
    public var status: AgentStatus

    public init(id: String, title: String, subtitle: String, preview: Preview, time: Time?, status: AgentStatus) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.time = time
        self.status = status
    }

    /// 預覽行(行為規格 F2.4)。
    public enum Preview: Equatable, Sendable {
        /// 「需要你」:等待你的輸入。
        case needsInput
        /// 最後一則訊息;`fromYou` 為使用者自己送出的。
        case message(String, fromYou: Bool)
        /// 沒有訊息時顯示狀態字。
        case status(AgentStatus)
    }

    /// 右欄時間。
    public enum Time: Equatable, Sendable {
        /// 工作中：「現在」。
        case now
        /// 最後一則訊息的時間。
        case date(Date)
    }
}
