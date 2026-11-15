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
    /// Claude 的背景 agents 窗格(F10「背景 agents 列」),從 pane 畫面解析;沒有窗格是 `nil`。
    public private(set) var agentsPane: AgentsPane?
    /// 上次讀到窗格的時間：執行中列的經過時間 = 畫面值 + 之後經過的秒數。
    public private(set) var agentsPaneReadAt: Date?

    /// 輪詢間隔：agent 工作中、等你回答，或背景 agents 窗格有執行中的列時 2 秒，否則 4 秒
    /// (herdr 在背景 agent 執行時回報 idle,commit 0a3b0d7)。
    public var pollInterval: Duration {
        let paneRunning = agentsPane?.rows.contains { $0.state == .running } ?? false
        return agentStatus == .working || agentStatus == .blocked || paneRunning ? .seconds(2) : .seconds(4)
    }

    /// Subagent 卡的畫面 model。還沒有 session 資料夾(對話紀錄未定位)或卡片沒有呼叫 id 時沒有(箭頭停用)。
    /// subagent 的 subagent 平放在同一個主 session 下，所以巢狀的卡也從這裡開。
    public func subagentModel(for card: SubagentCard) -> SubagentModel? {
        guard let path = file?.path, card.callID != nil else { return nil }
        return SubagentModel(transcripts: transcripts, parentTranscript: path, card: currentCard(card))
    }

    /// 卡片的箭頭能不能開(不建立 model)。
    public func canOpen(_ card: SubagentCard) -> Bool {
        file != nil && card.callID != nil
    }

    /// Workflow 的進度 model:每個 run 一個，卡片與畫面共用(每個 run 同時只有一個讀取在途)。
    public func workflowModel(for card: WorkflowCard) -> WorkflowModel? {
        guard let path = file?.path else { return nil }
        if let existing = workflowModels[card.id] { return existing }
        let model = WorkflowModel(transcripts: transcripts, sessionFolder: ClaudeTranscript.sessionFolder(ofTranscript: path), card: card, clock: clock)
        workflowModels[card.id] = model
        return model
    }

    /// Workflow 裡某個 agent 的對話紀錄畫面。
    public func workflowAgentModel(card: WorkflowCard, agent: WorkflowAgent) -> SubagentModel? {
        guard let path = file?.path, let runID = card.runID, let agentID = agent.agentID,
              let transcript = ClaudeTranscript.workflowAgentTranscript(
                  sessionFolder: ClaudeTranscript.sessionFolder(ofTranscript: path), runID: runID, agentID: agentID
              ) else { return nil }
        return SubagentModel(transcripts: transcripts, transcriptPath: transcript, title: agent.label, subtitle: agent.model, status: agent.state)
    }

    /// 卡片的最新狀態(畫面上的卡可能是舊的)。
    private func currentCard(_ card: SubagentCard) -> SubagentCard {
        for case .subagent(let current) in items where current.id == card.id { return current }
        return card
    }

    /// 任務文字與某張 subagent 卡描述**完全相同**時，背景 agents 列可以打開那張卡的對話紀錄。
    public func subagentCard(forTask task: String) -> SubagentCard? {
        for case .subagent(let card) in items where card.title == task { return card }
        return nil
    }

    // MARK: 送出(F6)

    /// 輸入框的文字。改動即存進 `DraftStore`(離開聊天保留)。
    public var draft = "" {
        didSet {
            drafts.save(draft, chatKey: chatKey, session: boundSessionID ?? knownSessionID)
            slash.update(draft: draft)
        }
    }
    /// 輸入 `/` 時的 slash 選單(#15)。
    public let slash: SlashMenuModel
    public private(set) var isSending = false

    // MARK: 圖片(F7)

    /// 一則最多幾張圖片。
    public static let maximumImages = 4
    /// 輸入列上的圖片附件(送出被接受時才清)。
    public private(set) var attachments: [ComposerAttachment] = []
    @ObservationIgnored private let images: ComposerImages?
    /// 這台主機能不能附加圖片(有上傳器;目前只有 Unix 主機)。
    public var canAttachImages: Bool { images != nil }
    public var remainingImageSlots: Int { max(0, Self.maximumImages - attachments.count) }

    /// 加入圖片(相簿、相機、貼上):長邊縮到 2048px、JPEG,存手機副本。超過 4 張的部分不加入並提示。
    public func addImages(_ items: [Data]) async {
        guard let images, !items.isEmpty else { return }
        if items.count > remainingImageSlots { notice = .imageLimit }
        for data in items.prefix(remainingImageSlots) {
            let prepared = await Task.detached(priority: .userInitiated) { ImagePreparation.prepare(data) }.value
            guard let prepared, remainingImageSlots > 0 else {
                if prepared == nil { notice = .imageUnreadable }
                continue
            }
            let name = images.makeName()
            do {
                try images.store.save(prepared.jpeg, as: name.value)
            } catch {
                notice = .imageUnreadable
                continue
            }
            attachments.append(ComposerAttachment(fileName: name, pixelWidth: prepared.width, pixelHeight: prepared.height))
            saveAttachments()
        }
    }

    /// 已滿 4 張時點「加入圖片」:提示上限(F7)。
    public func noteImageLimit() { notice = .imageLimit }

    /// 移除附件。送出(上傳)中不能移除。
    public func removeAttachment(_ id: String) {
        guard !isSending else { return }
        attachments.removeAll { $0.id == id }
        saveAttachments()
    }

    /// 泡泡裡的主機圖片路徑 → 手機上的副本(依檔名;找不到就是 `nil`,畫面顯示「圖片」標籤)。
    public func localImage(forHostPath path: String) -> URL? {
        guard let name = path.split(separator: "/").last else { return nil }
        return localImage(named: String(name))
    }

    public func localImage(named name: String) -> URL? {
        images?.store.url(of: name)
    }

    private func saveAttachments() {
        drafts.saveAttachments(attachments, chatKey: chatKey)
    }

    /// 依序上傳還沒上傳的附件(已上傳的沿用路徑)。任何一張失敗回傳 `nil`:整則不送(F6.5)。
    private func uploadAttachments() async -> [String]? {
        guard let images else { return attachments.isEmpty ? [] : nil }
        var paths: [String] = []
        for index in attachments.indices {
            if let path = attachments[index].uploadedPath {
                paths.append(path)
                continue
            }
            let name = attachments[index].fileName
            guard let url = images.store.url(of: name.value), let data = try? Data(contentsOf: url),
                  let path = try? await images.uploader.upload(data, named: name) else { return nil }
            if let current = attachments.firstIndex(where: { $0.fileName == name }) {
                attachments[current].uploadedPath = path
            }
            paths.append(path)
        }
        saveAttachments()
        return paths
    }
    /// 還沒被對話紀錄確認的回音。
    public private(set) var echoes: [PromptEcho] = []
    /// 畫面上的列：對話紀錄的項目，加上依時間併入的回音。
    public private(set) var entries: [ConversationEntry] = []
    /// 送出與中斷的提示。輪詢成功不清它(R-P11)。
    public private(set) var notice: SendNotice?
    public private(set) var isStopping = false

    // MARK: 回答「需要你」(F8)

    /// 畫面上正在等回答的提示。
    public private(set) var prompt: BlockedPrompt?
    /// 已送出、還在等結果的回答(選項全部鎖住)。
    public private(set) var answerInFlight: PromptAnswer?
    /// 最近一次已送達的回答(畫面清楚顯示選了什麼)。
    public private(set) var lastAnswer: AnsweredPrompt?
    public private(set) var answerNotice: AnswerNotice?

    public let paneID: String
    /// 不是選取中主機時的主機名(標題列第一段);選取中主機為 `nil`。
    private let hostName: String?
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    private let cache: any ConversationCache
    private let clock: ConversationClock
    private let openLines: Int
    private let pageLines: Int
    /// 列表傳來的 session:快取只在與它相同時秒開或離線顯示(F5.3、#97)。
    private let knownSessionID: String?
    private let drafts: DraftStore
    private let delivery: PromptDelivery
    private let slashDiscovery: ClaudeSlashDiscovery?
    private let haptics: any Haptics
    /// 下一次輪詢要讀畫面(送出時 agent 在等回答)。
    private var probeScreen = false
    private var answerSignature: String?
    private var answerQuestion: String?
    /// 按鍵送達主機的時間;還在送時為 `nil`(不判定)。
    private var answerSentAt: Date?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    /// 這次輪詢已經讀到的 pane 畫面(提示與背景 agents 窗格共用)。
    @ObservationIgnored private var screenThisPoll: String?
    private let sleep: @Sendable (Duration) async throws -> Void

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
    /// 最近一次輪詢看到的 agent(送出時重讀失敗的後備)。
    private var currentAgent: Agent?
    /// 已經確認過某則回音的使用者訊息(每個到達只能確認一則)。
    private var consumedUserIDs = Set<String>()
    private var lastPolledStatus: AgentStatus?
    /// 卡片在 body 中取用時才建立，所以不參與觀察(避免在畫面更新中改變被觀察的狀態)。
    @ObservationIgnored private var workflowModels: [String: WorkflowModel] = [:]
    private var lastPresenceSeq: UInt64 = 0
    /// 每次綁定新 session 遞增;晚到的舊 session 結果直接丟棄(R-B07)。
    private var generation = 0

    public init(
        client: HerdrClient, transcripts: TranscriptReader, paneID: String, knownSessionID: String?,
        cache: any ConversationCache, clock: ConversationClock = ConversationClock(), openLines: Int = 300, pageLines: Int = 200,
        drafts: DraftStore = DraftStore(), slashDiscovery: ClaudeSlashDiscovery? = nil, haptics: any Haptics = SilentHaptics(),
        hostName: String? = nil,
        images: ComposerImages? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.images = images
        self.client = client
        self.transcripts = transcripts
        self.paneID = paneID
        self.knownSessionID = knownSessionID
        self.cache = cache
        self.clock = clock
        self.openLines = openLines
        self.pageLines = pageLines
        self.drafts = drafts
        self.haptics = haptics
        self.hostName = hostName
        self.sleep = sleep
        delivery = PromptDelivery(client: client, sleep: sleep)
        self.slashDiscovery = slashDiscovery
        slash = SlashMenuModel(loader: { nil })
        draft = drafts.text(chatKey: paneID, session: knownSessionID)
        if images != nil { attachments = drafts.attachments(chatKey: paneID) }
        slash.loader = { [weak self] in await self?.slashCatalog() }
        slash.onPick = { [weak self] in self?.draft = $0 }
        slash.update(draft: draft)
    }

    /// 這個 agent 的 slash 清單(#15):Claude 在主機上發現;Grok、Antigravity 用固定清單;其他沒有選單(`nil`)。
    /// 還沒輪詢過時先讀一次 snapshot 以知道 agent 種類。沒有發現器時(測試)只有內建指令並標示不完整。
    private func slashCatalog() async -> SlashCatalog? {
        var agent = currentAgent
        if agent == nil {
            agent = (try? await client.snapshot())?.agents.first { $0.paneID == paneID }
        }
        guard let agent else { return nil }
        switch AgentSlashMenu(agentKind: agent.kind) {
        case .none:
            return nil
        case .fixed(let commands):
            return SlashCatalog(fixed: commands)
        case .discovered:
            guard let slashDiscovery else { return SlashCatalog(sections: [SlashSection(source: .builtIn, commands: ClaudeBuiltinCommands.all)], isComplete: false) }
            return await slashDiscovery.catalog(cwd: agent.cwd, transcriptPath: file?.path)
        }
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
                    let interval = await MainActor.run { self.pollInterval }
                    do {
                        try await sleep(interval)
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
        currentAgent = snapshot.agents.first { $0.paneID == paneID }
        guard let agent = currentAgent else {
            unbind()
            phase = .agentGone
            agentStatus = nil
            updateWorkingSince()
            return
        }
        agentStatus = agent.inputPending && agent.status != .working ? .blocked : agent.status
        screenThisPoll = nil
        await refreshPrompt(agent)
        await refreshLivePreview()
        title = AgentRowText.title(for: agent, siblings: snapshot.agents.filter { $0.workspaceID == agent.workspaceID })
        guard TranscriptFormat(agentKind: agent.kind) != nil else {
            unbind()
            phase = .unsupported
            return
        }
        // 背景 agents 窗格只有 Claude 有。
        if agent.kind == "claude" { await readAgentsPaneIfNeeded() }
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

    /// 背景 agents 窗格的讀取時機(F10、R-W05):工作中每次輪詢讀;問題開著時沿用上次;閒置時只在上次有窗格、
    /// 或工作中之後的第一次閒置時讀(一輪可能在兩次輪詢之間開始背景 agent 並結束,commit e0d34ce)。
    /// 讀取失敗沿用上次。
    private func readAgentsPaneIfNeeded() async {
        let status = agentStatus
        defer { lastPolledStatus = status }
        let shouldRead = switch status {
        case .working: true
        case .blocked: false
        default: agentsPane != nil || lastPolledStatus == .working
        }
        guard shouldRead else { return }
        // 這次輪詢找提示時已經讀過畫面就沿用，不再多一個主機指令。
        let read: String?
        if let screenThisPoll { read = screenThisPoll } else { read = try? await client.readPane(paneID: paneID) }
        guard let screen = read else { return }
        agentsPane = AgentsPane.parse(screen: screen)
        agentsPaneReadAt = clock.now()
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
        updateWorkingSince()
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

    // MARK: - 送出

    /// 可送 = 修剪後非空或有圖片、沒有送出進行中、目標可用(載入完、有 agent、連得上)(F6.1)。
    public var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && hasTarget
    }

    /// 停止只在 working 時;**永不對 blocked 的 agent**(中斷可能把問題關掉,F6.7)。
    public var canStop: Bool { agentStatus == .working && !isStopping }

    private var hasTarget: Bool {
        phase != .loading && phase != .agentGone && !isOffline && currentAgent != nil
    }

    /// 送出輸入框的文字(F6.5)。
    ///
    /// 輸入框樂觀清空、立刻顯示回音;送出當下重讀**新鮮的** snapshot 重新確認目標 pane(2 秒前的 pane 可能已被回收,R-P06)。
    /// 什麼都沒送出(agent 不在、session 換了、在等回答、herdr 拒絕)→ 拿掉回音、草稿放回;
    /// 送了但不確定(沒有反應、無法確認)→ 回音標示失敗，可重試，**不自動重送**(§7.3)。
    public func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        updateWorkingSince()
        defer {
            isSending = false
            updateWorkingSince()
        }
        notice = nil
        draft = ""
        let sentImages = attachments
        let echo = PromptEcho(
            id: UUID().uuidString, text: text, date: clock.now(), knownUserIDs: userMessageIDs,
            imageCount: sentImages.count, imageFiles: sentImages.map(\.fileName.value)
        )
        echoes.append(echo)
        rebuildEntries()
        // 圖片先逐張上傳;任何一張失敗 → 整則不送，草稿與圖片保留(F6.5、F7)。
        guard let paths = await uploadAttachments() else {
            removeEcho(echo.id)
            restoreDraft(text)
            notice = .uploadFailed
            return
        }
        if let index = echoes.firstIndex(where: { $0.id == echo.id }) { echoes[index].imagePaths = paths }
        let prompt = UploadedImages.prompt(text: text, paths: paths)
        switch await freshTarget() {
        case .success(let agent):
            apply(await delivery.send(prompt, to: agent), toEcho: echo.id, text: text, isRetry: false)
            // 附件只在送出被接受時清(什麼都沒送出時草稿放回、圖片也留著，已上傳的不重傳)。
            if !Self.nothingSent(notice) {
                attachments.removeAll { attachment in sentImages.contains { $0.fileName == attachment.fileName } }
                saveAttachments()
            }
            if notice == .needsAnswer {
                // 什麼都沒送出，因為 agent 在等回答：立刻找出問題(資料夾信任這類提示 herdr 可能回報 idle)。
                probeScreen = true
                await refreshPrompt(agent)
            }
        case .failure(let failure):
            removeEcho(echo.id)
            restoreDraft(text)
            notice = failure.notice
        }
    }

    /// 重試失敗的回音：送同樣的文字。同一則同時最多一個重試在途(連點曾送兩次,#100)。
    public func retry(echoID: String) async {
        guard let index = echoes.firstIndex(where: { $0.id == echoID }), case .failed(let failure) = echoes[index].state else { return }
        let text = echoes[index].text
        // 重試送同樣文字與已上傳的路徑，不重傳(F6.5)。
        let prompt = UploadedImages.prompt(text: text, paths: echoes[index].imagePaths)
        echoes[index].state = .sending
        rebuildEntries()
        notice = nil
        switch await freshTarget() {
        case .success(let agent):
            apply(await delivery.send(prompt, to: agent), toEcho: echoID, text: text, isRetry: true)
        case .failure(let targetFailure):
            setEcho(echoID, state: .failed(failure))
            notice = targetFailure.notice
        }
    }

    /// 停止(F6.7):一個 Esc,3 秒內確認離開 working。
    public func stop() async {
        guard canStop else { return }
        isStopping = true
        defer { isStopping = false }
        switch await delivery.stop(paneID: paneID) {
        case .stopped: notice = nil
        case .stillWorking: notice = .stillWorking
        case .failed: notice = .interruptFailed
        case .needsAnswer: notice = .interruptRefusedNeedsAnswer
        }
    }

    /// 強制結束(ctrl+c,F6.7)。呼叫端先請使用者確認;只對 working 的 agent。
    public func forceQuit() async {
        guard agentStatus == .working else { return }
        switch await delivery.forceQuit(paneID: paneID) {
        case .sent, .notWorking: notice = nil
        case .needsAnswer: notice = .interruptRefusedNeedsAnswer
        case .failed: notice = .interruptFailed
        }
    }

    public func dismissNotice() { notice = nil }

    // MARK: - 回答「需要你」

    /// 這個回答現在能不能送:沒有回答在途、提示還在，且有按鍵可送(編號 10 以上不行,R-Q04)。
    public func canAnswer(_ answer: PromptAnswer) -> Bool {
        guard answerInFlight == nil, let prompt, keys(for: answer) != nil else { return false }
        switch answer {
        case .option(let option): return prompt.options.contains(option)
        case .continueMultiSelect: return prompt.isMultiSelect
        case .closePicker: return prompt.kind == .filePicker
        case .generic: return prompt.kind == .unrecognized
        }
    }

    /// 回答提示(F8):依 agent 規則送出按鍵(§5.5)。
    ///
    /// 送出前就鎖住所有選項(兩次快速點擊在重繪前就會到);之後每次輪詢判定：提示不見了或換成別的 → 已送達;
    /// 同一個提示超過期限 → 逾時、解鎖並提示可能沒送到;按鍵送不出去 → 立刻解鎖並顯示錯誤(R-Q05)。
    public func answer(_ answer: PromptAnswer) async {
        guard canAnswer(answer), let prompt, let keys = keys(for: answer) else { return }
        answerInFlight = answer
        answerSignature = prompt.signature
        answerQuestion = prompt.question
        answerSentAt = nil
        answerNotice = nil
        haptics.play(.selection)
        do {
            try await client.sendKeys(paneID: paneID, keys: keys)
        } catch {
            guard answerInFlight == answer else { return }
            clearAnswer()
            answerNotice = .sendFailed
            haptics.play(.error)
            return
        }
        guard answerInFlight == answer else { return }
        answerSentAt = clock.now()
        // 下一題常緊接著出現：0.4 秒與 1.2 秒各多看一次(R-Q09)。
        kickTask?.cancel()
        kickTask = Task { [weak self, sleep] in
            for delay in [Duration.milliseconds(400), .milliseconds(800)] {
                do { try await sleep(delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    public func dismissAnswerNotice() { answerNotice = nil }

    private func keys(for answer: PromptAnswer) -> [String]? {
        AnswerKeys.keys(for: answer, agentKind: currentAgent?.kind ?? "")
    }

    /// 回答期限:max(12 秒, 3 × 輪詢間隔)(blocked 時每 2 秒輪詢;慢輪詢下好答案曾被判逾時,R-Q05)。
    private static let answerDeadline: TimeInterval = max(12, 3 * 2)

    /// 讀 pane 畫面找出提示(§5.1)。
    ///
    /// - `blocked`(或 `input_pending`)每次輪詢都讀;看不出選單就給通用鈕。
    /// - herdr 0.9.5 沒有 `input_pending`:Claude 首次啟動的資料夾信任時 agent 是閒置、還沒有 session,
    ///   所以閒置且沒有 session、送出時被告知在等回答、或畫面上已有提示時也讀，但**只認資料夾信任**
    ///   (閒置畫面上對話中的編號清單不是提示)。
    private func refreshPrompt(_ agent: Agent) async {
        let blocked = agent.status == .blocked || (agent.inputPending && agent.status != .working)
        // 工作中 = 沒有在等任何回答(提示已經被回答掉了)。
        let probe = agent.status != .working && (probeScreen || prompt != nil || agent.session == nil)
        probeScreen = false
        guard blocked || probe else {
            update(prompt: nil)
            return
        }
        screenThisPoll = try? await client.readPane(paneID: agent.paneID)
        guard let screen = screenThisPoll else {
            // 讀不到畫面 = 未知：永不當成新提示，只看逾時。
            if blocked, prompt == nil { prompt = .unrecognized }
            if prompt != nil { agentStatus = .blocked }
            checkAnswerDeadline()
            return
        }
        let parsed = BlockedPromptParser.parse(screen: screen, agentKind: agent.kind)
        let next = blocked ? (parsed ?? .unrecognized) : (parsed?.kind == .trust ? parsed : nil)
        if next != nil { agentStatus = .blocked }
        update(prompt: next)
    }

    /// 以新的畫面判定在途的回答，再換上新的提示(同一提示保持原物件)。
    private func update(prompt next: BlockedPrompt?) {
        if let answer = answerInFlight, answerSentAt != nil {
            if next == nil || next?.signature != answerSignature {
                // 不再 blocked = 已送達;換成別的提示 = 被取代(通常是下一題),新問題不繼承鎖。
                if case .option(let option) = answer, option.checked != nil {
                    // 勾選只是切換，不是最終的回答。
                } else {
                    lastAnswer = AnsweredPrompt(question: answerQuestion, choice: Self.choiceText(answer))
                }
                clearAnswer()
                haptics.play(.success)
            } else {
                checkAnswerDeadline()
            }
        }
        if next?.signature != prompt?.signature || (next == nil) != (prompt == nil) { prompt = next }
    }

    private func checkAnswerDeadline() {
        guard answerInFlight != nil, let sentAt = answerSentAt,
              clock.now().timeIntervalSince(sentAt) > Self.answerDeadline else { return }
        clearAnswer()
        answerNotice = .mayNotHaveArrived
        haptics.play(.error)
    }

    private func clearAnswer() {
        answerInFlight = nil
        answerSignature = nil
        answerQuestion = nil
        answerSentAt = nil
    }

    private static func choiceText(_ answer: PromptAnswer) -> String {
        switch answer {
        case .option(let option): option.label
        case .continueMultiSelect: String(localized: "Continue")
        case .closePicker: String(localized: "Close File Picker")
        case .generic(.confirm): String(localized: "Confirm")
        case .generic(.one): "1"
        case .generic(.two): "2"
        case .generic(.escape): String(localized: "Esc")
        }
    }

    // MARK: - 送出(內部)

    private enum TargetFailure: Error {
        case agentGone
        case superseded

        var notice: SendNotice {
            switch self {
            case .agentGone: .agentGone
            case .superseded: .superseded
            }
        }
    }

    /// 送出當下的目標：重讀新鮮的 snapshot(不共用輪詢那份);讀不到就用輪詢得到的 agent(F6.5)。
    /// session 換了 = pane 被回收成另一個聊天，原本的對象已不在(F5.1)。
    private func freshTarget() async -> Result<Agent, TargetFailure> {
        let agent: Agent?
        if let snapshot = try? await client.snapshot() {
            agent = snapshot.agents.first { $0.paneID == paneID }
        } else {
            agent = currentAgent
        }
        guard let agent else { return .failure(.agentGone) }
        if let expected = boundSessionID ?? knownSessionID, let session = agent.session?.value, session != expected {
            return .failure(.superseded)
        }
        return .success(agent)
    }

    private func apply(_ outcome: PromptOutcome, toEcho id: String, text: String, isRetry: Bool) {
        let nothingSent: SendNotice?
        switch outcome {
        case .delivered, .submittedCommand:
            setEcho(id, state: .sent)
            return
        case .noResponse:
            setEcho(id, state: .failed(.noResponse))
            notice = .noResponse
            return
        case .unconfirmed(let reason):
            setEcho(id, state: .failed(.unconfirmed(reason)))
            notice = .unconfirmed(reason)
            return
        case .needsAnswer:
            nothingSent = .needsAnswer
        case .rejected(let message):
            nothingSent = .rejected(message)
        }
        notice = nothingSent
        if isRetry {
            setEcho(id, state: .failed(.noResponse))
        } else {
            removeEcho(id)
            restoreDraft(text)
        }
    }

    /// 什麼都沒送出的提示(草稿放回)。
    private static func nothingSent(_ notice: SendNotice?) -> Bool {
        switch notice {
        case .needsAnswer?, .rejected?: true
        default: false
        }
    }

    /// 被拒的文字放回輸入框(使用者這段時間又打了字就不蓋掉)。
    private func restoreDraft(_ text: String) {
        if draft.isEmpty { draft = text }
    }

    private func setEcho(_ id: String, state: PromptEcho.State) {
        guard let index = echoes.firstIndex(where: { $0.id == id }) else { return }
        echoes[index].state = state
        rebuildEntries()
    }

    private func removeEcho(_ id: String) {
        echoes.removeAll { $0.id == id }
        rebuildEntries()
    }

    private var userMessageIDs: Set<String> {
        Set(items.compactMap { item in
            if case .user(let bubble) = item { bubble.id } else { nil }
        })
    }

    /// 以對話紀錄確認回音;確認了任何一則就清掉送出警告(R-P11:輪詢成功本身不清)。
    private func rebuildEntries() {
        let bubbles = items.compactMap { item -> UserBubble? in
            if case .user(let bubble) = item { bubble } else { nil }
        }
        let remaining = EchoMatching.confirm(echoes, against: bubbles, consumed: &consumedUserIDs)
        if remaining.count < echoes.count {
            echoes = remaining
            notice = nil
        }
        entries = EchoTimeline.merge(items: items, echoes: echoes)
    }

    // MARK: - 標題列(#44)

    /// 標題下一行的資訊(F5.7)。
    public var header: ConversationHeader {
        ConversationHeader(agent: currentAgent, title: title, metadata: metadata, status: agentStatus, isOffline: isOffline, hostName: hostName)
    }

    /// 標題列的動作鈕:working(或停止進行中)時「停止」,其他時候「重新載入」;還沒輪詢過時沒有。
    public var headerAction: HeaderAction? {
        if agentStatus == .working || isStopping { return .stop }
        return phase == .loading ? nil : .reload
    }

    /// 重新載入(F5.7):清掉這個聊天的快取、游標與歷史(含停止追蹤的 workflow),重新定位並讀視窗。
    public func reload() async {
        await cache.remove(chatKey: chatKey)
        unbind()
        banner = nil
        await poll()
    }

    // MARK: - 工作中指示(F5.11)

    /// 對話底部的工作中指示：agent 在工作或送出中，且沒有問題在等、連得上。
    public var showsWorkingIndicator: Bool {
        (agentStatus == .working || isSending) && prompt == nil && !isOffline
    }

    /// 指示出現的時間(經過時間從這裡起算)。
    public private(set) var workingSince: Date?
    /// 從 pane 可見畫面擷取到的散文(只在 working 時);沒有真正的散文為 `nil`。
    public private(set) var livePreview: String?

    /// working 時讀 pane 可見畫面擷取即時預覽(與背景 agents 窗格共用同一次讀取)。
    private func refreshLivePreview() async {
        if agentStatus == .working, prompt == nil {
            if screenThisPoll == nil { screenThisPoll = try? await client.readPane(paneID: paneID) }
            livePreview = screenThisPoll.flatMap(LivePreview.extract(screen:))
        } else {
            livePreview = nil
        }
        updateWorkingSince()
    }

    private func updateWorkingSince() {
        if !showsWorkingIndicator {
            workingSince = nil
            livePreview = nil
        } else if workingSince == nil {
            workingSince = clock.now()
        }
    }

    // MARK: - 內部

    private func unbind() {
        generation += 1
        workflowModels = [:]
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
        rebuildEntries()
        for case .workflow(let card) in items { workflowModels[card.id]?.update(card: card) }
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

/// 送出與中斷的提示(對話畫面上的非干擾式標示)。
public enum SendNotice: Sendable, Equatable {
    /// agent 正在等一個問題：先回答它再送(什麼都沒送出)。
    case needsAnswer
    /// 這個 pane 已經沒有 agent。
    case agentGone
    /// pane 被回收成另一個聊天(session 換了)。
    case superseded
    /// 連不上主機。
    case offline
    /// herdr 拒絕(原文)。
    case rejected(String)
    /// agent 沒接住(停滯)。
    case noResponse
    /// 不知道有沒有送到。
    case unconfirmed(UnconfirmedReason)
    /// 一則最多 4 張圖片(F7)。
    case imageLimit
    /// 讀不出圖片。
    case imageUnreadable
    /// 圖片上傳失敗：整則沒送出，草稿與圖片保留。
    case uploadFailed
    /// 停止後 3 秒仍在工作。
    case stillWorking
    /// 送不出中斷的按鍵。
    case interruptFailed
    /// agent 在等你回答，所以沒有送出中斷(F6.7)。
    case interruptRefusedNeedsAnswer
}
