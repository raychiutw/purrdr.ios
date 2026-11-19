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
        /// 對話紀錄被壓縮了(Codex 會壓縮 7 天未動的 rollout,行為規格 §4.2):目前讀不了，但不是不存在。
        case compressed
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

    /// 輪詢間隔：agent 工作中、等你回答，或背景 agents 窗格有執行中的列時 2 秒，否則 4 秒。
    /// 例外快速路徑(#163):herdr 在背景 agent 執行時回報 idle(commit 0a3b0d7)、多題問答期間一直 blocked,
    /// 都沒有狀態事件，靠這個 2 秒讀畫面確認。工作中讀畫面另有節奏，約每 6 秒一次(#204,`WorkingScreenReads`)。
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
            // 自訂回答的文字不是草稿，也不開 slash 選單(#120)。
            guard typedAnswer == nil else {
                slash.update(draft: "")
                typedAnswerDraftChanged()
                return
            }
            drafts.save(draft, chatKey: chatKey, session: boundSessionID ?? knownSessionID)
            if !isComposingDraft { slash.update(draft: draft) }
        }
    }
    /// 輸入框正在組字(有 marked text)。組字中不拿暫時文字篩選 slash 選單(#138)。
    public var isComposingDraft = false {
        didSet {
            if oldValue, !isComposingDraft, typedAnswer == nil { slash.update(draft: draft) }
        }
    }
    /// 選取中主機的「You should know」註記(#23);由 `HostsModel` 接上，沒有時不顯示。
    public var youShouldKnow: YouShouldKnowModel?

    /// 輸入列上方的註記：只顯示這個輸入框要送往的 session 的那則(行為規格 F17)。
    public var note: YouShouldKnowNote? {
        guard let session = boundSessionID ?? knownSessionID else { return nil }
        return youShouldKnow?.note(forSession: session)
    }

    /// 把文字放進輸入框(「在聊天中討論」):空的就放入，已有文字就空一行接在後面，不蓋掉使用者打的字。
    public func insertIntoDraft(_ text: String) {
        draft = draft.isEmpty ? text : draft + "\n\n" + text
    }

    /// 輸入 `/` 時的 slash 選單(#15)。
    public let slash: SlashMenuModel
    public private(set) var isSending = false
    /// 這支裝置配對成唯讀(HTTPS):不能送 prompt、回答或中斷。
    public private(set) var isReadOnly = false

    // MARK: 圖片(F7)

    /// 一則最多幾張圖片。
    public static let maximumImages = 4
    /// 輸入列上的圖片附件(送出被接受時才清)。
    public private(set) var attachments: [ComposerAttachment] = []
    @ObservationIgnored private let images: ComposerImages?
    /// 這台主機能不能附加圖片(有上傳器;目前只有 Unix 主機)。
    public var canAttachImages: Bool { images != nil }
    public var remainingImageSlots: Int { max(0, Self.maximumImages - attachments.count) }

    /// 加入圖片(相簿、相機、貼上):長邊縮到 2048px、JPEG,存手機副本。超過 4 張的部分、原始大小超過單張上限的不加入並提示。
    public func addImages(_ items: [Data]) async {
        guard let images, !items.isEmpty else { return }
        if items.count > remainingImageSlots { notice = .imageLimit }
        for data in items.prefix(remainingImageSlots) {
            // 單張上限以使用者挑的原始圖片判斷，不因縮小而改變(#76)。
            guard data.count <= ImageUploadLimit.maximumSize else {
                notice = .imageTooLarge
                continue
            }
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
    /// 列表結構(列的 id 與順序)每變一次遞增。畫面觀察它，不必每次 body 都配置整個 id 陣列(#130)。
    public private(set) var entriesRevision = 0
    /// 送出與中斷的提示。輪詢成功不清它(R-P11)。
    public private(set) var notice: SendNotice?
    public private(set) var isStopping = false

    // MARK: 回答「需要你」(F8)

    /// 畫面上正在等回答的提示。
    public private(set) var prompt: BlockedPrompt?
    /// 已送出、還在等結果的回答(選項全部鎖住)。
    public private(set) var answerInFlight: PromptAnswer?
    /// 最近一次已送達的回答(畫面清楚顯示選了什麼);Agent 寫出新的文字後收起(#213,`AnsweredCardAnchor`)。
    public private(set) var lastAnswer: AnsweredPrompt?
    private var answeredCardAnchor: AnsweredCardAnchor?
    public private(set) var answerNotice: AnswerNotice?

    public let paneID: String
    /// 不是選取中主機時的主機名(標題列第一段);選取中主機為 `nil`。每次算標題列時才問，
    /// 換選取中主機或主機改名後，已開啟的聊天也跟著更新(#31)。
    private let hostName: @MainActor () -> String?
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
    private let slashDiscovery: (any SlashDiscovering)?
    private let haptics: any Haptics
    /// 主機收下 prompt(成功送出)時呼叫;請求評分用(#34)。
    @ObservationIgnored public var onPromptDelivered: (@MainActor () -> Void)?
    /// 下一次輪詢要讀畫面(送出時 agent 在等回答)。
    private var probeScreen = false
    private var answerSignature: String?
    private var answerQuestion: String?
    /// 按鍵送達主機的時間與當時對話的最後一列(已回答卡片的錨點，#213);還在送時為 `nil`(不判定)。
    private var answerSent: AnsweredCardAnchor?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    /// 這次輪詢已經讀到的 pane 畫面(提示與背景 agents 窗格共用)。
    @ObservationIgnored private var screenThisPoll: String?
    /// 工作中讀畫面的節奏(#204)。
    @ObservationIgnored private var workingScreenReads = WorkingScreenReads()
    /// 這次輪詢若在工作中，可以讀畫面更新即時預覽與背景 agents 窗格;不行時沿用上次的。
    @ObservationIgnored private var workingScreenDue = true
    private let sleep: Sleep
    /// 這台主機的主機更新來源(#163);沒有時自己讀快照。
    private let updates: HostUpdates?
    /// `run()` 期間下一次輪詢的等待(間隔到或被叫醒)。
    @ObservationIgnored private var pollDue: WakeSignal?
    /// `run()` 期間對話紀錄追蹤的節奏(內部輪詢的連線方式用);不在 `run()` 裡時沒有，`poll()` 自己讀尾端。
    @ObservationIgnored private var followPace: TranscriptFollowPace?
    /// 追蹤中的對話紀錄(#165):有它時新內容由追蹤送來，輪詢不讀尾端。
    @ObservationIgnored private var following: ActiveTranscriptFollow?

    /// 一個進行中的對話紀錄追蹤。`id` 讓結束的追蹤只清掉自己(不清後來開的)。
    private struct ActiveTranscriptFollow {
        let path: String
        let id: UUID
        let task: Task<Void, Never>

        init(path: String, start: (UUID) -> Task<Void, Never>) {
            self.path = path
            id = UUID()
            task = start(id)
        }
    }

    /// 目前綁定的 session(herdr 回報的 id 或路徑)與讀取狀態。
    private var boundSessionID: String?
    /// 對話紀錄的格式，依 Agent 種類(每次輪詢由 snapshot 更新;還沒輪詢前的快取還原不需要解析)。
    private var format: TranscriptFormat = .claude
    /// 對話紀錄的路徑、即時追蹤的游標，以及開啟視窗的 byte 起點(往上翻的錨點)。
    /// `follow.isLive`:這次可見期間已經追上主機，之後落後再多也從游標分段接著讀(#130);還沒追上(剛從快取恢復、
    /// 畫面重新可見)時落後太多改讀新視窗(F5.3 第 3 點、R-B08)。
    private var file: (path: String, follow: TranscriptFollow, windowStart: Int)?
    /// 開啟視窗與之後追蹤到的訊息(會寫入快取)。
    private var recent: [TranscriptMessage] = []
    /// `recent` 由哪幾段讀取組成(每段的 byte 起點與訊息數，依序、加總等於 `recent.count`)。修剪與寫快取都以整段為單位，
    /// 視窗起點因此是某一段的開頭，往上翻接得上、不缺訊息(#130)。
    private var segments: [(start: Int, count: Int)] = []
    /// 畫面跟隨尾端(由畫面告知)。只有跟隨中才修剪最舊的訊息：讀者正在看的不會被拿掉。
    @ObservationIgnored public var isFollowingLatest = true
    /// 跟隨尾端時記憶體裡最多保留的訊息數(含往上翻的舊頁;與快取的上限相同)。超過時整段修剪最舊的，可以往上翻回來。
    public static let followingMessageLimit = CachedConversation.maxMessages
    /// 往上翻載入的舊訊息(不寫入快取)。
    private var olderMessages: [TranscriptMessage] = []
    private var waitingSince: Date?
    /// 最近一次輪詢看到的 agent(送出時重讀失敗的後備)。
    private var currentAgent: Agent?
    /// 最近一次輪詢看到的 Agent 種類(畫面依種類調整說明，例如 Codex 等 session 的提示)。
    public var agentKind: String? { currentAgent?.kind }
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
        drafts: DraftStore = DraftStore(), slashDiscovery: (any SlashDiscovering)? = nil, haptics: any Haptics = SilentHaptics(),
        hostName: @escaping @MainActor () -> String? = { nil },
        images: ComposerImages? = nil,
        updates: HostUpdates? = nil,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.updates = updates
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
        slash.onPick = { [weak self] command in self?.pick(slash: command) }
        slash.update(draft: draft)
    }

    /// 這個 agent 的 slash 清單(#15):Claude 在主機上發現;Grok、Antigravity 用固定清單;其他沒有選單(`nil`)。
    /// 還沒輪詢過時先讀一次 snapshot 以知道 agent 種類。沒有發現器時(測試)只有內建指令並標示不完整。
    private func slashCatalog() async -> SlashCatalog? {
        var agent = currentAgent
        if agent == nil {
            var snapshot = liveSnapshot
            if snapshot == nil { snapshot = try? await client.snapshot() }
            agent = snapshot?.agents.first { $0.paneID == paneID }
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

    /// 畫面變成可見(開啟聊天、回到前景;`run()` 一開始):當作重新開啟。已在追蹤時，離開期間落後太多就讀新視窗，
    /// 不逐段重播積壓(R-B08、F5.3 第 3 點);畫面還空著時先顯示快取。
    public func reopen() async {
        file?.follow.reopen()
        await restoreFromCache()
    }

    /// 列表傳來的 session 與快取相同時，立刻顯示快取並從游標續讀(F5.3 第 1 點)。
    public func restoreFromCache() async {
        guard let knownSessionID, items.isEmpty, let cached = await cache.load(chatKey: chatKey),
              cached.matches(sessionID: knownSessionID) else { return }
        boundSessionID = knownSessionID
        file = (cached.path, TranscriptFollow(cursor: cached.cursor, isLive: false), cached.windowStart)
        recent = cached.messages
        segments = [(cached.windowStart, cached.messages.count)]
        metadata = cached.metadata
        older = cached.windowStart > 0 ? .available : .reachedStart
        phase = .ready
        rebuild()
    }

    // MARK: - 輪詢

    /// 畫面可見且 app 在前景時執行，直到所在的 task 被取消。agent 工作中或等你回答時每 2 秒，否則每 4 秒
    /// (指令預算：工作中每分鐘 ≤60 個主機指令、閒置 ≤30,R-F01);同時每 30 秒回報在場。
    /// 有主機更新來源時一起保持它的即時更新，這個 Agent 在快照裡變了就立刻再輪詢一次，不等間隔(#163)。
    /// 期間連線快速偵測斷線(最壞約 15 秒顯示離線)。
    public func run(sleep: @escaping Sleep = Sleeping.task) async {
        followPace = TranscriptFollowPace(interval: pollInterval, sleep: sleep)
        let pollDue = WakeSignal(sleep: sleep)
        self.pollDue = pollDue
        // 不讀快照時靠 keepalive／心跳發現離線：畫面可見期間縮短到最壞約 15 秒。
        await client.beginQuickDisconnectDetection()
        await reopen()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.reportPresence(sleep: sleep) }
            if let updates {
                group.addTask { await updates.liveUpdates.attach() }
                group.addTask { await self.wakeOnChanges(from: updates) }
            }
            while !Task.isCancelled {
                await poll()
                do {
                    // 輪詢期間被叫醒就不等。
                    try await pollDue.wait(atMost: pollInterval)
                } catch {
                    break
                }
            }
            group.cancelAll()
        }
        stopFollowingUpdates()
        followPace = nil
        self.pollDue = nil
        await client.endQuickDisconnectDetection()
        // 畫面不在了：主機推送尾端的連線方式(HTTPS)停止追蹤。下次開啟從游標重新開始。
        if let path = file?.path { await transcripts.stopFollowing(path: path) }
    }

    /// 這個 Agent 在主機更新來源的快照裡變了(狀態事件觸發的重讀):叫醒輪詢。
    private func wakeOnChanges(from updates: HostUpdates) async {
        for await agent in updates.changes(for: paneID) where agent != currentAgent {
            pollDue?.wake()
            followPace?.wake()
        }
    }

    /// 主機更新來源在訂閱事件時用它的快照;還沒連上、斷線或沒有事件訂閱時是 `nil`,改自己讀(#163)。
    private var liveSnapshot: HostSnapshot? {
        guard let updates, updates.isSubscribed else { return nil }
        return updates.snapshot
    }

    /// 一次輪詢：快照(主機更新來源的，或自己讀)→ 綁定 session → 讀對話紀錄。
    public func poll() async {
        // 沒有新的列時，卡片也要依經過時間收起。
        defer { refreshAnsweredCard() }
        let snapshot: HostSnapshot
        if let liveSnapshot {
            snapshot = liveSnapshot
        } else {
            do {
                snapshot = try await snapshotRetryingOnce()
            } catch {
                await showOffline()
                return
            }
        }
        isOffline = false
        if banner == .offline { banner = nil }
        // 送出時被拒過就維持唯讀。
        if (try? await client.isReadOnlyDevice()) == true { isReadOnly = true }
        currentAgent = snapshot.agents.first { $0.paneID == paneID }
        guard let agent = currentAgent else {
            clearSuggestion()
            unbind()
            phase = .agentGone
            agentStatus = nil
            updateWorkingSince()
            return
        }
        agentStatus = agent.inputPending && agent.status != .working ? .blocked : agent.status
        screenThisPoll = nil
        workingScreenDue = workingScreenReads.allowsRead(isWorking: agentStatus == .working, at: clock.now())
        await refreshPrompt(agent)
        let suggestionRead = await readSuggestion(agent)
        await refreshPanel(agent)
        applySuggestion(suggestionRead, agent: agent)
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
        followPace?.interval = pollInterval
        await read(target)
    }

    /// 背景 agents 窗格的讀取時機(F10、R-W05):工作中約每 6 秒讀(#204);問題開著時沿用上次;閒置時只在上次有窗格、
    /// 或工作中之後的第一次閒置時讀(一輪可能在兩次輪詢之間開始背景 agent 並結束,commit e0d34ce)。
    /// 讀取失敗沿用上次。
    private func readAgentsPaneIfNeeded() async {
        let status = agentStatus
        defer { lastPolledStatus = status }
        let shouldRead = switch status {
        case .working: workingScreenDue
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
            if let file, following?.path == file.path {
                // 新內容由追蹤送來(#165),不讀尾端。
            } else if let file {
                // 已追上：落後多少都從游標分段接著讀，不改讀新視窗取代已顯示與往上翻的訊息(#130、R-B09)。
                // 還沒追上(剛從快取恢復、畫面重新可見):落後太多不逐段重播積壓，讀新視窗(R-B08)。
                let read = try await transcripts.follow(path: file.path, file.follow)
                guard generation == self.generation else { return }
                switch read.tail {
                case .unchanged:
                    self.file?.follow = read.next
                case .appended(let chunk):
                    self.file?.follow = read.next
                    append(chunk)
                case .tooFarBehind(let size), .shrank(let size):
                    // 還沒追上時落後太多，或檔案被換掉(變小,真正的斷層):重讀視窗並重建列表。
                    try await openWindow(path: file.path, size: size, generation: generation)
                }
            } else {
                let located = try await transcripts.locate(target)
                guard generation == self.generation else { return }
                try await openWindow(path: located.path, size: located.size, generation: generation)
            }
            banner = nil
            phase = .ready
            startFollowingUpdates()
        } catch {
            showReadFailure(error, generation: generation)
        }
        if generation == self.generation, boundSessionID == target.sessionKey { await saveCache() }
    }

    /// 已追上主機且在 `run()` 裡：開始追蹤目前的對話紀錄，之後的新內容由追蹤送來(#165)。
    private func startFollowingUpdates() {
        guard let followPace, let file, file.follow.isLive, following?.path != file.path else { return }
        following?.task.cancel()
        let path = file.path
        let cursor = file.follow.cursor
        let generation = generation
        let started = ActiveTranscriptFollow(path: path) { id in
            Task { await self.applyUpdates(path: path, from: cursor, pace: followPace, generation: generation, id: id) }
        }
        following = started
    }

    private func stopFollowingUpdates() {
        following?.task.cancel()
        following = nil
    }

    /// 套用追蹤事件：新增接在後面;接不上時重讀視窗並從新游標再追蹤。追蹤以錯誤結束時回到輪詢讀一次再開始。
    private func applyUpdates(path: String, from cursor: Int, pace: TranscriptFollowPace, generation: Int, id: UUID) async {
        var isReplaced = false
        do {
            isReplaced = try await TranscriptFollowUpdates.apply(
                await transcripts.followTranscript(path: path, from: cursor, pace: pace),
                isCurrent: { generation == self.generation && file?.path == path },
                appended: { chunk in
                    file?.follow = TranscriptFollow(cursor: chunk.end, isLive: true)
                    append(chunk)
                },
                replaced: { size in try await openWindow(path: path, size: size, generation: generation) },
                afterEach: {
                    if banner == .readFailed { banner = nil }
                    await saveCache()
                })
        } catch is CancellationError {
        } catch {
            showReadFailure(error, generation: generation)
        }
        guard following?.id == id else { return }
        following = nil
        if isReplaced, !Task.isCancelled { startFollowingUpdates() }
    }

    /// 讀對話紀錄失敗時的畫面狀態。
    private func showReadFailure(_ error: any Error, generation: Int) {
        switch error {
        case TranscriptReadError.absent:
            // 新 session 在第一個 prompt 前可能還沒有檔案：可用的空聊天，下次輪詢再找(R-I09)。
            guard generation == self.generation else { return }
            file = nil
            banner = nil
            phase = .ready
        case TranscriptReadError.unreadable:
            banner = .unreadable
            phase = .ready
        case TranscriptReadError.ambiguous:
            // 不開任何檔、不依新舊猜;下次輪詢重新定位(使用者可能已刪掉多餘的檔)。
            guard generation == self.generation else { return }
            file = nil
            banner = .ambiguous
            phase = .ready
        case TranscriptReadError.compressed:
            // 只有 `.zst`:不是「還沒有檔案」,也不在手機上解壓;下次輪詢重新定位(Codex 可能又寫了新的 rollout)。
            guard generation == self.generation else { return }
            file = nil
            banner = .compressed
            phase = .ready
        default:
            // 保留畫面上的內容，下次輪詢重試;永不退回從 byte 0 追蹤。
            banner = .readFailed
            if items.isEmpty { phase = .ready }
        }
    }

    /// 讀最後 `openLines` 行並**取代**目前的訊息。
    private func openWindow(path: String, size: Int, generation: Int) async throws {
        // 以剛探測到的大小為上限:agent 同時在寫也不會變成無上限的補讀(§4.7)。
        let chunk = try await transcripts.window(path: path, endingAt: size, lines: openLines)
        guard generation == self.generation else { return }
        file = (path, TranscriptFollow(cursor: chunk.end, isLive: true), chunk.start)
        recent = parse(chunk.lines)
        segments = [(chunk.start, recent.count)]
        olderMessages = []
        metadata = format.latestMetadata(in: chunk.lines)
        older = chunk.start > 0 ? .available : .reachedStart
        rebuild()
    }

    private func append(_ chunk: TranscriptChunk) {
        let known = Set(recent.map(\.id))
        let added = parse(chunk.lines).filter { !known.contains($0.id) }
        recent += added
        if !added.isEmpty { segments.append((chunk.start, added.count)) }
        for line in chunk.lines { format.updateMetadata(&metadata, with: line) }
        trimIfFollowing()
        rebuild()
    }

    /// 跟隨尾端時訊息超過上限：丟掉往上翻的舊頁，再整段丟掉最舊的(至少留最後一段),視窗起點移到留下的第一段開頭，
    /// 之後往上翻可以讀回來(#130)。
    private func trimIfFollowing() {
        guard isFollowingLatest, olderMessages.count + recent.count > Self.followingMessageLimit, let first = segments.first else { return }
        olderMessages = []
        var start = first.start
        while recent.count > Self.followingMessageLimit, segments.count > 1 {
            recent.removeFirst(segments.removeFirst().count)
            start = segments[0].start
        }
        file?.windowStart = start
        older = start > 0 ? .available : .reachedStart
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

    /// 讀 snapshot;失敗就立刻靜默重試一次，連續第二次失敗才往外丟(R-B11、F5.3 第 6 點、#133)。
    ///
    /// 第一次失敗多半是連線剛被丟棄(keepalive 逾時、網路切換、喚醒探測):重試在新連線上撥號，使用者不會看到「連線中斷」。
    /// snapshot 是唯讀請求，重送不違反「連線層失敗不重送」(行為規格 §7.3 針對的是寫入)。
    private func snapshotRetryingOnce() async throws -> HostSnapshot {
        do {
            return try await client.snapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await client.snapshot()
        }
    }

    /// 連不上主機：畫面空著時，唯讀顯示同一 session 的快取(只在快取屬於列表看到的 session 時,R-B16)。
    private func showOffline() async {
        isOffline = true
        // 看不到主機畫面，建議可能已過時;恢復連線後重讀(#123)。
        clearSuggestion()
        banner = .offline
        updateWorkingSince()
        if items.isEmpty, let knownSessionID, let cached = await cache.load(chatKey: chatKey), cached.matches(sessionID: knownSessionID) {
            recent = cached.messages
            segments = [(cached.windowStart, cached.messages.count)]
            metadata = cached.metadata
            rebuild()
        }
        if phase == .loading { phase = .ready }
    }

    // MARK: - 在場回報

    /// 每 30 秒回報一次「手機正在看」(F5.13,ttl 45 秒),直到所在的 task 被取消。純裝飾，失敗不影響任何事。
    public func reportPresence(sleep: @escaping Sleep) async {
        while !Task.isCancelled {
            let nowMillis = UInt64(max(0, clock.now().timeIntervalSince1970 * 1000))
            // herdr 忽略不大於上次的 seq(即使過了 TTL):以時鐘起算並保持單調(R-H22)。
            let seq = max(lastPresenceSeq + 1, nowMillis)
            lastPresenceSeq = seq
            let model = metadata.model.map(TranscriptMetadata.displayName(ofModel:))
            try? await client.reportPresence(paneID: paneID, model: model, seq: seq)
            do {
                try await sleep(.seconds(30))
            } catch {
                return
            }
        }
    }

    // MARK: - 送出

    /// 可送 = 不是唯讀裝置、修剪後非空或有圖片、沒有送出進行中、目標可用(載入完、有 agent、連得上)(F6.1)。
    /// 自訂回答時改看回答在途與否，而且不能只送圖片(#120)。
    public var canSend: Bool {
        guard hasTarget, !isReadOnly else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if typedAnswer != nil { return answerInFlight == nil && hasText }
        return !isSending && (hasText || !attachments.isEmpty)
    }

    /// Shell 模式(F6.4):Claude 聊天的草稿以 `!` 開頭，輸入列上方提示會在 agent 的 shell 執行。
    public var isShellMode: Bool {
        guard typedAnswer == nil, let kind = currentAgent?.kind else { return false }
        return PromptDelivery.isShellCommand(draft, kind: kind)
    }

    /// 停止只在 working 時;**永不對 blocked 的 agent**(中斷可能把問題關掉,F6.7)。
    public var canStop: Bool { agentStatus == .working && !isStopping && !isReadOnly }

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
        if let typedAnswer {
            await sendTypedAnswer(typedAnswer)
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        updateWorkingSince()
        defer {
            isSending = false
            updateWorkingSince()
        }
        notice = nil
        draft = ""
        // 送出後舊建議已不適用;下次完成時重讀(herdr 可能來不及回報工作中,#123)。
        clearSuggestion()
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
        case .stopped, .unconfirmed: notice = nil
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
        guard !isReadOnly, answerInFlight == nil, let prompt, inputs(for: answer) != nil else { return false }
        switch answer {
        case .option(let option): return prompt.options.contains(option)
        case .continueMultiSelect: return prompt.isMultiSelect
        case .closePicker: return prompt.kind == .filePicker
        case .generic: return prompt.kind == .unrecognized
        case .typed(let option, _): return prompt.typedAnswerOption(agentKind: answerAgentKind) == option
        }
    }

    /// 回答提示(F8):依 agent 規則送出按鍵(§5.5)。
    ///
    /// 送出前就鎖住所有選項(兩次快速點擊在重繪前就會到);之後每次輪詢判定：提示不見了或換成別的 → 已送達;
    /// 同一個提示超過期限 → 逾時、解鎖並提示可能沒送到;按鍵送不出去 → 立刻解鎖並顯示錯誤(R-Q05)。
    public func answer(_ answer: PromptAnswer) async {
        guard canAnswer(answer), let prompt, let inputs = inputs(for: answer) else { return }
        answerInFlight = answer
        answerSignature = prompt.signature
        answerQuestion = prompt.question
        answerSent = nil
        answerNotice = nil
        haptics.play(.selection)
        do {
            for input in inputs {
                switch input {
                case .keys(let keys): try await client.sendKeys(paneID: paneID, keys: keys)
                case .text(let text): try await client.sendText(paneID: paneID, text: text)
                }
            }
        } catch {
            guard answerInFlight == answer else { return }
            clearAnswer()
            if error as? HostServiceError == .readOnlyDevice {
                // 卡片改顯示唯讀說明，不另外提示。
                isReadOnly = true
                haptics.play(.error)
                return
            }
            answerNotice = .sendFailed
            haptics.play(.error)
            return
        }
        guard answerInFlight == answer else { return }
        answerSent = AnsweredCardAnchor(lastEntryID: entries.last?.id, sentAt: clock.now())
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

    // MARK: 自訂回答(Type something,#120)

    /// 正在用輸入框打自訂答案的「Type something.」選項;`nil` = 一般輸入。
    public private(set) var typedAnswer: PromptOption?
    /// 進入自訂回答前的草稿(結束後放回)。
    private var draftBeforeTypedAnswer = ""
    /// 這次自訂回答打過字了沒有。剛進入時輸入框本來就空，打過字之後再清空才算取消(#127)。
    private var typedAnswerHasText = false

    /// 這個選項是不是要用輸入框打字回答的「Type something.」。
    public func isTypedAnswerOption(_ option: PromptOption) -> Bool {
        prompt?.typedAnswerOption(agentKind: answerAgentKind) == option
    }

    /// 這個「Type something.」現在能不能點(進入自訂回答):沒有回答在途、它是這張問題卡的自訂回答選項。
    /// 已經在自訂回答時也可點(不做事),所以不看 `typedAnswer`。
    public func canBeginTypedAnswer(_ option: PromptOption) -> Bool {
        answerInFlight == nil && isTypedAnswerOption(option)
    }

    /// 這個選項的回答是否正在送出(點選的編號，或以它送出的自訂回答)。
    public func isAnswering(_ option: PromptOption) -> Bool {
        switch answerInFlight {
        case .option(let answered)?, .typed(let answered, _)?: answered == option
        default: false
        }
    }

    /// 點「Type something.」:不送任何按鍵(Claude 收到數字只會把那一列變成文字輸入),改由輸入框打字;
    /// 原本的草稿先收起來，結束時放回。
    public func beginTypedAnswer(_ option: PromptOption) {
        guard canBeginTypedAnswer(option), typedAnswer == nil else { return }
        typedAnswer = option
        typedAnswerHasText = false
        draftBeforeTypedAnswer = draft
        draft = ""
    }

    /// 取消自訂回答，回到一般輸入(什麼都沒送過，不必還原 pane)。
    public func cancelTypedAnswer() {
        guard typedAnswer != nil else { return }
        endTypedAnswer()
    }

    /// 自訂回答時輸入框改了：打過字之後清空 = 取消，回到一般輸入(#127)。
    private func typedAnswerDraftChanged() {
        if !draft.isEmpty {
            typedAnswerHasText = true
        } else if typedAnswerHasText {
            endTypedAnswer()
        }
    }

    private func endTypedAnswer() {
        typedAnswer = nil
        typedAnswerHasText = false
        draft = draftBeforeTypedAnswer
        draftBeforeTypedAnswer = ""
    }

    /// 送出自訂回答：數字 → 文字 → enter(`AnswerKeys.inputs`)。送不出去就回到自訂回答、保留打的字。
    private func sendTypedAnswer(_ option: PromptOption) async {
        let text = draft
        let answer = PromptAnswer.typed(option, text: text)
        guard canAnswer(answer) else { return }
        endTypedAnswer()
        await self.answer(answer)
        if answerNotice == .sendFailed, isTypedAnswerOption(option) {
            beginTypedAnswer(option)
            draft = text
        }
    }

    private func inputs(for answer: PromptAnswer) -> [AnswerInput]? {
        AnswerKeys.inputs(for: answer, agentKind: answerAgentKind)
    }

    /// 回答規則用的 agent 種類(還不知道 agent 時是空字串，走一般規則)。
    private var answerAgentKind: String { agentKind ?? "" }

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
        if let answer = answerInFlight, let sent = answerSent {
            if next == nil || next?.signature != answerSignature {
                // 不再 blocked = 已送達;換成別的提示 = 被取代(通常是下一題),新問題不繼承鎖。
                if case .option(let option) = answer, option.checked != nil {
                    // 勾選只是切換，不是最終的回答。
                } else {
                    lastAnswer = AnsweredPrompt(question: answerQuestion, choice: Self.choiceText(answer))
                    answeredCardAnchor = sent
                }
                clearAnswer()
                haptics.play(.success)
            } else {
                checkAnswerDeadline()
            }
        }
        if next?.signature != prompt?.signature || (next == nil) != (prompt == nil) { prompt = next }
        // 提示換了或不見了(例如在終端機回答掉):自訂回答跟著結束。
        if let typedAnswer, !isTypedAnswerOption(typedAnswer) { endTypedAnswer() }
    }

    private func checkAnswerDeadline() {
        guard answerInFlight != nil, let sentAt = answerSent?.sentAt,
              clock.now().timeIntervalSince(sentAt) > Self.answerDeadline else { return }
        clearAnswer()
        answerNotice = .mayNotHaveArrived
        haptics.play(.error)
    }

    private func clearAnswer() {
        answerInFlight = nil
        answerSignature = nil
        answerQuestion = nil
        answerSent = nil
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
        case .typed(_, let text): text
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
        case .delivered:
            setEcho(id, state: .sent)
            onPromptDelivered?()
            return
        case .submittedCommand:
            setEcho(id, state: .sent)
            watchForPanel()
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
        case .readOnlyDevice:
            isReadOnly = true
            nothingSent = .readOnlyDevice
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
        case .needsAnswer?, .rejected?, .readOnlyDevice?: true
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
        Set(userTurns.map(\.id))
    }

    /// 使用者送出的內容：泡泡，以及 shell 區塊(以 `!指令` 比對回音,F6.4)。
    private var userTurns: [UserBubble] {
        items.compactMap { item -> UserBubble? in
            switch item {
            case .user(let bubble): bubble
            case .shell(let run): UserBubble(id: run.id, text: "!" + run.command, date: run.date, imageCount: 0)
            default: nil
            }
        }
    }

    /// 以對話紀錄確認回音;確認了任何一則就清掉送出警告(R-P11:輪詢成功本身不清)。
    private func rebuildEntries() {
        let bubbles = userTurns
        let remaining = EchoMatching.confirm(echoes, against: bubbles, consumed: &consumedUserIDs)
        if remaining.count < echoes.count {
            echoes = remaining
            notice = nil
        }
        let merged = EchoTimeline.merge(items: items, echoes: echoes)
        if !merged.map(\.id).elementsEqual(entries.map(\.id)) { entriesRevision &+= 1 }
        entries = merged
        refreshAnsweredCard()
    }

    /// 已回答卡片：Agent 寫出新的文字，或只有工具步驟但已過保留時間就收起(#213)。
    private func refreshAnsweredCard() {
        guard let anchor = answeredCardAnchor, !anchor.isShowing(rows: answeredCardRows, at: clock.now()) else { return }
        lastAnswer = nil
        answeredCardAnchor = nil
    }

    /// 已回答卡片去留規則看的對話列。
    private var answeredCardRows: [AnsweredCardAnchor.Row] {
        entries.map { entry in
            let showsText = switch entry {
            case .item(.agentText), .item(.user), .item(.shell), .echo: true
            case .item: false
            }
            return AnsweredCardAnchor.Row(id: entry.id, showsText: showsText)
        }
    }

    // MARK: - Slash 點選與面板(#45)

    /// 點選 slash 指令：一律只填入 `/名稱 `,由使用者自己按送出(#83,刻意偏離行為規格 F9.3 的直接送出)。
    public func pick(slash command: SlashCommand) {
        draft = "/\(command.name) "
        pickedHint = command.argumentHint.map { (draft, $0) }
    }

    /// 點選後游標後淡淡顯示的參數提示;使用者開始打參數(草稿改變)就消失。
    public var slashArgumentHint: String? {
        guard let pickedHint, pickedHint.draft == draft else { return nil }
        return pickedHint.hint
    }

    @ObservationIgnored private var pickedHint: (draft: String, hint: String)?

    /// slash 指令開出的面板(F9.4);沒有面板為 `nil`。
    public private(set) var panel: SlashPanel?
    /// 面板按鍵送出中(卡片上的操作暫時停用)。
    public private(set) var isOperatingPanel = false
    /// 面板監看到這個時間為止(送出 slash 指令或操作面板後 8 秒)。
    private var panelWatchUntil: Date?
    @ObservationIgnored private var panelKickTask: Task<Void, Never>?

    /// 面板卡片的操作：送方向鍵或面板自己的動作鍵，**永不送數字**(R-C04)。送完 0.3 秒後重讀，並把監看延長 8 秒
    /// (面板可能接著出確認畫面)。
    public func operatePanel(_ input: SlashPanel.Input) async {
        guard !isOperatingPanel, let panel, let keys = panel.keys(for: input), !keys.isEmpty else { return }
        isOperatingPanel = true
        defer { isOperatingPanel = false }
        haptics.play(.selection)
        do {
            try await client.sendKeys(paneID: paneID, keys: keys)
        } catch {
            notice = .panelKeysFailed
            haptics.play(.error)
            return
        }
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        kickPolls(after: [.milliseconds(300)])
    }

    private static let panelWatch: TimeInterval = 8

    /// 面板對 herdr 不可見(狀態仍是 idle):送出 slash 指令後監看 8 秒，0.4 秒與 1.2 秒各多讀一次。
    private func watchForPanel() {
        guard let kind = currentAgent?.kind, Self.panelAgents.contains(kind) else { return }
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        kickPolls(after: [.milliseconds(400), .milliseconds(800)])
    }

    private static let panelAgents: Set<String> = ["claude", "codex"]

    private func kickPolls(after delays: [Duration]) {
        panelKickTask?.cancel()
        panelKickTask = Task { [weak self, sleep] in
            for delay in delays {
                do { try await sleep(delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// 監看中或面板開著時讀畫面(只限 Claude／Codex、沒有問題在等、agent 不在工作);這次輪詢已讀過畫面就順便看。
    /// 讀不到畫面沿用上次;畫面上沒有面板、或 agent 開始工作／需要你時關掉。
    private func refreshPanel(_ agent: Agent) async {
        let watching = panelWatchUntil.map { clock.now() < $0 } ?? false
        if !watching { panelWatchUntil = nil }
        guard Self.panelAgents.contains(agent.kind), prompt == nil, agentStatus != .working, agentStatus != .blocked else {
            panel = nil
            return
        }
        guard watching || panel != nil || screenThisPoll != nil else { return }
        if screenThisPoll == nil { screenThisPoll = try? await client.readPane(paneID: paneID) }
        guard let screen = screenThisPoll else { return }
        let next = SlashPanelParser.parse(screen: screen, agentKind: agent.kind)
        if next != panel { panel = next }
    }

    // MARK: - 建議提示詞(#121、#123)

    /// 輸入列上方要顯示的 Claude Code 建議提示詞;沒有建議、或輸入框已有文字時為 `nil`
    /// (不蓋掉使用者打的字，#121 故事 4)。
    public var suggestion: String? { draft.isEmpty ? detectedSuggestion : nil }

    /// 接受建議：只把文字填入輸入框，**不送任何 herdr 請求**(同 slash 選定,#83)。
    /// 沒有顯示中的建議(例如輸入框已有字)時什麼都不做並回傳 `false`(硬體鍵盤的 Tab 照常交給系統)。
    @discardableResult
    public func acceptSuggestion() -> Bool {
        guard let suggestion else { return false }
        draft = suggestion
        return true
    }

    /// 從 Pane 畫面認出的建議(輸入框有字時保留，清空後再顯示)。
    private var detectedSuggestion: String?
    /// 這段完成期間還能讀幾次畫面找建議。Claude Code 回完之後才另外產生建議，第一次讀常常還沒有，
    /// 所以沒讀到時之後的輪詢再讀，讀到就停;次數有上限(指令預算 R-F01)。離開完成、送出、離線時重來。
    @ObservationIgnored private var suggestionReadsLeft = ConversationModel.suggestionReadLimit
    /// 每次清掉建議就加一:在途的讀取回來時若已不同，結果作廢(期間送出過，舊建議不適用)。
    @ObservationIgnored private var suggestionEpoch = 0

    /// 同一段完成期間最多讀幾次畫面找建議。
    static let suggestionReadLimit = 3

    /// 一次讀畫面認出的建議(可能沒有)與讀取開始時的 epoch。
    private struct SuggestionRead {
        var suggestion: String?
        var epoch: Int
    }

    /// Claude Code 在等下一步(完成或閒置——閒置是 herdr 把完成標成看過，#121 故事 5;沒有提示)。
    private func awaitsNextPrompt(_ agent: Agent) -> Bool {
        agent.kind == "claude" && (agentStatus == .done || agentStatus == .idle) && prompt == nil
    }

    /// 在等下一步、這段期間還能讀時，讀含 ANSI 的畫面找建議(#121)。在面板判定之前讀，讀到的畫面去掉 ANSI 後
    /// 給這次輪詢的面板、背景 agents 窗格共用(R-F02);這次輪詢已讀過純文字畫面(分不出灰色建議)就留到下次。
    /// 讀取期間建議被清掉(送出)時結果作廢，畫面也不共用。
    private func readSuggestion(_ agent: Agent) async -> SuggestionRead? {
        guard awaitsNextPrompt(agent), suggestionReadsLeft > 0, screenThisPoll == nil else { return nil }
        let epoch = suggestionEpoch
        suggestionReadsLeft -= 1
        guard let screen = try? await client.readPane(paneID: paneID, format: .ansi), epoch == suggestionEpoch else { return nil }
        screenThisPoll = Self.plainText(ansi: screen)
        return SuggestionRead(suggestion: PromptSuggestion.detect(screen: screen), epoch: epoch)
    }

    /// 面板判定之後才決定：不在等下一步、或面板開著就拿掉;這次有讀到就換上(讀到建議後這段期間不再讀)。
    private func applySuggestion(_ read: SuggestionRead?, agent: Agent) {
        guard awaitsNextPrompt(agent), panel == nil else {
            clearSuggestion()
            return
        }
        guard let read, read.epoch == suggestionEpoch else { return }
        detectedSuggestion = read.suggestion
        if read.suggestion != nil { suggestionReadsLeft = 0 }
    }

    private func clearSuggestion() {
        detectedSuggestion = nil
        suggestionReadsLeft = Self.suggestionReadLimit
        suggestionEpoch += 1
    }

    /// 去掉跳脫序列與 `\r`:`.ansi` 畫面只差在跳脫序列與行尾，其他解析器吃的是純文字。
    static func plainText(ansi screen: String) -> String {
        ANSIText.strip(screen).replacingOccurrences(of: "\r", with: "")
    }

    // MARK: - 標題列(#44)

    /// 標題下一行的資訊(F5.7)。
    public var header: ConversationHeader {
        ConversationHeader(agent: currentAgent, title: title, metadata: metadata, status: agentStatus, isOffline: isOffline, hostName: hostName())
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
    /// 從 pane 可見畫面擷取到的散文(只在 working 時);沒有真正的散文，或已寫進對話紀錄的最後一則回覆時為 `nil`(#208)。
    public var livePreview: String? {
        guard let screenPreview else { return nil }
        guard let reply = Conversation.latestReplyText(in: recent) else { return screenPreview }
        return LivePreview.isWritten(screenPreview, in: reply) ? nil : screenPreview
    }

    /// 這次輪詢從畫面擷取到的散文，尚未與對話紀錄去重。
    private var screenPreview: String?

    /// working 時讀 pane 可見畫面擷取即時預覽(與背景 agents 窗格共用同一次讀取);還沒到讀取時間沿用上次的(#204)。
    private func refreshLivePreview() async {
        if agentStatus == .working, prompt == nil {
            if workingScreenDue {
                if screenThisPoll == nil { screenThisPoll = try? await client.readPane(paneID: paneID) }
                screenPreview = screenThisPoll.flatMap(LivePreview.extract(screen:))
            }
        } else {
            screenPreview = nil
        }
        updateWorkingSince()
    }

    private func updateWorkingSince() {
        if !showsWorkingIndicator {
            workingSince = nil
            screenPreview = nil
        } else if workingSince == nil {
            workingSince = clock.now()
        }
    }

    // MARK: - 內部

    private func unbind() {
        stopFollowingUpdates()
        if let path = file?.path {
            let transcripts = transcripts
            Task { await transcripts.stopFollowing(path: path) }
        }
        generation += 1
        workflowModels = [:]
        boundSessionID = nil
        file = nil
        recent = []
        segments = []
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

    /// 寫入快取：最多 `CachedConversation.maxMessages` 則(R-B13),以整段為單位從尾端取，視窗起點是取到的第一段開頭，
    /// 從快取恢復後往上翻接得上;往上翻的舊頁不寫入(F5.2)。最後一段本身就超過上限時只存它的最後幾則(往上翻會缺這段的前面)。
    private func saveCache() async {
        guard let boundSessionID, let file else { return }
        var count = 0
        var first = segments.count
        while first > 0, count + segments[first - 1].count <= CachedConversation.maxMessages {
            first -= 1
            count += segments[first].count
        }
        if first == segments.count, let last = segments.last {
            first = segments.count - 1
            count = last.count
        }
        let windowStart = first < segments.count ? segments[first].start : file.windowStart
        await cache.save(
            CachedConversation(
                sessionID: boundSessionID, messages: Array(recent.suffix(count)), metadata: metadata, path: file.path,
                cursor: file.follow.cursor, windowStart: windowStart
            ),
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
    /// 原始圖片超過單張上限(`ImageUploadLimit.maximumSize`)。
    case imageTooLarge
    /// 圖片上傳失敗：整則沒送出，草稿與圖片保留。
    case uploadFailed
    /// 停止後 3 秒仍在工作。
    case stillWorking
    /// 送不出中斷的按鍵。
    case interruptFailed
    /// 送出停止後讀不到狀態，不知道停了沒(#220)。
    case stopUnconfirmed
    /// 送不出 slash 面板的按鍵(#45)。
    case panelKeysFailed
    /// agent 在等你回答，所以沒有送出中斷(F6.7)。
    case interruptRefusedNeedsAnswer
    /// 這支裝置配對成唯讀，什麼都沒送出。
    case readOnlyDevice
}
