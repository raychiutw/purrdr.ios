import Foundation
import Observation
import PurrdrCore

/// 離線佇列裡的一則訊息(#301)。
public struct QueuedPrompt: Codable, Equatable, Sendable, Identifiable {
    /// 重連後沒有補送的原因(泡泡紅框，下方寫原因與「放回輸入框」「刪除」)。
    public enum Problem: String, Codable, Sendable {
        /// 排隊超過 10 分鐘。
        case expired
        /// 對象的 pane 不在了、換了 Workspace,或 session 換了。
        case conversationChanged
        /// Agent 在等你回答(「需要你」):什麼都沒送出。
        case needsAnswer
        /// 主機拒絕了：什麼都沒送出。
        case notDelivered
        /// 送了但無法確認：可能已經送到，不自動重送(§7.3)。
        case mayHaveBeenSent
    }

    public let id: UUID
    public let text: String
    public let paneID: String
    public let workspaceID: String?
    /// 按下送出時的 session;重連後換了就不補送。
    public let sessionID: String?
    public let createdAt: Date
    /// 沒有補送的原因;還在排隊時是 `nil`。
    public var problem: Problem?

    public init(
        id: UUID = UUID(), text: String, paneID: String, workspaceID: String?, sessionID: String?, createdAt: Date,
        problem: Problem? = nil
    ) {
        self.id = id
        self.text = text
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.problem = problem
    }
}

/// 離線佇列存在本機(App 重開仍在);每台主機一份。
@MainActor
public protocol OfflineQueueStore: AnyObject {
    func load(host: String) -> [QueuedPrompt]
    func save(_ prompts: [QueuedPrompt], host: String)
}

/// 只在記憶體(測試、UI 測試)。
@MainActor
public final class InMemoryOfflineQueueStore: OfflineQueueStore {
    private var stored: [String: [QueuedPrompt]] = [:]

    public init() {}

    public func load(host: String) -> [QueuedPrompt] { stored[host] ?? [] }
    public func save(_ prompts: [QueuedPrompt], host: String) { stored[host] = prompts }
}

/// 存放離線佇列內容的位置(Seam:正式是 Keychain,測試是記憶體);內容是 JSON。
public protocol OfflineQueueBlobStore: AnyObject, Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
}

/// 舊版存在 `UserDefaults` 的資料(只讀取與刪除，用來遷移)。
public protocol LegacyOfflineQueueSource: Sendable {
    func data(host: String) -> Data?
    func remove(host: String)
}

/// 離線佇列存在不進備份的位置;第一次載入時把舊版 `UserDefaults` 的資料遷移過來並刪除。
@MainActor
public final class ProtectedOfflineQueueStore: OfflineQueueStore {
    public init(blobs: any OfflineQueueBlobStore, legacy: any LegacyOfflineQueueSource) {}

    public func load(host: String) -> [QueuedPrompt] { [] }
    public func save(_ prompts: [QueuedPrompt], host: String) {}
}

/// 一台主機的離線佇列(#301,spec #298):沒有連線時送出的訊息先排在這裡(每台主機最多 30 則，存本機)。
///
/// 訊息只在離線時進來，所以之後收到的第一份 Agent 列表(`reconcile(with:)`)就是重連後的第一次:逐則比對，
/// pane 還在同一個 Workspace、session 沒換、排隊不到 10 分鐘才依序補送;否則不送，標上原因(`QueuedPrompt.problem`),
/// 留給使用者「放回輸入框」或「刪除」。標了原因的不再自動送出。
@MainActor
@Observable
public final class OfflineQueue {
    /// 每台主機最多排幾則。
    public static let limit = 30
    /// 排隊超過這麼久就不補送(對話可能已經往前走了)。
    public static let maximumAge: TimeInterval = 10 * 60

    /// 依排入順序。
    public private(set) var entries: [QueuedPrompt]

    @ObservationIgnored private let host: String
    @ObservationIgnored private let store: any OfflineQueueStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let deliver: @MainActor (String, Agent, String?) async -> PromptOutcome
    @ObservationIgnored private var reconciling: Task<Void, Never>?

    /// - Parameters:
    ///   - host: 這台主機在本機存放的 key(`HostSelection.storedValue`)。
    ///   - deliver: 補送一則給 Agent,第三個參數是排入時的 session(由建立者以新鮮的快照與 `PromptDelivery` 實作)。
    public init(
        host: String, store: any OfflineQueueStore, now: @escaping @Sendable () -> Date = Date.init,
        deliver: @escaping @MainActor (String, Agent, String?) async -> PromptOutcome
    ) {
        self.host = host
        self.store = store
        self.now = now
        self.deliver = deliver
        entries = store.load(host: host)
    }

    public var isFull: Bool { entries.count >= Self.limit }

    /// 某個 pane 的訊息(聊天畫面畫在對話最下面)。
    public func entries(forPane paneID: String) -> [QueuedPrompt] {
        entries.filter { $0.paneID == paneID }
    }

    /// 排入一則;滿了回 `false`(不收)。
    @discardableResult
    public func enqueue(_ prompt: OutgoingPrompt) -> Bool {
        guard !isFull else { return false }
        entries.append(QueuedPrompt(
            text: prompt.text, paneID: prompt.paneID, workspaceID: prompt.workspaceID, sessionID: prompt.expectedSession,
            createdAt: prompt.createdAt))
        save()
        return true
    }

    /// 取消(還在排隊)或刪除(沒送出)一則。
    public func remove(_ id: QueuedPrompt.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// 放回輸入框：從佇列拿掉，回傳文字。
    public func takeBack(_ id: QueuedPrompt.ID) -> String? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        remove(id)
        return entry.text
    }

    /// 收到一份 Agent 列表(主機更新來源或聊天自己讀的快照):有排隊中的訊息就比對、補送。同時只跑一次。
    public func receive(_ snapshot: HostSnapshot) {
        guard reconciling == nil, entries.contains(where: { $0.problem == nil }) else { return }
        reconciling = Task { [weak self] in
            await self?.reconcile(with: snapshot)
            self?.reconciling = nil
        }
    }

    /// 等 `receive(_:)` 開始的比對做完(測試)。
    public func waitUntilIdle() async {
        await reconciling?.value
    }

    /// 以重連後的 Agent 列表逐則比對：符合的依序補送，送到就移出;不符合或沒送到的標上原因。
    public func reconcile(with snapshot: HostSnapshot) async {
        let current = now()
        // 逐則比對;但同一個 pane 前一則補送時沒送到，後面的也不送(順序不能亂)。
        var stoppedPanes: [String: QueuedPrompt.Problem] = [:]
        for entry in entries where entry.problem == nil {
            let problem: QueuedPrompt.Problem?
            if let stopped = stoppedPanes[entry.paneID] {
                problem = stopped
            } else if current.timeIntervalSince(entry.createdAt) >= Self.maximumAge {
                problem = .expired
            } else if let agent = matchingAgent(for: entry, in: snapshot) {
                problem = await send(entry, to: agent)
                if let problem { stoppedPanes[entry.paneID] = problem }
            } else {
                problem = .conversationChanged
            }
            // 補送期間使用者可能取消了這則。
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            if let problem {
                entries[index].problem = problem
            } else {
                entries.remove(at: index)
            }
            save()
        }
    }

    /// pane 還在同一個 Workspace,session 沒換(Agent 還沒回報 session 時不擋，與送出時的確認相同)。
    private func matchingAgent(for entry: QueuedPrompt, in snapshot: HostSnapshot) -> Agent? {
        guard let agent = snapshot.agents.first(where: { $0.paneID == entry.paneID }) else { return nil }
        if let workspace = entry.workspaceID, agent.workspaceID != workspace { return nil }
        if let expected = entry.sessionID, let session = agent.sessionID, session != expected { return nil }
        return agent
    }

    /// 補送一則;送到回 `nil`。
    private func send(_ entry: QueuedPrompt, to agent: Agent) async -> QueuedPrompt.Problem? {
        switch await deliver(entry.text, agent, entry.sessionID) {
        case .delivered, .submittedCommand: nil
        case .noResponse, .unconfirmed: .mayHaveBeenSent
        case .needsAnswer: .needsAnswer
        case .rejected, .readOnlyDevice: .notDelivered
        case .paneChanged: .conversationChanged
        }
    }

    private func save() {
        store.save(entries, host: host)
    }
}

/// 送出管線的離線佇列步驟(#301):輪到它時(撤回倒數結束後)連不上主機，訊息排進這台主機的佇列(輸入框維持清空);
/// 佇列滿了不收，文字放回輸入框。連得上時直接通過。連線狀態在這一刻才問(`SendPipelineClock.isHostReachable`)。
@MainActor
public struct OfflineQueueStep: SendStep {
    public let queue: OfflineQueue

    public init(queue: OfflineQueue) {
        self.queue = queue
    }

    public func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult {
        guard !clock.isHostReachable() else { return .proceed(prompt) }
        return .halt(SendHalt(restoresDraft: !queue.enqueue(prompt)))
    }
}
