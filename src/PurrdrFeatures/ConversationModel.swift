import Foundation
import Observation
import PurrdrCore

/// 對話畫面的時鐘(測試注入)。
public struct ConversationClock: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

/// 對話畫面(閱讀)的 model(行為規格 F5)。
///
/// - 聊天的身分是 Agent 的 **session**,不是 pane:herdr 會回收 pane id,session 改變就是另一個聊天(R-I01)。
/// - 沒有 session id 就等待，**永不猜檔**(R-I02)。
/// - 以主機上的 UTF-8 byte 游標增量讀取：開啟讀最後 `openLines` 行，之後每次輪詢只讀游標之後的完整行;
///   落後超過 64KB 或檔案被換掉時重讀視窗(R-B08)。
/// - 往上翻以第一個視窗的起點為錨點，每頁 `pageLines` 行;舊頁不寫入快取(F5.4)。
/// - 主機連不上時唯讀顯示同一 session 的快取並標示離線(R-B16)。
@MainActor
@Observable
public final class ConversationModel {
    public enum Phase: Equatable {
        case loading
        /// 有可讀對話紀錄的 agent,但還沒回報 session。
        case waitingForSession
        /// 等了 80 秒仍沒有 session:無法分辨是哪個對話(integration 可能沒裝)。
        case missingSession
        /// 這種 agent 沒有可讀的對話紀錄。
        case unsupported
        /// 這個 pane 已經沒有 agent。
        case agentGone
        case ready
    }

    /// 對話內的非干擾式標示(HIG 20.5:不在進入畫面時跳 alert)。
    public enum Banner: Equatable {
        /// 主機上的對話紀錄讀不到(權限)。
        case unreadable
        /// 連不上主機;畫面上是上次讀到的內容。
        case offline
        /// 讀取失敗，稍後重試。
        case readFailed
        /// 符合這個 session 的對話紀錄不只一個:不猜(行為規格 §4.3、§4.5)。
        case ambiguous
    }

    public enum Older: Equatable {
        case available
        case loading
        case reachedStart
    }

    public private(set) var phase: Phase = .loading
    public private(set) var items: [ConversationItem] = []
    /// 畫面上是快取的內容(離線)。
    public private(set) var isOffline = false
    public private(set) var banner: Banner?
    public private(set) var older: Older = .reachedStart
    /// 導覽列標題;永不顯示 `w1` 這類 id(R-V10)。
    public private(set) var title = ""
    public private(set) var agentStatus: AgentStatus?
    public private(set) var metadata = TranscriptMetadata()

    public let paneID: String
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    private let cache: any ConversationCache
    private let clock: ConversationClock
    private let openLines: Int
    private let pageLines: Int
    /// 列表傳來的 session:快取只在與它相同時秒開或離線顯示(F5.3、#97)。
    private let knownSessionID: String?

    /// 目前綁定的 session(herdr 回報的 id 或路徑)與讀取狀態。
    private var boundSessionID: String?
    /// 對話紀錄的格式，依 Agent 種類(每次輪詢由 snapshot 更新;還沒輪詢前的快取還原不需要解析)。
    private var format: TranscriptFormat = .claude
    private var file: (path: String, cursor: Int, windowStart: Int)?
    /// 開啟視窗與之後追蹤到的訊息(會寫入快取)。
    private var recent: [TranscriptMessage] = []
    /// 往上翻載入的舊訊息(不寫入快取)。
    private var olderMessages: [TranscriptMessage] = []
    private var waitingSince: Date?
    private var lastPresenceSeq: UInt64 = 0
    /// 每次綁定新 session 遞增;晚到的舊 session 結果直接丟棄(R-B07)。
    private var generation = 0

    public init(
        client: HerdrClient, transcripts: TranscriptReader, paneID: String, knownSessionID: String?,
        cache: any ConversationCache, clock: ConversationClock = ConversationClock(), openLines: Int = 300, pageLines: Int = 200
    ) {
        self.client = client
        self.transcripts = transcripts
        self.paneID = paneID
        self.knownSessionID = knownSessionID
        self.cache = cache
        self.clock = clock
        self.openLines = openLines
        self.pageLines = pageLines
    }

    /// 快取 key。目前一個聊天對應一個 pane;多 agent 的 workspace 聊天(合併多個 pane)是之後的票。
    private var chatKey: String { paneID }

    // MARK: - 開啟

    /// 列表傳來的 session 與快取相同時，立刻顯示快取並從游標續讀(F5.3 第 1 點)。
    public func restoreFromCache() async {
        guard let knownSessionID, items.isEmpty, let cached = await cache.load(chatKey: chatKey),
              cached.matches(sessionID: knownSessionID) else { return }
        boundSessionID = knownSessionID
        file = (cached.path, cached.cursor, cached.windowStart)
        recent = cached.messages
        metadata = cached.metadata
        older = cached.windowStart > 0 ? .available : .reachedStart
        phase = .ready
        rebuild()
    }

    // MARK: - 輪詢

    /// 畫面可見且 app 在前景時執行，直到所在的 task 被取消。agent 工作中或等你回答時每 2 秒，否則每 4 秒
    /// (指令預算：工作中每分鐘 ≤60 個主機指令、閒置 ≤30,R-F01);同時每 20 秒回報在場。
    public func run(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        await restoreFromCache()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.reportPresence(sleep: sleep) }
            group.addTask {
                while !Task.isCancelled {
                    await self.poll()
                    let fast = await MainActor.run { self.agentStatus == .working || self.agentStatus == .blocked }
                    do {
                        try await sleep(fast ? .seconds(2) : .seconds(4))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// 一次輪詢:snapshot → 綁定 session → 讀對話紀錄。
    public func poll() async {
        let snapshot: HostSnapshot
        do {
            snapshot = try await client.snapshot()
        } catch {
            await showOffline()
            return
        }
        isOffline = false
        if banner == .offline { banner = nil }
        guard let agent = snapshot.agents.first(where: { $0.paneID == paneID }) else {
            unbind()
            phase = .agentGone
            agentStatus = nil
            return
        }
        agentStatus = agent.inputPending && agent.status != .working ? .blocked : agent.status
        title = AgentRowText.title(for: agent, siblings: snapshot.agents.filter { $0.workspaceID == agent.workspaceID })
        guard TranscriptFormat(agentKind: agent.kind) != nil else {
            unbind()
            phase = .unsupported
            return
        }
        guard let target = agent.transcriptTarget else {
            waitForSession(agent)
            return
        }
        waitingSince = nil
        if boundSessionID != target.sessionKey {
            // 新的 session(輪替，或回收 slot 中的新聊天):丟掉舊對話、游標與快取(F5.1 第 4 點)。
            if boundSessionID != nil { await cache.remove(chatKey: chatKey) }
            unbind()
            boundSessionID = target.sessionKey
        }
        format = target.format
        await read(target)
    }

    /// 有 agent 但沒有 session id:等待;80 秒後變缺少。agent 在等回答時 id 要等回答後才來，計時歸零(R-I08)。
    private func waitForSession(_ agent: Agent) {
        let now = clock.now()
        if agentStatus == .blocked || waitingSince == nil { waitingSince = now }
        if boundSessionID == nil {
            phase = now.timeIntervalSince(waitingSince ?? now) > 80 ? .missingSession : .waitingForSession
        }
    }

    private func read(_ target: TranscriptTarget) async {
        let generation = generation
        do {
            if let file {
                switch try await transcripts.tail(path: file.path, from: file.cursor) {
                case .unchanged:
                    break
                case .appended(let chunk):
                    guard generation == self.generation else { return }
                    append(chunk)
                case .tooFarBehind(let size), .shrank(let size):
                    // 落後太多不逐行重播積壓;檔案被換掉就重讀(R-B08)。
                    try await openWindow(path: file.path, size: size, generation: generation)
                }
            } else {
                let located = try await transcripts.locate(target)
                guard generation == self.generation else { return }
                try await openWindow(path: located.path, size: located.size, generation: generation)
            }
            banner = nil
            phase = .ready
        } catch TranscriptReadError.absent {
            // 新 session 在第一個 prompt 前可能還沒有檔案：可用的空聊天，下次輪詢再找(R-I09)。
            guard generation == self.generation else { return }
            file = nil
            banner = nil
            phase = .ready
        } catch TranscriptReadError.unreadable {
            banner = .unreadable
            phase = .ready
        } catch TranscriptReadError.ambiguous {
            // 不開任何檔、不依新舊猜;下次輪詢重新定位(使用者可能已刪掉多餘的檔)。
            guard generation == self.generation else { return }
            file = nil
            banner = .ambiguous
            phase = .ready
        } catch {
            // 保留畫面上的內容，下次輪詢重試;永不退回從 byte 0 追蹤。
            banner = .readFailed
            if items.isEmpty { phase = .ready }
        }
        if generation == self.generation, boundSessionID == target.sessionKey { await saveCache() }
    }

    /// 讀最後 `openLines` 行並**取代**目前的訊息。
    private func openWindow(path: String, size: Int, generation: Int) async throws {
        // 以剛探測到的大小為上限:agent 同時在寫也不會變成無上限的補讀(§4.7)。
        let chunk = try await transcripts.window(path: path, endingAt: size, lines: openLines)
        guard generation == self.generation else { return }
        file = (path, chunk.end, chunk.start)
        recent = parse(chunk.lines)
        olderMessages = []
        metadata = format.latestMetadata(in: chunk.lines)
        older = chunk.start > 0 ? .available : .reachedStart
        rebuild()
    }

    private func append(_ chunk: TranscriptChunk) {
        file?.cursor = chunk.end
        let known = Set(recent.map(\.id))
        recent += parse(chunk.lines).filter { !known.contains($0.id) }
        for line in chunk.lines { format.updateMetadata(&metadata, with: line) }
        rebuild()
    }

    // MARK: - 往上翻

    /// 讀上一頁(F5.4)。失敗靜默;session 改變後才到的頁丟棄(R-B05)。
    public func loadOlder() async {
        guard older == .available, let file, file.windowStart > 0 else { return }
        let generation = generation
        older = .loading
        do {
            let chunk = try await transcripts.window(path: file.path, endingAt: file.windowStart, lines: pageLines)
            guard generation == self.generation else { return }
            let known = Set((olderMessages + recent).map(\.id))
            olderMessages = parse(chunk.lines).filter { !known.contains($0.id) } + olderMessages
            self.file?.windowStart = chunk.start
            older = chunk.start > 0 ? .available : .reachedStart
            rebuild()
        } catch {
            guard generation == self.generation else { return }
            older = .available
        }
    }

    // MARK: - 離線

    /// 連不上主機：畫面空著時，唯讀顯示同一 session 的快取(只在快取屬於列表看到的 session 時,R-B16)。
    private func showOffline() async {
        isOffline = true
        banner = .offline
        if items.isEmpty, let knownSessionID, let cached = await cache.load(chatKey: chatKey), cached.matches(sessionID: knownSessionID) {
            recent = cached.messages
            metadata = cached.metadata
            rebuild()
        }
        if phase == .loading { phase = .ready }
    }

    // MARK: - 在場回報

    /// 每 20 秒回報一次「手機正在看」(F5.13),直到所在的 task 被取消。純裝飾，失敗不影響任何事。
    public func reportPresence(sleep: @escaping @Sendable (Duration) async throws -> Void) async {
        while !Task.isCancelled {
            let nowMillis = UInt64(max(0, clock.now().timeIntervalSince1970 * 1000))
            // herdr 忽略不大於上次的 seq(即使過了 TTL):以時鐘起算並保持單調(R-H22)。
            let seq = max(lastPresenceSeq + 1, nowMillis)
            lastPresenceSeq = seq
            let model = metadata.model.map(TranscriptMetadata.displayName(ofModel:))
            try? await client.reportPresence(paneID: paneID, model: model, seq: seq)
            do {
                try await sleep(.seconds(20))
            } catch {
                return
            }
        }
    }

    // MARK: - 內部

    private func unbind() {
        generation += 1
        boundSessionID = nil
        file = nil
        recent = []
        olderMessages = []
        metadata = TranscriptMetadata()
        older = .reachedStart
        rebuild()
    }

    private func rebuild() {
        items = Conversation.items(from: olderMessages + recent)
    }

    private func saveCache() async {
        guard let boundSessionID, let file else { return }
        await cache.save(
            CachedConversation(sessionID: boundSessionID, messages: recent, metadata: metadata, path: file.path, cursor: file.cursor, windowStart: file.windowStart),
            chatKey: chatKey
        )
    }

    private func parse(_ lines: [String]) -> [TranscriptMessage] {
        var seen = Set<String>()
        return lines.flatMap(format.messages(in:)).filter { seen.insert($0.id).inserted }
    }
}
