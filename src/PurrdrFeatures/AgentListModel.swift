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

    /// 即時更新(`run()`),由所有顯示這份列表的視窗共用：iPad 多視窗時只跑一份(#31)。
    @ObservationIgnored public private(set) lazy var liveUpdates = SharedRun { [weak self] in await self?.run() }

    /// 最後一次成功讀到的 snapshot。讀取失敗時保留，列表不會變空。
    public private(set) var snapshot: HostSnapshot?
    private let client: HerdrClient
    private let transcripts: TranscriptReader?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// 使用者取消了 Tailscale 重新驗證：即時更新停下來等「再試一次」(`load()`)。
    /// 與退避的 `retryWaiter` 分開：網路恢復、回到前景(`retryNow()`)不會讓它重連而又跳出驗證。
    private var checkCancelWaiter: CheckedContinuation<Void, Never>?

    /// 所在的主機(列的身分)。
    public let host: HostSelection

    /// - Parameter sleep: 退避與去抖用的等待;測試注入假的。
    public init(
        client: HerdrClient, transcripts: TranscriptReader? = nil, host: HostSelection = .demo,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.host = host
        self.client = client
        self.transcripts = transcripts
        self.sleep = sleep
    }

    /// 依「需要你／工作中／閒置」分組、套用搜尋後的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(snapshot: snapshot, query: query, previews: previews, host: host)
    }

    /// 列表看到的 pane 的 session 參照(id 或路徑;開對話時用來比對快取)。
    /// 列表裡 Claude Code 的 session id → pane id(「You should know」以完整 session id 配對聊天，#23)。
    public var claudeSessionPanes: [String: String] {
        Dictionary((snapshot?.agents ?? []).compactMap { agent in agent.claudeSessionID.map { ($0, agent.paneID) } }) { first, _ in first }
    }

    public func sessionID(ofPane paneID: String) -> String? {
        snapshot?.agents.first { $0.paneID == paneID }?.transcriptTarget?.sessionKey
    }

    /// 主機上有沒有任何 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { snapshot?.agents.isEmpty == false }

    /// 即時更新停著，等使用者按「再試一次」(取消了 Tailscale 重新驗證)。
    public var isWaitingForRetry: Bool { checkCancelWaiter != nil }

    /// 讀一次主機的 snapshot。即時更新因取消 Tailscale 重新驗證而停著時，改為讓它重新開始。
    public func load() async {
        if let checkCancelWaiter {
            self.checkCancelWaiter = nil
            phase = .loading
            checkCancelWaiter.resume()
            return
        }
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
    /// - 使用者取消了 Tailscale 重新驗證：不自動重試(否則每次重試又跳出驗證),等使用者按「再試一次」。
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
            } catch SSHConnectionError.tailscaleCheckCancelled {
                fail(with: SSHConnectionError.tailscaleCheckCancelled)
                await waitForUserRetry()
                if Task.isCancelled { return }
                failures = 0
                needsSnapshot = true
                continue
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
                try await backoff(Self.backoff(afterFailures: failures))
            } catch {
                return
            }
        }
    }

    /// 使用者按「重試」或網路恢復：正在退避就立刻重連;正在連就讓下一次退避直接跳過。
    public func retryNow() {
        if let waiter = retryWaiter {
            retryWaiter = nil
            waiter.resume()
        } else {
            retryRequested = true
        }
    }

    private var retryRequested = false
    private var retryWaiter: CheckedContinuation<Void, Never>?

    /// 退避等待：時間到，或有人要求立刻重試。
    private func backoff(_ duration: Duration) async throws {
        if retryRequested {
            retryRequested = false
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [sleep] in try await sleep(duration) }
            group.addTask { await self.waitForRetry() }
            try await group.next()
            group.cancelAll()
        }
    }

    /// 等使用者按「再試一次」(`load()`);所在的 task 被取消時也結束。
    private func waitForUserRetry() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    checkCancelWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeCheckCancelWaiter() }
        }
    }

    private func resumeCheckCancelWaiter() {
        let waiter = checkCancelWaiter
        checkCancelWaiter = nil
        waiter?.resume()
    }

    private func waitForRetry() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    retryWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRetryWait() }
        }
    }

    private func cancelRetryWait() {
        retryWaiter?.resume()
        retryWaiter = nil
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
        case is SSHConnectionError:
            phase = .failed(HostErrorText.message(for: error))
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
    /// 列表上的狀態(`input_pending` 已折算成 `blocked`)。
    public var status: AgentStatus

    /// 主機身分 + pane id:不同主機的同一個 pane id 是不同的列(也是 UI 測試的 `agent.row.<id>`)。
    public var id: String { "\(host.storedValue)/\(paneID)" }
    public var route: ChatRoute { ChatRoute(host: host, paneID: paneID) }

    public init(
        host: HostSelection = .demo, paneID: String, kind: String = "claude", title: String, subtitle: String,
        hostLabel: HostLabel? = nil, preview: Preview, time: Time?, status: AgentStatus
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
