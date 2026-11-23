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
        /// 已知 session,但它的對話紀錄檔還不存在(`/clear`、重開、resume 後，Claude Code 要到第一則提示詞才建立新檔)。
        /// 電腦上的 Pane 此時可能還顯示舊 session 的畫面，所以不說「還沒有訊息」(#418)。送出後檔案出現，下一次讀取就接上。
        case newConversation
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
    /// 重新載入、換 session 的讀取進行中:畫面保留舊訊息，只顯示不遮擋的更新指示(#329)。
    public private(set) var isRefreshing = false
    /// 載入超過這麼久才出現系統進度指示(HIG〈Loading〉:內容理想上立刻出現，等待超過一兩秒才用進度指示)。
    nonisolated public static let loadingIndicatorDelay: Duration = .seconds(1.5)
    private var loadingIndicatorArmed = false
    /// 還沒有任何內容、載入已超過 `loadingIndicatorDelay`:畫面在骨架下方加系統進度指示。有快取或內容先到就不會出現。
    public var showsLoadingIndicator: Bool { loadingIndicatorArmed && phase == .loading && items.isEmpty }
    public private(set) var items: [ConversationItem] = []
    /// 畫面上是快取的內容(離線)。
    public private(set) var isOffline = false
    public private(set) var banner: Banner?
    public private(set) var older: Older = .reachedStart
    /// 導覽列標題;永不顯示 `w1` 這類 id(R-V10)。
    public private(set) var title = ""
    /// Tab 名稱(#476):標題膠囊顯示;每次輪詢由 snapshot 更新。
    public private(set) var tabName = ""
    public private(set) var agentStatus: AgentStatus?
    public private(set) var metadata = TranscriptMetadata()
    /// context 百分比與待辦進度(#307),由讀到的對話紀錄推得;標題列與待辦 sheet 用。
    public private(set) var progress = AgentProgress()
    /// Claude Code 的 status line 為這個 session 回報的狀態(#388);沒有(未安裝、API key、舊版主機服務、讀不到)時是 `nil`,
    /// context 退回對話紀錄算法(`progress`)。
    public private(set) var sessionStatus: ClaudeSessionStatus?
    /// 讀 session 狀態的來源(SSH 主機上的 session 檔、HTTPS 的 `usage.session_context`);`nil` 時只用退回算法。
    public var sessionStatusReader: (any ClaudeSessionStatusReading)?
    /// 各 Agent 種類自己的 session 狀態來源(Antigravity 的 statusline 包裝,#448);沒有的種類用 `sessionStatusReader`。
    public var agentSessionStatusReaders: [AgentID: any ClaudeSessionStatusReading] = [:]

    /// 有狀態列的 Agent(Antigravity)裝了 statusline 包裝時,從 session 檔讀到的模式、模型與 effort(優先於畫面狀態列,#448);沒有是 `nil`。
    private var statusFileLine: AgentStatusLine? {
        guard screenDialect.statusLine != nil, let status = sessionStatus else { return nil }
        return AgentStatusLine(
            mode: status.cycleMode.flatMap { AgentPermissionMode(antigravityCycleMode: $0) }, model: status.antigravityModelName,
            effort: status.effort)
    }
    @ObservationIgnored private var sessionStatusReadAt: Date?
    /// 兩次讀 session 狀態的最短間隔(秒):輪詢每 2 秒一輪,不必每輪都問主機。
    nonisolated public static let sessionStatusInterval: TimeInterval = 10

    /// 標題列與面板用的進度:有 status line 的 context 就以它為準(與 Claude Code 實際顯示一致),否則是對話紀錄算出的。
    public var displayProgress: AgentProgress {
        var result = progress
        if let percent = sessionStatus?.contextPercent { result.contextPercent = Int(percent.rounded()) }
        return result
    }
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
            if !isComposingDraft { slash.update(draft: draft, caret: draftCaret) }
        }
    }
    /// 輸入框回報的游標(UTF-16 位置;有選取範圍時為 `nil`),連同當時的文字。
    @ObservationIgnored private var reportedCaret: (text: String, caret: Int?)?
    /// 草稿的游標(UTF-16 位置;有選取範圍時為 `nil`)。輸入框沒回報過這份草稿時視為在結尾。
    public var draftCaret: Int? {
        if let reportedCaret, reportedCaret.text == draft { return reportedCaret.caret }
        return draft.utf16.count
    }
    /// 已知的游標(輸入框回報過或選定 slash 指令時指定);輸入框程式改寫草稿時把游標放這裡。
    public var knownDraftCaret: Int? {
        guard let reportedCaret, reportedCaret.text == draft else { return nil }
        return reportedCaret.caret
    }

    /// 輸入框的游標或選取範圍改變時呼叫(#230)。文字先回報游標再寫草稿，slash 選單只更新一次。
    public func updateDraftCaret(_ caret: Int?, in text: String) {
        if let reportedCaret, reportedCaret.text == text, reportedCaret.caret == caret { return }
        reportedCaret = (text, caret)
        guard text == draft, typedAnswer == nil, !isComposingDraft else { return }
        slash.update(draft: draft, caret: caret)
    }
    /// 輸入框正在組字(有 marked text)。組字中不拿暫時文字篩選 slash 選單(#138)。
    public var isComposingDraft = false {
        didSet {
            if oldValue, !isComposingDraft, typedAnswer == nil { slash.update(draft: draft, caret: draftCaret) }
        }
    }
    /// 選取中主機的「You should know」註記(#23);由 `HostsModel` 接上，沒有時不顯示。
    public var youShouldKnow: YouShouldKnowModel?
    /// 圖片卡片的縮圖載入(#225):聊天所在主機的那份，由 `HostsModel` 接上;沒有時卡片不載入縮圖。
    public var agentFiles: AgentFileLoads?
    /// 變更頁的 git 讀取(#310):聊天所在主機的連線方式，由 `HostsModel` 接上;沒有時不顯示變更鈕。
    public var gitChanges: (any GitChangesReading)?

    /// 這個 Agent 工作目錄的變更頁;沒有 git 讀取或還不知道工作目錄時是 `nil`。
    public func makeChanges() -> ChangesModel? {
        guard let gitChanges, let cwd = currentAgent?.cwd else { return nil }
        return ChangesModel(reader: gitChanges, cwd: cwd) { [weak self] in self?.canSendReview ?? false }
    }

    /// 能不能開變更頁(有 git 讀取、知道 Agent 的工作目錄)。
    public var canOpenChanges: Bool { gitChanges != nil && currentAgent?.cwd != nil }

    /// 更多選單裡「Git 變更」項目的狀態(#381):可用時帶分支與檔案數，不可用時停用並寫原因。
    public enum GitMenuState: Sendable, Equatable {
        /// 還沒讀過(或暫時讀不到):項目可點，進變更頁自己再讀。
        case checking
        case available(branch: String?, fileCount: Int)
        case unavailable(GitUnavailableReason)

        public var isEnabled: Bool {
            if case .unavailable = self { false } else { true }
        }
    }

    public enum GitUnavailableReason: Sendable, Equatable {
        /// 這種連線方式或主機讀不了 git(含還不知道 Agent 的工作目錄)。
        case unsupported
        case notGitRepository
        case gitNotInstalled
        case agentMoved
        case hostServiceUpdateRequired
    }

    public private(set) var gitMenu: GitMenuState = .checking

    /// 讀一次 git 狀態，更新更多選單的「Git 變更」項目。只有明確的原因才停用;暫時讀不到維持可點。
    public func refreshGitMenu() async {
        guard let gitChanges else {
            gitMenu = .unavailable(.unsupported)
            return
        }
        guard let cwd = currentAgent?.cwd else {
            gitMenu = .checking
            return
        }
        do {
            let status = try await gitChanges.gitStatus(cwd: cwd)
            gitMenu = .available(branch: status.branch, fileCount: status.files.count)
        } catch {
            switch ChangesProblem(error) {
            case .unsupported: gitMenu = .unavailable(.unsupported)
            case .notGitRepository: gitMenu = .unavailable(.notGitRepository)
            case .gitNotInstalled: gitMenu = .unavailable(.gitNotInstalled)
            case .agentMoved: gitMenu = .unavailable(.agentMoved)
            case .hostServiceUpdateRequired: gitMenu = .unavailable(.hostServiceUpdateRequired)
            case .failed: gitMenu = .checking
            }
        }
    }

    /// 能不能送出變更頁的評論：與輸入列相同的目標條件(唯讀、離線、送出中都不行)。
    public var canSendReview: Bool { hasTarget && !isReadOnly && !isSending && typedAnswer == nil }

    /// 主機取檔的存取範圍(#225):Agent 的工作目錄、目前對話紀錄裡 Agent 寫出的路徑(#229)、對話紀錄本身(附檔資料夾),
    /// 與使用者 prompt 裡的路徑(只放行 Purrdr 上傳資料夾，#428)。
    public var fileAccessScope: HostFileAccessScope {
        HostFileAccessScope(
            workingDirectories: currentAgent?.cwd.map { [$0] } ?? [], mentionedPaths: HostFileAccessScope.mentionedPaths(in: items),
            transcriptPaths: file.map { [$0.path] } ?? [], promptMentionedPaths: HostFileAccessScope.promptMentionedPaths(in: items))
    }

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

    /// 一則最多幾個附件(圖片與檔案合計,#352)。
    public static let maximumAttachments = 10
    /// 輸入列上的圖片附件(送出被接受時才清)。
    public private(set) var attachments: [ComposerAttachment] = []
    @ObservationIgnored private let images: ComposerImages?
    /// 這台主機能不能附加圖片(有上傳器;目前只有 Unix 主機)。
    public var canAttachImages: Bool { images != nil }
    public var remainingImageSlots: Int { max(0, Self.maximumAttachments - attachments.count) }

    /// 加入圖片(相簿、相機、貼上):長邊縮到 2048px、JPEG,存手機副本。超過 4 張的部分、原始大小超過單張上限的不加入並提示。
    public func addImages(_ items: [Data]) async {
        guard let images, !items.isEmpty else { return }
        if items.count > remainingImageSlots { notice = .attachmentLimit }
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
            attachments.append(
                ComposerAttachment(
                    fileName: HostUploadName(name), byteCount: prepared.jpeg.count, pixelWidth: prepared.width, pixelHeight: prepared.height))
            saveAttachments()
        }
    }

    /// 已滿時點「附加」:提示上限(F7)。
    public func noteImageLimit() { notice = .attachmentLimit }

    /// 「+」現在能不能用(#382):離線停用、滿了提示上限。
    public var attachAvailability: ComposerAttachAvailability {
        ComposerAttachAvailability.resolve(isOffline: isOffline, remainingSlots: remainingImageSlots)
    }

    /// 點「+」:可以就回傳 `true`(畫面升起面板);否則放說明提示、回傳 `false`。
    public func requestAttach() -> Bool {
        switch attachAvailability {
        case .available: return true
        case .offline: notice = .attachOffline
        case .limitReached: notice = .attachmentLimit
        }
        return false
    }

    /// 輸入框提示文字的種類(#382)。
    public var placeholderKind: ComposerPlaceholderKind {
        ComposerPlaceholderKind.choose(hasTypedAnswer: typedAnswer != nil, hasPendingPrompt: prompt != nil)
    }

    /// 移除附件。送出(上傳)中不能移除。
    public func removeAttachment(_ id: String) {
        guard !isSending else { return }
        if let removed = attachments.first(where: { $0.id == id }), removed.kind == .file { removeStoredCopies(of: removed) }
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

    // MARK: 檔案(#286)

    /// 正在讀取、準備加成附件的檔案(原始檔名);沒有時是 `nil`。
    public private(set) var loadingFileName: String?
    /// 能不能附加檔案：有上傳到主機、不是唯讀裝置。
    public var canAttachFiles: Bool { images != nil && !isReadOnly }

    /// 附加一般檔案：讀進來存手機副本、在輸入列成一張附件卡，送出時才上傳(#352)。已知大小超過上限時不讀內容。
    /// 圖片檔(副檔名 png、jpg…)走圖片附件，與相簿一致。
    public func addFile(named originalName: String, size: Int?, load: @Sendable () async throws -> Data) async {
        guard let images, canAttachFiles, loadingFileName == nil else { return }
        guard remainingImageSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        let limit = HostUploadLimit.maximumFileSize
        if let size, size > limit {
            notice = .fileTooLarge(size: size, limit: limit)
            return
        }
        loadingFileName = originalName
        defer { loadingFileName = nil }
        let data: Data
        do {
            data = try await load()
        } catch {
            notice = .fileUnreadable
            return
        }
        guard data.count <= limit else {
            notice = .fileTooLarge(size: data.count, limit: limit)
            return
        }
        if UploadedImages.hasImageExtension(originalName) {
            await addImages([data])
            return
        }
        guard remainingImageSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        let name = images.makeFileName(originalName)
        do {
            try images.store.save(data, as: name.value)
        } catch {
            notice = .fileUnreadable
            return
        }
        attachments.append(ComposerAttachment(kind: .file, fileName: name, displayName: originalName, byteCount: data.count))
        saveAttachments()
    }

    // MARK: 影片(#474)

    /// 影片準備中(取出、壓縮)的進度;沒有時是 `nil`。
    public private(set) var videoPreparation: VideoPreparation?
    /// 能不能附加影片：能附加檔案、又有壓縮器。
    public var canAttachVideos: Bool { canAttachFiles && images?.videoCompressor != nil }

    @ObservationIgnored private var videoTask: Task<VideoOutcome, Never>?
    /// 目前這一次準備的識別;取消或換新一次後,舊的結果回來(挑選器不回應取消)就丟掉。
    @ObservationIgnored private var videoToken: UUID?

    private enum VideoOutcome: Sendable {
        /// 已經搬進手機副本。
        case ready(fileName: HostUploadName, displayName: String, byteCount: Int, duration: TimeInterval?, thumbnailFileName: String?)
        case tooLong
        case unreadable
        case cancelled
    }

    /// 附加相簿影片(#474):`load` 取出影片檔(可能要從 iCloud 下載;檔案交給這裡，用完會刪)。
    public func addVideo(displayName: String, load: @escaping @Sendable () async throws -> URL) async {
        await addPickedVideo(displayName: displayName, load: { VideoSourceFile(try await load()) })
    }

    /// 附加相簿影片(#474):沒超過上限就原樣加成附件卡;超過就由高到低壓縮，第一個放得下的畫質就是結果;
    /// 壓到最小仍超過、或太長，提示後不加入。與檔案一樣先留在輸入列，送出才上傳。可用 `cancelVideoPreparation()` 取消。
    /// 取出、壓縮與搬進手機副本都在背景做(最多 25 MiB 不佔主執行緒)，副檔名依實際格式。
    public func addPickedVideo(displayName: String, load: @escaping @Sendable () async throws -> VideoSourceFile) async {
        guard let images, let compressor = images.videoCompressor, canAttachFiles, videoPreparation == nil, loadingFileName == nil else { return }
        guard remainingImageSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        videoPreparation = VideoPreparation(displayName: displayName, phase: .loading, fraction: nil)
        let token = UUID()
        videoToken = token
        let limit = HostUploadLimit.maximumFileSize
        let task = Task.detached { [weak self] () -> VideoOutcome in
            let picked: VideoSourceFile
            do { picked = try await load() } catch { return Task.isCancelled ? .cancelled : .unreadable }
            defer { try? FileManager.default.removeItem(at: picked.discard) }
            // 挑選器不回應取消:回來時已經取消就整個丟掉。
            if Task.isCancelled { return .cancelled }
            let source = picked.url
            do {
                let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if sourceSize <= limit {
                    let ext = source.pathExtension.lowercased()
                    return try await Self.storeVideo(source, displayName: displayName, fileExtension: ext.isEmpty ? nil : ext, images: images, compressor: compressor)
                }
                let candidates = VideoQuality.candidates(forDuration: try await compressor.duration(of: source), limit: limit)
                await self?.setVideoPhase(.shrinking, token: token)
                for quality in candidates {
                    let output = FileManager.default.temporaryDirectory.appending(path: "purrdr-video-\(UUID().uuidString).mp4")
                    defer { try? FileManager.default.removeItem(at: output) }
                    try await compressor.compress(source, quality: quality, to: output) { fraction in
                        Task { @MainActor in self?.setVideoFraction(fraction, token: token) }
                    }
                    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                    if size <= limit {
                        if Task.isCancelled { return .cancelled }
                        return try await Self.storeVideo(output, displayName: displayName, fileExtension: "mp4", images: images, compressor: compressor)
                    }
                }
                return .tooLong
            } catch {
                return Task.isCancelled || error is CancellationError ? .cancelled : .unreadable
            }
        }
        videoTask = task
        let outcome = await task.value
        // 取消(或已經換成新的一次)後回來的結果:不加入，已搬進副本的刪掉。
        guard videoToken == token else {
            if case .ready(let fileName, _, _, _, let thumbnail) = outcome {
                images.store.remove(fileName.value)
                if let thumbnail { images.store.remove(thumbnail) }
            }
            return
        }
        videoTask = nil
        videoToken = nil
        videoPreparation = nil
        switch outcome {
        case .cancelled: break
        case .tooLong: notice = .videoTooLong
        case .unreadable: notice = .videoUnreadable
        case .ready(let fileName, let name, let byteCount, let duration, let thumbnail):
            guard remainingImageSlots > 0 else {
                images.store.remove(fileName.value)
                if let thumbnail { images.store.remove(thumbnail) }
                notice = .attachmentLimit
                return
            }
            attachments.append(
                ComposerAttachment(
                    kind: .file, fileName: fileName, displayName: name, byteCount: byteCount, duration: duration, thumbnailFileName: thumbnail))
            saveAttachments()
        }
    }

    /// 把影片檔搬進手機副本(背景)。`fileExtension` 是實際格式,沒有就沿用顯示名稱的。
    private nonisolated static func storeVideo(
        _ file: URL, displayName: String, fileExtension: String?, images: ComposerImages, compressor: any VideoCompressing
    ) async throws -> VideoOutcome {
        var name = displayName
        if let fileExtension { name = (displayName as NSString).deletingPathExtension + "." + fileExtension }
        let byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let uploadName = images.makeFileName(name)
        // 長度與縮圖在搬走檔案之前取(取不到就沒有,卡片照常顯示)。
        let duration = try? await compressor.duration(of: file)
        var thumbnailName: String?
        if let thumbnail = await compressor.thumbnail(of: file) {
            let stem = (uploadName.value as NSString).deletingPathExtension
            if (try? images.store.save(thumbnail, as: stem + "-thumb.jpg")) != nil { thumbnailName = stem + "-thumb.jpg" }
        }
        do {
            try images.store.save(movingFile: file, as: uploadName.value)
        } catch {
            if let thumbnailName { images.store.remove(thumbnailName) }
            throw error
        }
        return .ready(fileName: uploadName, displayName: name, byteCount: byteCount, duration: duration, thumbnailFileName: thumbnailName)
    }

    private func setVideoPhase(_ phase: VideoPreparation.Phase, token: UUID) {
        guard videoToken == token else { return }
        videoPreparation?.phase = phase
    }

    private func setVideoFraction(_ fraction: Double, token: UUID) {
        guard videoToken == token else { return }
        videoPreparation?.fraction = fraction
    }

    /// 取消影片準備(取出或壓縮中):立刻恢復輸入列;不加入、不提示，暫存檔刪掉。
    public func cancelVideoPreparation() {
        videoTask?.cancel()
        videoTask = nil
        videoToken = nil
        videoPreparation = nil
    }

    /// 主機服務太舊時提示更新，其他失敗用 `otherwise`。
    private static func uploadNotice(for error: any Error, otherwise: SendNotice) -> SendNotice {
        guard case .hostServiceUpdateRequired(_, let installedVersion)? = error as? HostServiceError else { return otherwise }
        return .hostServiceUpdateRequired(installedVersion: installedVersion)
    }

    /// 影片大到行動網路上傳前要先提醒的大小(10 MiB)。
    package nonisolated static let cellularWarningBytes = 10 * 1024 * 1024
    /// 等使用者確認的行動網路上傳提醒(這次要上傳的影片位元組數);沒有提醒時是 `nil`。
    public private(set) var cellularUploadWarning: Int?
    @ObservationIgnored private var cellularConfirmed = false

    private var needsCellularConfirmation: Bool {
        guard !cellularConfirmed, let images, images.isOnCellular() else { return false }
        return attachments.contains { $0.uploadedPath == nil && $0.duration != nil && $0.byteCount >= Self.cellularWarningBytes }
    }

    /// 使用者確認用行動網路上傳:接著照常送出。
    public func confirmCellularUpload() async {
        cellularUploadWarning = nil
        cellularConfirmed = true
        defer { cellularConfirmed = false }
        await send()
    }

    public func dismissCellularWarning() { cellularUploadWarning = nil }

    /// 刪掉檔案附件的手機副本(影片連縮圖)。
    private func removeStoredCopies(of attachment: ComposerAttachment) {
        images?.store.remove(attachment.fileName.value)
        if let thumbnail = attachment.thumbnailFileName { images?.store.remove(thumbnail) }
    }

    /// 送出時上傳中的附件進度;沒有在上傳時是 `nil`。
    public private(set) var uploadProgress: UploadProgress?
    @ObservationIgnored private var uploadTask: Task<[String], any Error>?

    /// 取消送出時的上傳(使用者按取消):附件與草稿留著,不提示。SSH 主機上的暫存檔因連線提早結束而刪掉。
    public func cancelUpload() { uploadTask?.cancel() }

    /// 依序上傳還沒上傳的附件(已上傳的沿用路徑)。任何一張失敗丟出那個錯誤：整則不送(F6.5)。
    private func uploadAttachments() async throws -> [String] {
        guard let images else {
            guard attachments.isEmpty else { throw HostServiceError.unsupported("upload") }
            return []
        }
        var paths: [String] = []
        for index in attachments.indices {
            if let path = attachments[index].uploadedPath {
                paths.append(path)
                continue
            }
            let name = attachments[index].fileName
            guard let url = images.store.url(of: name.value) else { throw CocoaError(.fileReadNoSuchFile) }
            // 分塊讀檔上傳(影片最多 25 MiB,不整份進記憶體),回報進度。
            let source = try HostUploadSource.file(at: url)
            uploadProgress = UploadProgress(displayName: attachments[index].displayName, fraction: 0)
            defer { uploadProgress = nil }
            let path = try await images.uploader.upload(source, named: name) { [weak self] fraction in
                Task { @MainActor in self?.uploadProgress?.fraction = fraction }
            }
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
    public var isStopping: Bool { stopPhase == .stopping }
    /// 停止列顯示的停止進度或結果(#220)。
    public private(set) var stopPhase: StopPhase?
    /// 強制結束的確認對話框是否開著(#220;停止列與「仍在工作」結果共用)。
    public var confirmsForceQuit = false
    /// 狀態 sheet 是否開著(#349):點標題或工作中膠囊的子 Agent 數都開同一張。
    public var showsStatusSheet = false
    /// 斷線前 agent 在工作：離線橫幅說明重新連上後才能停止(#220)。
    public private(set) var stopNeedsReconnect = false
    /// 停止中最多等多久，之後當成仍在工作。
    public nonisolated static let stopTimeout: Duration = .seconds(10)

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
    private let openMaxBytes: Int
    private let pageLines: Int
    /// 列表傳來的 session:快取只在與它相同時秒開或離線顯示(F5.3、#97)。
    private let knownSessionID: String?
    private let drafts: DraftStore
    private let delivery: PromptDelivery
    /// 送出前依序經過的步驟(#299):機密偵測、撤回倒數、離線佇列…由建立者注入。
    private let sendPipeline: SendPipeline
    /// 送出管線裡的撤回倒數(#300):畫面以它在對話最下面畫出倒數中的訊息;沒有這個步驟時是 `nil`。
    public var undoSend: UndoSendCountdown? { sendPipeline.step(UndoSendCountdown.self) }
    /// 管線裡的離線佇列(#301):離線時送出的訊息排在這台主機的佇列;沒有這個步驟時離線不能送出。
    public var offlineQueue: OfflineQueue? { sendPipeline.step(OfflineQueueStep.self)?.queue }
    /// 這個聊天(pane)排隊中與沒送出的訊息，畫在對話最下面。
    public var queuedPrompts: [QueuedPrompt] { offlineQueue?.entries(forPane: paneID) ?? [] }

    /// 放回輸入框：拿出佇列，文字接在目前的草稿前面(不蓋掉新打的)。
    public func putBack(_ id: QueuedPrompt.ID) {
        guard let text = offlineQueue?.takeBack(id) else { return }
        putBackInDraft(text)
    }

    /// 取消排隊中的訊息，或刪除沒送出的。
    public func deleteQueued(_ id: QueuedPrompt.ID) {
        offlineQueue?.remove(id)
    }

    /// 管線裡的 Send When Done(#305):輸入列的「做完再送」開關與主機上的佇列;沒有這個步驟時是 `nil`。
    public var sendWhenDone: SendWhenDoneModel? { sendPipeline.step(SendWhenDoneStep.self)?.model }

    /// 編輯 Send When Done 佇列裡的一則:從主機佇列拿掉，文字放回輸入框(接在目前的草稿前面)。
    public func editSendWhenDone(_ id: SendWhenDoneItem.ID) async {
        guard let text = await sendWhenDone?.takeBack(id) else { return }
        putBackInDraft(text)
    }

    /// 管線裡的機密偵測步驟(#302):畫面依它的 `review` 開說明 sheet。
    public var secretCheck: SecretCheck? { sendPipeline.step(SecretCheck.self) }
    private let slashDiscovery: (any SlashDiscovering)?
    private let modelCatalogProvider: (any ModelCatalogProviding)?
    private let haptics: any Haptics
    /// 主機收下 prompt(成功送出)時呼叫;請求評分用(#34)。
    @ObservationIgnored public var onPromptDelivered: (@MainActor () -> Void)?
    /// 下一次輪詢要讀畫面(送出時 agent 在等回答)。
    private var probeScreen = false
    private var answerSignature: String?
    private var answerQuestion: String?
    /// 按鍵送達主機的時間與當時對話的最後一列(已回答卡片的錨點，#213);還在送時為 `nil`(不判定)。
    private var answerSent: AnsweredCardAnchor?
    /// 答完後到這個時間為止，blocked 但畫面不是選單時視為過時狀態、不顯示通用鈕(#468)。
    private var staleBlockedUntil: Date?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    /// 「已停止」2 秒後的收起;agent 又開始工作或有新的停止時取消(#220)。
    @ObservationIgnored private var stoppedCollapseTask: Task<Void, Never>?
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
    /// 對話紀錄的方言，依 Agent 設定檔(每次輪詢由 snapshot 更新;還沒輪詢前的快取還原不需要解析)。
    private var dialect: TranscriptDialect = .claude
    /// 解析時略過認不得的行(#449):交給診斷紀錄(只含種類名稱與數量);`nil` 不回報。
    public var onTranscriptSkips: (@Sendable (TranscriptDialect, TranscriptSkips) -> Void)?
    /// 對話紀錄的路徑、即時追蹤的游標，以及開啟視窗的 byte 起點(往上翻的錨點)。
    /// `follow.isLive`:這次可見期間已經追上主機，之後落後再多也從游標分段接著讀(#130);還沒追上(剛從快取恢復、
    /// 畫面重新可見)時落後太多改讀新視窗(F5.3 第 3 點、R-B08)。
    private var file: (path: String, follow: TranscriptFollow, windowStart: Int)? {
        // 對話紀錄的路徑出現或換了:清單要連同 session 內的 skill 一起重讀(#469)。
        didSet {
            guard let path = file?.path, path != oldValue?.path else { return }
            slash.markStale()
            preloadSlash()
        }
    }
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
    /// 對話時間軸:列身分由它分配,新內容只以增量餵給它(#481)。
    private var timeline = ConversationTimeline()
    private var waitingSince: Date?
    /// 最近一次輪詢看到的 agent(送出時重讀失敗的後備)。
    /// 知道 Agent 後預載 slash 清單(#469);之後每次輪詢檢查是否過期,超過 60 秒在背景重讀。
    private var currentAgent: Agent? {
        didSet { preloadSlash() }
    }

    /// 預載 slash 清單:要等 Agent 已知、對話紀錄路徑也找到(session 內的 skill 才讀得到)才開始,
    /// 不為預載自己讀 snapshot 或定位。
    private func preloadSlash() {
        guard currentAgent != nil, file != nil else { return }
        slash.refreshIfNeeded()
    }
    /// 最近一次輪詢看到的 Agent 種類(畫面依種類調整說明，例如 Codex 等 session 的提示)。
    public var agentKind: String? { currentAgent?.kind }
    /// 第一則訊息送出後才有對話紀錄的 Agent(Codex):等待畫面換成對應說明。
    public var transcriptStartsAfterFirstMessage: Bool { screenDialect.transcriptStartsAfterFirstMessage }
    /// Agent 所在的 workspace(更多選單的「顯示版面」用,#381)。
    public var workspaceID: String? { currentAgent?.workspaceID }
    /// 已經確認過某則回音的使用者訊息(每個到達只能確認一則)。
    private var consumedUserIDs = Set<String>()
    private var lastPolledStatus: AgentStatus?
    /// 卡片在 body 中取用時才建立，所以不參與觀察(避免在畫面更新中改變被觀察的狀態)。
    @ObservationIgnored private var workflowModels: [String: WorkflowModel] = [:]
    private var lastPresenceSeq: UInt64 = 0

    // MARK: 離開期間摘要(#308)

    /// 上次離開這個聊天的時間(由 `MergedAgentListModel.awayStart(for:)` 接上;沒開過的聊天是 `nil`)。
    @ObservationIgnored public var awayStart: (@MainActor () -> Date?)?
    /// 第一次讀到離開起點時定下來的(離開起點，進來的時間);之後不變，聊天開著時發生的項目不會被算進去。
    private var awayLatch: (from: Date, cutoff: Date)?
    /// 離開超過 15 分鐘回來時的摘要;其餘為 `nil`。
    package private(set) var awaySummary: AwaySummary?
    /// 離開期間那段是否收合(只留最後一句)。
    package var isAwayCollapsed = false

    /// 畫面上要畫的列:收合時藏起離開期間那段(最後一句留著)。
    package var visibleEntries: [ConversationEntry] {
        guard isAwayCollapsed, let awaySummary else { return entries }
        let hidden = awaySummary.hiddenIDs(in: entries.map(\.id))
        return entries.filter { !hidden.contains($0.id) }
    }

    /// app 進背景的時間(聊天一直開著時的離開起點，#308)。
    private var backgroundedAt: Date?

    /// app 進背景或回到前景(由畫面的 scenePhase 回報):進背景記起點，回來時離開起點與這次進來的時間重新定下來，
    /// 之後的摘要規則同進出聊天畫面(離開 15 分鐘以上才出現)。
    public func scenePhaseChanged(isBackground: Bool) {
        if isBackground {
            if backgroundedAt == nil { backgroundedAt = clock.now() }
            return
        }
        guard let from = backgroundedAt else { return }
        backgroundedAt = nil
        awayLatch = (from, clock.now())
        updateAwaySummary()
    }

    private func updateAwaySummary() {
        if awayLatch == nil, !items.isEmpty, let from = awayStart?() { awayLatch = (from, clock.now()) }
        awaySummary = awayLatch.flatMap { AwaySummary.make(items: items, awayFrom: $0.from, cutoff: $0.cutoff) }
    }
    /// 每次綁定新 session 遞增;晚到的舊 session 結果直接丟棄(R-B07)。
    private var generation = 0

    public init(
        client: HerdrClient, transcripts: TranscriptReader, paneID: String, knownSessionID: String?,
        cache: any ConversationCache, clock: ConversationClock = ConversationClock(), openLines: Int = TranscriptReader.openingLines,
        openMaxBytes: Int = TranscriptReader.openingMaxBytes, pageLines: Int = 200,
        drafts: DraftStore = DraftStore(), slashDiscovery: (any SlashDiscovering)? = nil, haptics: any Haptics = SilentHaptics(),
        hostName: @escaping @MainActor () -> String? = { nil },
        images: ComposerImages? = nil,
        updates: HostUpdates? = nil,
        sendSteps: [any SendStep] = [],
        modelCatalog: (any ModelCatalogProviding)? = nil,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.modelCatalogProvider = modelCatalog
        self.updates = updates
        self.images = images
        self.client = client
        self.transcripts = transcripts
        self.paneID = paneID
        self.knownSessionID = knownSessionID
        self.cache = cache
        self.clock = clock
        self.openLines = openLines
        self.openMaxBytes = openMaxBytes
        self.pageLines = pageLines
        self.drafts = drafts
        self.haptics = haptics
        self.hostName = hostName
        self.sleep = sleep
        delivery = PromptDelivery(client: client, sleep: sleep)
        sendPipeline = SendPipeline(steps: sendSteps, clock: SendPipelineClock(now: clock.now, sleep: sleep))
        self.slashDiscovery = slashDiscovery
        slash = SlashMenuModel(loader: { nil })
        draft = drafts.text(chatKey: paneID, session: knownSessionID)
        if images != nil { attachments = drafts.attachments(chatKey: paneID) }
        slash.loader = { [weak self] in await self?.slashCatalog() }
        slash.onPick = { [weak self] command in self?.pick(slash: command) }
        slash.update(draft: draft, caret: draftCaret)
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
        switch AgentCatalog.profile(forHerdrName: agent.kind).transcript?.slashMenu ?? .none {
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
        preloadSlash()
        await restoreFromCache()
    }

    /// 列表傳來的 session 與快取相同時，立刻顯示快取並從游標續讀(F5.3 第 1 點)。
    /// 列表還沒給 session(冷啟動、從推播打開)時也先顯示這個聊天上次的快取(#356):之後快照回報的 session 不同，
    /// 輪詢綁定新 session 時丟掉快取，舊內容留著到新內容讀回來(#329)。
    public func restoreFromCache() async {
        guard items.isEmpty, let cached = await cache.load(chatKey: chatKey),
              knownSessionID.map({ cached.matches(sessionID: $0) }) ?? (cached.parserVersion == CachedConversation.parserVersion),
              Self.isWorthRestoring(cached) else { return }
        boundSessionID = cached.sessionID
        file = (cached.path, TranscriptFollow(cursor: cached.cursor, isLive: false), cached.windowStart)
        recent = cached.messages
        segments = [(cached.windowStart, cached.messages.count)]
        metadata = cached.metadata
        noteTranscriptPermissionMode()
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
        let runID = UUID()
        currentRunID = runID
        slash.restartRetries()
        followPace = TranscriptFollowPace(interval: pollInterval, sleep: sleep)
        let pollDue = WakeSignal(sleep: sleep)
        self.pollDue = pollDue
        // 不讀快照時靠 keepalive／心跳發現離線：畫面可見期間縮短到最壞約 15 秒。
        await client.beginQuickDisconnectDetection()
        await reopen()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.reportPresence(sleep: sleep) }
            group.addTask { await self.armLoadingIndicator(sleep: sleep) }
            if let updates {
                group.addTask { await updates.liveUpdates.attach() }
                group.addTask { await self.wakeOnChanges(from: updates) }
            }
            while !Task.isCancelled {
                await poll()
                await refreshSessionStatusIfDue()
                await probePermissionModeIfNeeded()
                await refreshStatusLineIfDue()
                do {
                    // 輪詢期間被叫醒就不等。
                    try await pollDue.wait(atMost: pollInterval)
                } catch {
                    break
                }
            }
            group.cancelAll()
        }
        // 場景重新可見時新的 run 可能已經開始(#219):追蹤與節奏是它的，不收。
        let isCurrentRun = currentRunID == runID
        if isCurrentRun {
            currentRunID = nil
            stopFollowingUpdates()
            followPace = nil
            self.pollDue = nil
        }
        if isCurrentRun { slash.cancelBackgroundReload() }
        await client.endQuickDisconnectDetection()
        // 畫面不在了：主機推送尾端的連線方式(HTTPS)停止追蹤。下次開啟從游標重新開始。
        if isCurrentRun, currentRunID == nil, let path = file?.path { await transcripts.stopFollowing(path: path) }
    }

    /// 讀這個 session 的 status line 狀態(#388):只有 Claude Code、知道 session id 時;至少隔 `sessionStatusInterval` 秒才再讀。
    /// 讀不到(沒有檔案、未安裝、舊版主機服務、連線錯誤)一律清成 `nil`,畫面退回對話紀錄算法、不空白。
    package func refreshSessionStatusIfDue() async {
        let reader = agentKind.flatMap { agentSessionStatusReaders[AgentID(herdrName: $0)] } ?? sessionStatusReader
        guard let reader, dialect.readsSessionStatus, let session = boundSessionID ?? knownSessionID,
              ClaudeSessionStatus.isValidSessionID(session) else {
            sessionStatus = nil
            return
        }
        let now = clock.now()
        if let last = sessionStatusReadAt, now.timeIntervalSince(last) < Self.sessionStatusInterval { return }
        sessionStatusReadAt = now
        let statuses = try? await reader.sessionStatuses(sessionIDs: [session])
        guard !Task.isCancelled else { return }
        let status = statuses?[session].flatMap { $0.isFresh(at: now) ? $0 : nil }
        if status != sessionStatus { sessionStatus = status }
    }

    /// 載入超過 `loadingIndicatorDelay` 還沒有內容才開啟進度指示。
    private func armLoadingIndicator(sleep: Sleep) async {
        loadingIndicatorArmed = false
        guard phase == .loading, items.isEmpty else { return }
        do { try await sleep(Self.loadingIndicatorDelay) } catch { return }
        loadingIndicatorArmed = true
    }

    /// 目前的 `run()`;舊的 run 晚於新的結束時據此不收新的資源。
    @ObservationIgnored private var currentRunID: UUID?

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
        stopNeedsReconnect = false
        if banner == .offline { banner = nil }
        // 重連後的 Agent 列表交給離線佇列比對、補送(#301;主機更新來源讀到的也會交給它)。
        offlineQueue?.receive(snapshot)
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
        settleStopResult()
        screenThisPoll = nil
        workingScreenDue = workingScreenReads.allowsRead(isWorking: agentStatus == .working, at: clock.now())
        title = AgentRowText.title(for: agent, siblings: snapshot.agents.filter { $0.workspaceID == agent.workspaceID })
        tabName = AgentListProjection.tabPosition(of: agent.tabID, in: snapshot).map { AgentListProjection.tabName(label: $0.tab.label, position: $0.position) } ?? ""
        // 讀 Pane 畫面(提問卡、建議提示詞、面板、即時預覽、背景 agents 窗格)排在讀對話紀錄之後(#356):
        // 慢網路下對話內容先出來，不等這幾個依序的請求。沒有對話紀錄可讀的情況(不支援、還沒有 session)照舊先讀畫面。
        let agentDialect = AgentCatalog.profile(forHerdrName: agent.kind).transcript
        let readScreens = { [self] in
            await refreshPrompt(agent)
            let suggestionRead = await readSuggestion(agent)
            await refreshPanel(agent)
            applySuggestion(suggestionRead, agent: agent)
            await refreshLivePreview()
            // 背景 agents 窗格只有支援 subagent 的方言(Claude)有。
            if agentDialect?.supportsSubagents == true { await readAgentsPaneIfNeeded() }
        }
        guard agentDialect != nil else {
            await readScreens()
            unbind()
            phase = .unsupported
            return
        }
        guard let target = agent.transcriptTarget else {
            await readScreens()
            if isRefreshing { clearDisplay() }
            waitForSession(agent)
            return
        }
        waitingSince = nil
        if boundSessionID != target.sessionKey {
            // 新的 session(輪替，或回收 slot 中的新聊天):丟掉舊對話、游標與快取(F5.1 第 4 點)。
            if boundSessionID != nil { await cache.remove(chatKey: chatKey) }
            unbind(keepingDisplay: true)
            boundSessionID = target.sessionKey
        }
        dialect = target.dialect
        followPace?.interval = pollInterval
        await read(target)
        await readScreens()
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
        if let screenThisPoll { read = screenThisPoll } else { read = await readScreen() }
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

    /// 停在 `.missingSession` 時,這種 Agent 的解法指令(Codex 的 `codex --no-daemon`,#400);其他情況與沒有解法的種類為 `nil`。
    public var missingSessionCommand: String? {
        guard phase == .missingSession, let kind = currentAgent?.kind else { return nil }
        return AgentCatalog.profile(forHerdrName: kind).session.launchCommand
    }

    private func read(_ target: TranscriptTarget) async {
        let generation = generation
        defer { if generation == self.generation { isRefreshing = false } }
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
            if isRefreshing { clearDisplay() }
            banner = nil
            phase = .newConversation
        case TranscriptReadError.unreadable:
            banner = .unreadable
            phase = .ready
        case TranscriptReadError.ambiguous:
            // 不開任何檔、不依新舊猜;下次輪詢重新定位(使用者可能已刪掉多餘的檔)。
            guard generation == self.generation else { return }
            file = nil
            if isRefreshing { clearDisplay() }
            banner = .ambiguous
            phase = .ready
        case TranscriptReadError.compressed:
            // 只有 `.zst`:不是「還沒有檔案」,也不在手機上解壓;下次輪詢重新定位(Codex 可能又寫了新的 rollout)。
            guard generation == self.generation else { return }
            file = nil
            if isRefreshing { clearDisplay() }
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
        var chunk = try await transcripts.window(path: path, endingAt: size, lines: openLines, maxBytes: openMaxBytes > 0 ? openMaxBytes : nil)
        guard generation == self.generation else { return }
        if chunk.lines.isEmpty, chunk.start > 0 {
            // 最後一行比 byte 上限還大：放寬成只讀那一行(上限的目的是慢網路下別讀太多，但一行都沒有就沒東西可看)。
            chunk = try await transcripts.window(path: path, endingAt: size, lines: 1)
            guard generation == self.generation else { return }
        }
        file = (path, TranscriptFollow(cursor: chunk.end, isLive: true), chunk.start)
        recent = parse(chunk.lines)
        segments = [(chunk.start, recent.count)]
        olderMessages = []
        metadata = dialect.latestMetadata(in: chunk.lines)
        notePermissionModes(in: chunk.lines)
        progress = AgentProgress.latest(in: chunk.lines, dialect: dialect)
        older = chunk.start > 0 ? .available : .reachedStart
        rebuild()
        try await readEarlierUntilMessages(path: path, generation: generation)
    }

    /// 開啟視窗內沒有任何使用者／Agent 文字(最後幾十行都是 system、api-request-blob、file-history-snapshot 這類不產生訊息的紀錄)
    /// 但檔案前面有:往前一頁一頁讀到有訊息為止，不顯示「還沒有訊息」(#418)。有上限，避免超大檔案讀不完。
    private func readEarlierUntilMessages(path: String, generation: Int) async throws {
        var pages = 0
        while !hasReadableMessage, older == .available, let start = file?.windowStart, start > 0, pages < Self.maximumEmptyWindowPages {
            pages += 1
            let page = try await transcripts.window(path: path, endingAt: start, lines: pageLines)
            guard generation == self.generation else { return }
            let known = Set((olderMessages + recent).map(\.id))
            let olderPage = parse(page.lines).filter { !known.contains($0.id) }
            olderMessages = olderPage + olderMessages
            file?.windowStart = page.start
            older = page.start > 0 ? .available : .reachedStart
            applyTimeline(timeline.prependOlder(olderPage))
        }
    }

    /// 畫面上有沒有「可讀訊息」(#473):使用者訊息、Agent 文字、備註、skill、subagent、workflow、shell、檔案卡都算;
    /// 只有摺起來的工具串(`.toolRun`)不算。
    private var hasReadableMessage: Bool { Self.hasReadableMessage(in: items) }

    private static func hasReadableMessage(in items: [ConversationItem]) -> Bool {
        items.contains { if case .toolRun = $0 { false } else { true } }
    }

    /// 快取的訊息組出的畫面有可讀訊息(或根本沒有訊息)才值得還原:尾端只有工具步驟的快取會讓開啟時看到一片空白的步驟串(#473)。
    private static func isWorthRestoring(_ cached: CachedConversation) -> Bool {
        cached.messages.isEmpty || hasReadableMessage(in: Conversation.items(from: cached.messages))
    }

    /// 開啟視窗沒有訊息時最多往前讀幾頁(每頁 `pageLines` 行)。
    package static let maximumEmptyWindowPages = 25

    private func append(_ chunk: TranscriptChunk) {
        let known = Set(recent.map(\.id))
        let added = parse(chunk.lines).filter { !known.contains($0.id) }
        recent += added
        let appendUpdate = timeline.append(added)
        if !added.isEmpty { segments.append((chunk.start, added.count)) }
        for line in chunk.lines {
            dialect.updateMetadata(&metadata, with: line)
            progress.update(with: line, dialect: dialect)
        }
        notePermissionModes(in: chunk.lines)
        if let trimUpdate = trimIfFollowing() {
            applyTimeline(ConversationTimeline.Update(cause: appendUpdate.cause, changes: appendUpdate.changes + trimUpdate.changes))
        } else {
            applyTimeline(appendUpdate)
        }
    }

    /// 跟隨尾端時訊息超過上限：丟掉往上翻的舊頁，再整段丟掉最舊的(至少留最後一段),視窗起點移到留下的第一段開頭，
    /// 之後往上翻可以讀回來(#130)。
    private func trimIfFollowing() -> ConversationTimeline.Update? {
        guard isFollowingLatest, olderMessages.count + recent.count > Self.followingMessageLimit, let first = segments.first else { return nil }
        var droppedMessageCount = olderMessages.count
        olderMessages = []
        var start = first.start
        while recent.count > Self.followingMessageLimit, segments.count > 1 {
            let droppedSegment = segments.removeFirst()
            recent.removeFirst(droppedSegment.count)
            droppedMessageCount += droppedSegment.count
            start = segments[0].start
        }
        file?.windowStart = start
        older = start > 0 ? .available : .reachedStart
        return timeline.dropOldest(messageCount: droppedMessageCount)
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
            let olderPage = parse(chunk.lines).filter { !known.contains($0.id) }
            olderMessages = olderPage + olderMessages
            self.file?.windowStart = chunk.start
            older = chunk.start > 0 ? .available : .reachedStart
            applyTimeline(timeline.prependOlder(olderPage))
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
        isRefreshing = false
        // 斷線前的狀態已過時：不能留著 working 讓停止鈕可按(#220)。
        if agentStatus == .working { stopNeedsReconnect = true }
        agentStatus = nil
        // 看不到主機畫面，建議可能已過時;恢復連線後重讀(#123)。
        clearSuggestion()
        banner = .offline
        updateWorkingSince()
        if items.isEmpty, let knownSessionID, let cached = await cache.load(chatKey: chatKey), cached.matches(sessionID: knownSessionID),
            Self.isWorthRestoring(cached) {
            recent = cached.messages
            segments = [(cached.windowStart, cached.messages.count)]
            metadata = cached.metadata
            noteTranscriptPermissionMode()
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
        guard !isReadOnly else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 離線時排進離線佇列(#301):只排文字(圖片要上傳到主機)、不排自訂回答。
        if canQueueOffline { return !isSending && hasText && attachments.isEmpty }
        guard hasTarget else { return false }
        if typedAnswer != nil { return answerInFlight == nil && hasText }
        return !isSending && loadingFileName == nil && (hasText || !attachments.isEmpty)
    }

    /// Shell 模式(F6.4):Claude 聊天的草稿以 `!` 開頭，輸入列上方提示會在 agent 的 shell 執行。
    public var isShellMode: Bool {
        guard typedAnswer == nil, let kind = currentAgent?.kind else { return false }
        return PromptDelivery.isShellCommand(draft, kind: kind)
    }

    /// 停止只在 working 時;**永不對 blocked 的 agent**(中斷可能把問題關掉,F6.7)。
    public var canStop: Bool { agentStatus == .working && !isStopping && !isReadOnly && !isOffline }

    /// 停止列與強制結束確認裡的 agent 名稱(#220)。
    public var agentName: String {
        currentAgent.flatMap { AgentKind.displayName($0.kind) } ?? String(localized: "Agent")
    }

    /// 輸入卡片最上面的停止列(#220):工作中或有停止進度、結果時;唯讀、離線時沒有。
    public var showsStopBar: Bool {
        !isReadOnly && !isOffline && (agentStatus == .working || stopPhase != nil)
    }

    /// 輪詢讀到狀態後：agent 不在工作就收起失敗結果;「無法確認」此時已確認，仍在工作就換成仍在工作。
    /// 「已停止」遇到又在工作立刻換回停止鈕;「需要你」留到 agent 不再需要你。
    private func settleStopResult() {
        switch stopPhase {
        case .stillWorking?, .failed?, .unconfirmed?, .forceQuitFailed?:
            if agentStatus != .working {
                stopPhase = nil
            } else if stopPhase == .unconfirmed {
                stopPhase = .stillWorking
            }
        case .stopped?:
            if agentStatus == .working { setStopPhase(nil) }
        case .needsAnswer?:
            if agentStatus != .blocked { stopPhase = nil }
        case .stopping?, nil:
            break
        }
    }

    /// 換停止列的狀態;換掉「已停止」時一併取消它的自動收起。
    private func setStopPhase(_ phase: StopPhase?) {
        stoppedCollapseTask?.cancel()
        stoppedCollapseTask = nil
        stopPhase = phase
        guard phase == .stopped else { return }
        stoppedCollapseTask = Task { [weak self, sleep] in
            do { try await sleep(.seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, self.stopPhase == .stopped else { return }
            self.stopPhase = nil
        }
    }

    /// 關閉停止列的失敗結果。
    public func dismissStopResult() {
        if stopPhase != .stopping { setStopPhase(nil) }
    }

    /// 強制結束同停止，只對 working 的 agent;唯讀、離線時不可用(#220)。
    public var canForceQuit: Bool { agentStatus == .working && !isReadOnly && !isOffline }

    /// 離線，但知道對象(上次讀到的 Agent),送出會排進離線佇列。
    public var canQueueOffline: Bool {
        isOffline && offlineQueue != nil && currentAgent != nil && typedAnswer == nil && phase != .agentGone
    }

    private var hasTarget: Bool {
        phase != .loading && phase != .agentGone && !isOffline && currentAgent != nil
    }

    /// 送出輸入框的文字(F6.5)。
    ///
    /// 先經過送出管線(`SendPipeline`,#299):步驟擋下時不碰主機，依步驟決定草稿放回或維持清空。
    /// 輸入框樂觀清空、立刻顯示回音;送出當下重讀**新鮮的** snapshot 重新確認目標 pane(2 秒前的 pane 可能已被回收,R-P06)。
    /// 什麼都沒送出(agent 不在、session 換了、在等回答、herdr 拒絕)→ 拿掉回音、草稿放回;
    /// 送了但不確定(沒有反應、無法確認)→ 回音標示失敗，可重試，**不自動重送**(§7.3)。
    public func send() async {
        guard canSend else { return }
        // 行動網路上要傳大影片:先提醒會用掉多少流量,使用者確認才送(#474)。
        if needsCellularConfirmation {
            cellularUploadWarning = attachments.filter { $0.uploadedPath == nil && $0.duration != nil }.reduce(0) { $0 + $1.byteCount }
            return
        }
        if let typedAnswer {
            await sendTypedAnswer(typedAnswer)
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        await submit(text)
    }

    /// 變更頁組好的評論訊息送給 Agent(#310):與輸入列同一條送出管線;輸入框裡打到一半的字留著，
    /// 擋下而要放回時評論接在草稿前面。
    public func sendReview(_ text: String) async {
        guard canSendReview else { return }
        await submit(text)
    }

    /// 送出一段文字：送出管線 → 主機。呼叫端已清空(或不動)輸入框。
    private func submit(_ text: String) async {
        isSending = true
        updateWorkingSince()
        defer {
            isSending = false
            updateWorkingSince()
        }
        notice = nil
        let outgoing = OutgoingPrompt(
            text: text, paneID: paneID, expectedSession: boundSessionID ?? knownSessionID, createdAt: clock.now(),
            workspaceID: currentAgent?.workspaceID)
        // 連線狀態在步驟輪到時才讀:撤回倒數期間可能斷線或恢復。
        switch await sendPipeline.prepare(outgoing, isHostReachable: { [weak self] in !(self?.isOffline ?? false) }) {
        case .proceed(let prepared):
            await deliver(prepared)
        case .halt(let halt):
            // 放回的是使用者打的原文(不是步驟改過的);步驟等待期間(撤回倒數)又打了字時，原文放在前面、不蓋掉新打的。
            if halt.restoresDraft { putBackInDraft(text) }
        }
    }

    /// 管線通過後交給主機：回音、上傳圖片、重新確認目標、送出。
    private func deliver(_ outgoing: OutgoingPrompt) async {
        let text = outgoing.text
        // 送出後舊建議已不適用;下次完成時重讀(herdr 可能來不及回報工作中,#123)。
        clearSuggestion()
        let sentImages = attachments
        let echo = PromptEcho(
            id: UUID().uuidString, text: text, date: clock.now(), knownUserIDs: userMessageIDs,
            imageCount: sentImages.filter { $0.kind == .image }.count,
            imageFiles: sentImages.filter { $0.kind == .image }.map(\.fileName.value)
        )
        echoes.append(echo)
        rebuildEntries()
        // 圖片先逐張上傳;任何一張失敗 → 整則不送，草稿與圖片保留(F6.5、F7)。
        let paths: [String]
        let upload = Task { try await uploadAttachments() }
        uploadTask = upload
        defer { uploadTask = nil }
        do {
            paths = try await withTaskCancellationHandler { try await upload.value } onCancel: { upload.cancel() }
        } catch is CancellationError {
            // 使用者取消上傳:什麼都沒送出,草稿與附件留著,不提示。
            removeEcho(echo.id)
            putBackInDraft(text)
            return
        } catch {
            removeEcho(echo.id)
            putBackInDraft(text)
            notice = Self.uploadNotice(for: error, otherwise: .uploadFailed)
            return
        }
        if let index = echoes.firstIndex(where: { $0.id == echo.id }) {
            echoes[index].imagePaths = paths
            echoes[index].filePaths = zip(sentImages, paths).filter { $0.0.kind == .file }.map(\.1)
        }
        let prompt = UploadedImages.prompt(text: text, paths: paths)
        switch await freshTarget() {
        case .success(let agent):
            apply(
                await delivery.send(prompt, to: agent, expectedSession: outgoing.expectedSession), toEcho: echo.id, text: text,
                isRetry: false)
            // 附件只在送出被接受時清(什麼都沒送出時草稿放回、圖片也留著，已上傳的不重傳)。
            if !Self.nothingSent(notice) {
                attachments.removeAll { attachment in sentImages.contains { $0.fileName == attachment.fileName } }
                for sent in sentImages where sent.kind == .file { removeStoredCopies(of: sent) }
                saveAttachments()
            }
            if notice == .needsAnswer {
                // 什麼都沒送出，因為 agent 在等回答：立刻找出問題(資料夾信任這類提示 herdr 可能回報 idle)。
                probeScreen = true
                await refreshPrompt(agent)
            }
        case .failure(let failure):
            removeEcho(echo.id)
            putBackInDraft(text)
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
            apply(
                await delivery.send(prompt, to: agent, expectedSession: boundSessionID ?? knownSessionID), toEcho: echoID, text: text,
                isRetry: true)
        case .failure(let targetFailure):
            setEcho(echoID, state: .failed(failure))
            notice = targetFailure.notice
        }
    }

    /// 停止(F6.7):一個 Esc,3 秒內確認離開 working;結果顯示在停止列(#220)。
    public func stop() async {
        guard canStop else { return }
        setStopPhase(.stopping)
        notice = nil
        switch await stopWithinTimeout() {
        case .stopped(let status)?:
            // 不等下一次輪詢：工作中的介面立刻收起。
            agentStatus = status
            updateWorkingSince()
            setStopPhase(.stopped)
        case .unconfirmed?: stopPhase = .unconfirmed
        case .stillWorking?, nil: stopPhase = .stillWorking
        case .failed?: stopPhase = .failed
        case .needsAnswer?: stopPhase = .needsAnswer
        }
    }

    /// 停止中超過 `stopTimeout` 回 `nil`(當成仍在工作，不讓轉圈停在原地)。
    private func stopWithinTimeout() async -> StopOutcome? {
        let delivery = delivery, paneID = paneID, sleep = sleep
        return await withTaskGroup(of: StopOutcome?.self) { group in
            group.addTask { await delivery.stop(paneID: paneID) }
            group.addTask {
                try? await sleep(Self.stopTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 強制結束(ctrl+c,F6.7)。呼叫端先請使用者確認;只對 working 的 agent。
    public func forceQuit() async {
        guard canForceQuit else { return }
        switch await delivery.forceQuit(paneID: paneID) {
        case .sent, .notWorking: setStopPhase(nil)
        case .needsAnswer: setStopPhase(.needsAnswer)
        case .failed: setStopPhase(.forceQuitFailed)
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
        staleBlockedUntil = nil
        answerNotice = nil
        haptics.play(.selection)
        let expectation = SendExpectation(session: boundSessionID ?? knownSessionID)
        do {
            for input in inputs {
                switch input {
                case .keys(let keys): try await client.sendKeys(paneID: paneID, keys: keys, expecting: expectation)
                case .text(let text): try await client.sendText(paneID: paneID, text: text, expecting: expectation)
                }
            }
        } catch {
            guard answerInFlight == answer else { return }
            clearAnswer()
            if error as? HostServiceError == .paneChanged {
                // 什麼都沒送出：題目或對話已變，立刻重讀畫面換上目前的題目。
                answerNotice = .questionChanged
                haptics.play(.error)
                probeScreen = true
                await poll()
                return
            }
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

    /// 「需要你」卡片上一個選項現在的狀態(#424):畫面據此決定附屬位置放什麼、能不能點、VoiceOver 念什麼。
    public func optionState(for option: PromptOption) -> PromptOptionState {
        if isAnswering(option) { return .sending }
        if answerInFlight != nil || isReadOnly { return .disabled }
        let answer = PromptAnswer.option(option)
        return isTypedAnswerOption(option) ? (canBeginTypedAnswer(option) ? .available : .disabled)
            : (canAnswer(answer) ? .available : .disabled)
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
        if answerNotice == .sendFailed || answerNotice == .questionChanged, isTypedAnswerOption(option) {
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
        screenThisPoll = await readScreen()
        guard let screen = screenThisPoll else {
            // 讀不到畫面 = 未知：永不當成新提示，只看逾時。
            // 剛答完、herdr 的 blocked 還沒更新的期限內(`staleBlockedUntil`)不冒通用鈕(#468)。
            let isWithinStaleWindow = staleBlockedUntil.map { clock.now() < $0 } ?? false
            if blocked, prompt == nil, !isWithinStaleWindow { prompt = .unrecognized }
            if prompt != nil { agentStatus = .blocked }
            checkAnswerDeadline()
            return
        }
        let parsed = BlockedPromptParser.parse(screen: screen, dialect: AgentCatalog.profile(forHerdrName: agent.kind).screen)
        if blocked, parsed == nil, answerInFlight != nil, answerSent == nil, prompt != nil {
            // 送出還沒返回、按鍵可能已到 Agent 而畫面重繪：維持原卡片，不換成通用鈕(#468)。
            agentStatus = .blocked
            return
        }
        var next = blocked ? (parsed ?? .unrecognized) : (parsed?.kind == .trust ? parsed : nil)
        if parsed != nil { staleBlockedUntil = nil }
        if blocked, parsed == nil {
            // 答完後 herdr 的 blocked 狀態可能還沒更新：畫面不是選單時不冒出通用鈕(其按鍵會真的打進 Agent)，到期限為止。
            if let sent = answerSent, answerInFlight != nil { staleBlockedUntil = sent.sentAt.addingTimeInterval(Self.answerDeadline) }
            if let until = staleBlockedUntil, clock.now() < until { next = nil }
        }
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
        case .paneChanged:
            // 主機送出前比對發現對話已變更(#304):與送前重讀 snapshot 發現 session 換了相同。
            nothingSent = .superseded
        }
        notice = nothingSent
        if isRetry {
            setEcho(id, state: .failed(.noResponse))
        } else {
            removeEcho(id)
            putBackInDraft(text)
        }
    }

    /// 什麼都沒送出的提示(草稿放回)。
    private static func nothingSent(_ notice: SendNotice?) -> Bool {
        switch notice {
        case .needsAnswer?, .rejected?, .readOnlyDevice?: true
        default: false
        }
    }

    /// 沒送出的文字放回輸入框:接在目前的草稿前面,使用者這段時間打的字不蓋掉(放回輸入框的一律走這裡)。
    private func putBackInDraft(_ text: String) {
        draft = draft.isEmpty ? text : text + "\n" + draft
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
        updateAwaySummary()
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
    /// 只換掉游標前的 `/字詞`,前後文字保留，游標停在插入文字之後(#230);沒有觸發時整段換掉。
    public func pick(slash command: SlashCommand) {
        let trigger = slash.trigger ?? SlashMenuModel.Trigger(range: 0..<draft.utf16.count, query: "", placement: .leading)
        let filled = trigger.filling(command.name, in: draft)
        reportedCaret = (filled.draft, filled.caret)
        draft = filled.draft
        pickedHint = command.argumentHint.map { (draft, $0) }
        pickedSlashNames.insert(command.name)
        lastSlashInsertion = SlashInsertion(name: command.name, sequence: (lastSlashInsertion?.sequence ?? 0) + 1)
    }

    /// 訊息中間要上色的指令名稱(#469):這個聊天的 slash 清單(非內建)加上從選單選用過的名稱。輸入框與使用者泡泡共用。
    public var inlineSlashNames: Set<String> { slash.inlineNames.union(pickedSlashNames) }

    private var pickedSlashNames: Set<String> = []

    /// 最近一次選定插入的指令(VoiceOver 念出插入了哪個指令)。
    public private(set) var lastSlashInsertion: SlashInsertion?

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
    /// 回傳按鍵是否送出(沒有可送的按鍵或送失敗為 `false`)。
    @discardableResult
    public func operatePanel(_ input: SlashPanel.Input) async -> Bool {
        guard !isOperatingPanel, let panel, let keys = panel.keys(for: input), !keys.isEmpty else { return false }
        isOperatingPanel = true
        defer { isOperatingPanel = false }
        haptics.play(.selection)
        do {
            try await client.sendKeys(paneID: paneID, keys: keys)
        } catch {
            notice = .panelKeysFailed
            haptics.play(.error)
            return false
        }
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        kickPolls(after: [.milliseconds(300)])
        return true
    }

    private static let panelWatch: TimeInterval = 8

    /// 面板對 herdr 不可見(狀態仍是 idle):送出 slash 指令後監看 8 秒，0.4 秒與 1.2 秒各多讀一次。
    private func watchForPanel() {
        guard screenDialect.readsPanels else { return }
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        kickPolls(after: [.milliseconds(400), .milliseconds(800)])
    }

    /// 目前 Agent 的畫面方言(ADR-0013);還沒讀到 Agent 時是通用方言(什麼都不讀、不操作)。
    private var screenDialect: ScreenDialect { AgentCatalog.profile(forHerdrName: currentAgent?.kind ?? "").screen }

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
        defer { updatePanelReadability() }
        let watching = panelWatchUntil.map { clock.now() < $0 } ?? false
        if !watching { panelWatchUntil = nil }
        guard AgentCatalog.profile(forHerdrName: agent.kind).screen.readsPanels, prompt == nil, agentStatus != .working, agentStatus != .blocked else {
            panel = nil
            return
        }
        guard watching || panel != nil || screenThisPoll != nil else { return }
        if screenThisPoll == nil { screenThisPoll = await readScreen() }
        guard let screen = screenThisPoll else { return }
        let next = SlashPanelParser.parse(screen: screen, dialect: AgentCatalog.profile(forHerdrName: agent.kind).screen)
        if next != panel { panel = next }
        if modelSheetPage == .effort, effortBaseline == nil, let next, let slider = next.slider {
            effortBaseline = EffortBaseline(level: slider.current, ultracode: next.ultracode)
        }
    }

    /// 模型選擇 sheet 在等面板、監看期已滿還是沒讀到面板:sheet 改成只顯示目前模型(#384)。
    private func updatePanelReadability() {
        let watching = panelWatchUntil.map { clock.now() < $0 } ?? false
        let unreadable = isChoosingModel && panel == nil && !watching
        if unreadable != modelPanelUnreadable { modelPanelUnreadable = unreadable }
    }

    // MARK: - 建議提示詞(#121、#123)

    /// 輸入列上方要顯示的 Claude Code 建議提示詞;沒有建議、或輸入框已有文字時為 `nil`
    /// (不蓋掉使用者打的字，#121 故事 4)。
    public var suggestion: String? { draft.isEmpty ? detectedSuggestion : nil }

    /// 輸入框上方這時要顯示的一樣(需要你 > 工作中(停止列) > 建議卡,#240)。
    public var topAccessory: ComposerTopAccessory? {
        ComposerTopAccessory.choose(
            needsYou: prompt != nil, isWorking: showsWorkingIndicator, showsStopBar: showsStopBar, suggestion: suggestion)
    }

    /// 接受建議：只把文字填入輸入框，**不送任何 herdr 請求**(同 slash 選定,#83)。
    /// 沒有顯示中的建議(例如輸入框已有字)時什麼都不做並回傳 `false`(硬體鍵盤的 Tab 照常交給系統)。
    @discardableResult
    public func acceptSuggestion() -> Bool {
        guard let suggestion else { return false }
        draft = suggestion
        return true
    }

    /// HTTPS 主機的主機服務太舊、讀不了 Pane 畫面時的說明(#303):「需要你」卡只能給通用鈕，看不到選項、計畫與建議。
    /// 讀得到畫面或是其他原因失敗時為 `nil`。
    public private(set) var screenUpdateRequiredMessage: String?

    /// 讀 pane 可見畫面;讀不到回 `nil`(呼叫端各自沿用上次或當成未知)。主機服務太舊時記下說明，讀得到就拿掉。
    private func readScreen(format: PaneReadFormat = .text) async -> String? {
        do {
            let screen = try await client.readPane(paneID: paneID, format: format)
            screenUpdateRequiredMessage = nil
            return screen
        } catch let error as HostServiceError {
            if case .hostServiceUpdateRequired = error { screenUpdateRequiredMessage = HostErrorText.hostServiceMessage(error) }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - 模型膠囊(#350)

    /// 輸入框模型膠囊顯示的目前模型(取自對話紀錄最新的模型 id);還沒讀到是 `nil`。
    public var modelName: String? { statusFileLine?.model ?? screenStatusLine?.model ?? metadata.model.map(TranscriptMetadata.displayName(ofModel:)) }

    /// 目前的 effort 原值:畫面狀態列優先(使用者在電腦上改了也跟著),沒有就取對話紀錄。
    private var effortLevel: String? { statusFileLine?.effort ?? screenStatusLine?.effort ?? metadata.effort }

    /// 面板「模型」列的值:「Opus 5.5 · 中」;沒有 effort 時只有模型名,還沒讀到是 `nil`。
    public var modelSummary: String? {
        guard let name = modelName else { return nil }
        guard let effort = effortLevel.flatMap(Self.effortName(of:)) else { return name }
        return "\(name) · \(effort)"
    }

    /// 目前的 effort 顯示名稱(「中」);還沒讀到是 `nil`。
    public var effortDisplayName: String? { effortLevel.flatMap(Self.effortName(of:)) }

    public static func effortName(of level: String) -> String? {
        switch level.lowercased() {
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra High")
        case "max": String(localized: "Max")
        default: level.isEmpty ? nil : level
        }
    }

    /// 模型選擇 sheet 開著(從送出 `/model` 到選定或取消)。畫面據此不在對話裡重複畫同一張面板卡片。
    public private(set) var isChoosingModel = false

    /// 模型膠囊要顯示:Claude(可切換),或 Codex 有讀到目前模型(只顯示、說明不能在 app 內切換,#384)。
    public var showsModelCapsule: Bool {
        supportsPermissionMode || (screenDialect.showsModelName && modelName != nil)
    }

    /// 能開模型選擇:只有 Claude(`/model` 面板一步選定)、閒置、沒有問題在等、沒有別的面板、
    /// 非唯讀與離線。工作中時 `/model` 會排進佇列,所以不開放。
    public var canChooseModel: Bool {
        screenDialect.canChooseModel && hasTarget && !isReadOnly && !isOffline && !isSending && typedAnswer == nil
            && prompt == nil && panel == nil && agentStatus != .working && agentStatus != .blocked && !isChoosingModel
    }

    /// 模型選擇為什麼停用(#384);可選時是 `nil`。停用時膠囊仍可點開 sheet,sheet 只顯示目前模型與這個原因(說明同權限模式)。
    public enum ModelChoiceLock: Equatable, Sendable {
        case readOnlyDevice
        case offline
        /// Agent 在等使用者回覆:這時 `/model` 面板不會出現。
        case waitingForYou
        /// Agent 在工作:`/model` 會排進佇列。
        case working
        /// 這個 Agent 沒有在 app 內切換模型的功能(Codex 等)。
        case agentLacksFeature
        /// 這個 Agent 的切換方式還沒驗證過,所以不開放。
        case notVerified(documentedFor: String)
        /// 這台主機做不到。
        case hostCannot

        public init(_ unavailability: FeatureUnavailability) {
            switch unavailability {
            case .agentLacksFeature: self = .agentLacksFeature
            case .notVerified(let version): self = .notVerified(documentedFor: version)
            case .hostCannot: self = .hostCannot
            }
        }

        /// 對應三種「不能用」的原因;因為唯讀、離線、等你回覆、工作中而停用的不算。
        public var unavailability: FeatureUnavailability? {
            switch self {
            case .agentLacksFeature: .agentLacksFeature
            case .notVerified(let version): .notVerified(documentedFor: version)
            case .hostCannot: .hostCannot
            case .readOnlyDevice, .offline, .waitingForYou, .working: nil
            }
        }
    }

    public var modelChoiceLock: ModelChoiceLock? {
        if currentAgent != nil, let reason = screenDialect.modelChoiceUnavailability { return ModelChoiceLock(reason) }
        if isReadOnly { return .readOnlyDevice }
        if isOffline { return .offline }
        if agentStatus == .blocked || prompt != nil { return .waitingForYou }
        if agentStatus == .working { return .working }
        return nil
    }

    /// 模型選擇 sheet 的頁面:模型列,或投入程度子頁(#384)。
    public enum ModelSheetPage: Equatable, Sendable {
        case models
        case effort
    }

    public private(set) var modelSheetPage: ModelSheetPage = .models
    /// 模型切換的按鍵送出中(膠囊顯示「切換中」)。
    public private(set) var isSwitchingModel = false
    /// 面板監看期滿還是讀不到(解析失敗或畫面不是預期的面板):sheet 只顯示目前模型,不開自己的選單。
    public private(set) var modelPanelUnreadable = false

    private struct EffortBaseline {
        var level: Int?
        var ultracode: Bool?
    }

    @ObservationIgnored private var effortBaseline: EffortBaseline?

    // MARK: - 模型目錄(#385)

    /// 模型清單的描述、effort 與徽章來源:一開始是內建對照表(沒有目錄時 sheet 仍可用),開 sheet 時依序問主機快取、公開目錄,
    /// 讀到就換上(讀不到維持內建,不報錯)。
    public private(set) var modelCatalog = ResolvedModelCatalog(catalog: .builtIn, source: .builtIn)

    @ObservationIgnored private var catalogTask: Task<Void, Never>?

    private func refreshModelCatalog() {
        guard let provider = modelCatalogProvider else { return }
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            let resolved = await provider.catalog()
            guard !Task.isCancelled, let self else { return }
            if resolved != modelCatalog { modelCatalog = resolved }
        }
    }

    /// 面板上的一列對到目錄的哪個模型(名稱、簡稱或 id 相符);對不到是 `nil`,畫面維持面板自己的描述、不顯示徽章。
    public func catalogEntry(for option: SlashPanelOption) -> ModelCatalogEntry? {
        modelCatalog.catalog.entry(named: option.label)
    }

    /// 目前模型在目錄裡的項目(依對話紀錄的模型 id);投入程度子頁的徽章取自它。
    public var currentModelEntry: ModelCatalogEntry? {
        metadata.model.flatMap { modelCatalog.catalog.entry(id: $0) }
    }

    /// 目前模型的某個 effort 層級在目錄裡的選項(名稱與徽章);目錄沒有就是 `nil`。
    public func effortOption(_ level: String) -> EffortOption? {
        currentModelEntry?.effort(level)
    }

    /// 點模型膠囊:送 `/model`(不產生回音泡泡),之後由既有的面板監看讀到畫面上的面板。
    /// 什麼都沒送出(Agent 不在、對話已變更、唯讀…)時 sheet 只顯示目前模型與原因,原因放在 `notice`。
    public func beginChoosingModel() async {
        guard canChooseModel else { return }
        isChoosingModel = true
        modelSheetPage = .models
        modelPanelUnreadable = false
        effortBaseline = nil
        notice = nil
        refreshModelCatalog()
        await sendModelCommand()
    }

    private func sendModelCommand() async {
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        switch await freshTarget() {
        case .success(let agent):
            let outcome = await delivery.send("/model", to: agent, expectedSession: boundSessionID ?? knownSessionID)
            switch outcome {
            case .submittedCommand:
                watchForPanel()
            case .noResponse:
                notice = .noResponse
                isChoosingModel = false
            default:
                isChoosingModel = false
            }
        case .failure(let failure):
            notice = failure.notice
            isChoosingModel = false
        }
    }

    /// 在 sheet 點選一個模型:移動面板游標到那一列,再按面板自己的 `s`(只用在這個 session;永不送數字)。
    /// 按鍵送不出去就維持原模型,`notice` 說明。
    public func chooseModel(_ option: SlashPanelOption) async {
        guard let panel, isChoosingModel, modelSheetPage == .models else { return }
        isSwitchingModel = true
        defer { isSwitchingModel = false }
        guard await operatePanel(.select(option)) else {
            notice = .modelSwitchFailed
            isChoosingModel = false
            return
        }
        // 面板的 Enter 是「設為預設」(寫進使用者設定);膠囊只改這個 session,所以有 `s`(只用在這個 session)就按它。
        if let confirm = panel.actions.first(where: { $0.key == "s" }) ?? panel.actions.first(where: { $0.key == "enter" }) {
            guard await operatePanel(.action(confirm)) else {
                notice = .modelSwitchFailed
                isChoosingModel = false
                return
            }
        }
        isChoosingModel = false
    }

    /// sheet 關閉(選定後或使用者下滑／按完成):面板還開著就取消(在投入程度子頁且有改動則確認),不改模型。
    public func finishChoosingModel() async {
        guard isChoosingModel else { return }
        isChoosingModel = false
        let key = modelSheetPage == .effort && effortChanged ? "enter" : "esc"
        modelSheetPage = .models
        effortBaseline = nil
        if let action = panel?.actions.first(where: { $0.key == key }) {
            await operatePanel(.action(action))
        }
    }

    // MARK: - 投入程度子頁(#384)

    /// 子頁上的層級滑桿(讀到 `/effort` 面板後才有)。
    public var effortSlider: SlashPanelSlider? { modelSheetPage == .effort ? panel?.slider : nil }

    /// Ultracode 開關只在目前模型支援 xhigh 時出現:面板有開關,且層級含 xhigh。
    public var showsUltracode: Bool {
        guard modelSheetPage == .effort, let panel, panel.ultracode != nil, let slider = panel.slider else { return false }
        return slider.levels.contains { $0.lowercased() == "xhigh" }
    }

    public var ultracodeIsOn: Bool { panel?.ultracode == true }

    /// 子頁開著後層級或 Ultracode 與剛進來時不同。
    public var effortChanged: Bool {
        guard modelSheetPage == .effort, let baseline = effortBaseline, let panel, let slider = panel.slider else { return false }
        return slider.current != baseline.level || panel.ultracode != baseline.ultracode
    }

    /// 點「投入程度」列:先 Esc 收掉 `/model` 面板(不改模型),再送 `/effort` 讀滑桿面板。
    public func openEffortPage() async {
        guard isChoosingModel, modelSheetPage == .models, !isOperatingPanel else { return }
        if let esc = panel?.actions.first(where: { $0.key == "esc" }) {
            await operatePanel(.action(esc))
        }
        panel = nil
        modelSheetPage = .effort
        effortBaseline = nil
        modelPanelUnreadable = false
        notice = nil
        await sendEffortCommand()
    }

    private func sendEffortCommand() async {
        panelWatchUntil = clock.now().addingTimeInterval(Self.panelWatch)
        switch await freshTarget() {
        case .success(let agent):
            let outcome = await delivery.send("/effort", to: agent, expectedSession: boundSessionID ?? knownSessionID)
            if outcome == .submittedCommand {
                watchForPanel()
            } else {
                if outcome == .noResponse { notice = .noResponse }
                panelWatchUntil = nil
                updatePanelReadability()
            }
        case .failure(let failure):
            notice = failure.notice
            panelWatchUntil = nil
            updatePanelReadability()
        }
    }

    /// 點一個層級:只移動滑桿(送方向鍵),離開子頁時才確認。
    public func chooseEffortLevel(_ level: Int) async {
        guard modelSheetPage == .effort else { return }
        await operatePanel(.level(level))
    }

    /// 切換 Ultracode(Tab)。
    public func toggleUltracode() async {
        guard showsUltracode else { return }
        await operatePanel(.toggleUltracode)
    }

    /// 離開子頁:有改動就按 Enter 確認(成為新 session 的預設),沒有就 Esc;接著重開 `/model` 回到模型列。
    public func closeEffortPage() async {
        guard modelSheetPage == .effort else { return }
        let key = effortChanged ? "enter" : "esc"
        let action = panel?.slider != nil ? panel?.actions.first(where: { $0.key == key }) : nil
        modelSheetPage = .models
        effortBaseline = nil
        if let action { await operatePanel(.action(action)) }
        panel = nil
        modelPanelUnreadable = false
        await sendModelCommand()
    }

    /// 面板 sheet 被使用者關掉(下滑或「完成」)時：面板還開著就按 Esc 取消，不改設定(#366)。
    public func dismissPanel() async {
        guard !isChoosingModel, let esc = panel?.actions.first(where: { $0.key == "esc" }) else { return }
        await operatePanel(.action(esc))
    }

    // MARK: - 畫面狀態列(#446)

    /// 這個 Agent 的畫面有可讀的狀態列(Antigravity):模式、模型、effort 只顯示、不能在 app 切換。
    public var readsStatusLine: Bool { screenDialect.statusLine != nil }

    /// 畫面最底下狀態列讀到的模式、模型與 effort(Antigravity,#446);還沒讀到或這個 Agent 沒有狀態列是 `nil`。
    public private(set) var screenStatusLine: AgentStatusLine?
    @ObservationIgnored private var statusLineReadStatus: AgentStatus?
    @ObservationIgnored private var pollsSinceStatusLine = 0

    /// 這個 Agent 的狀態列每隔幾次輪詢重讀一次(輪詢 2～4 秒一次,約半分鐘),狀態變了(開始工作、做完)也重讀。
    private static let statusLineRefreshPolls = 8

    /// 讀一次畫面的狀態列;認不出(被蓋住、讀不到)沿用上次。只讀、不送按鍵。
    public func refreshStatusLine() async {
        guard screenDialect.statusLine != nil, !isOffline, let screen = await readScreen() else { return }
        pollsSinceStatusLine = 0
        statusLineReadStatus = agentStatus
        if let line = screenDialect.readStatusLine(in: Self.plainText(ansi: screen)) { screenStatusLine = line }
    }

    /// 輪詢迴圈每輪呼叫:第一次、Agent 狀態變了或隔了一段時間才讀(指令預算:平常的輪詢不讀畫面)。
    private func refreshStatusLineIfDue() async {
        guard screenDialect.statusLine != nil, !isOffline else { return }
        pollsSinceStatusLine += 1
        guard screenStatusLine == nil && statusLineReadStatus == nil
            || statusLineReadStatus != agentStatus || pollsSinceStatusLine >= Self.statusLineRefreshPolls else { return }
        await refreshStatusLine()
    }

    // MARK: - 權限模式(#306、#383)

    /// 畫面讀到的模式與當時對話紀錄的原文。紀錄沒變就用畫面補「剛切換、紀錄尚未寫入」的空檔;紀錄一更新就以紀錄為準。
    private struct ScreenObservation {
        var mode: AgentPermissionMode
        var transcriptValue: String?
    }

    private var screenObservation: ScreenObservation?
    /// 這個聊天看過的模式(畫面標示、對話紀錄),用來決定輪替裡有沒有略過權限與自動。
    private var observedPermissionModes: Set<AgentPermissionMode> = []

    /// Claude 目前的權限模式:對話紀錄尾端最後一筆為準(電腦端改了也會同步),畫面只補空檔;都沒有是 `nil`。
    public var permissionMode: AgentPermissionMode? {
        // Antigravity 的對話紀錄沒有權限模式,以畫面狀態列為準(#446)。
        if screenDialect.statusLine != nil, let mode = statusFileLine?.mode ?? screenStatusLine?.mode { return mode }
        let fromTranscript = metadata.permissionMode.flatMap { AgentPermissionMode(transcriptValue: $0) }
        if let seen = screenObservation, seen.transcriptValue == metadata.permissionMode { return seen.mode }
        return fromTranscript ?? screenObservation?.mode
    }

    /// Shift+Tab 輪替裡有哪些模式:預設一般、接受編輯、Plan;看過略過權限或自動才加入。
    public var permissionModeAvailability: PermissionModeAvailability {
        var availability = PermissionModeAvailability()
        for mode in observedPermissionModes { availability.observe(mode) }
        if let permissionMode { availability.observe(permissionMode) }
        return availability
    }

    /// 面板上的模式選項(依輪替順序);目前是 `dontAsk` 時多一列只顯示的它。
    /// 有自己輪替的 Agent(Antigravity)固定是它輪替裡的幾種。
    public var permissionModeOptions: [AgentPermissionMode] {
        screenDialect.switchablePermissionModes ?? permissionModeAvailability.options(current: permissionMode)
    }

    /// Codex 的核准政策原文(例:`on-request`);只顯示,不能在手機切換。其他 Agent 是 `nil`。
    public var approvalPolicy: String? {
        screenDialect.showsApprovalPolicy ? metadata.approvalPolicy : nil
    }

    private func noteTranscriptPermissionMode() {
        if let mode = metadata.permissionMode.flatMap({ AgentPermissionMode(transcriptValue: $0) }) {
            observedPermissionModes.insert(mode)
        }
    }

    /// 一批對話紀錄行裡出現過的權限模式都記下(同一批有多次切換時,中間的模式也算看過)。
    private func notePermissionModes(in lines: [String]) {
        for line in lines where line.contains("\"permissionMode\"") {
            var scratch = TranscriptMetadata()
            scratch.update(with: line)
            if let mode = scratch.permissionMode.flatMap({ AgentPermissionMode(transcriptValue: $0) }) {
                observedPermissionModes.insert(mode)
            }
        }
    }

    private func observeScreen(_ mode: AgentPermissionMode) {
        observedPermissionModes.insert(mode)
        screenObservation = ScreenObservation(mode: mode, transcriptValue: metadata.permissionMode)
    }
    /// 正在切到這個模式(膠囊顯示進行中)。
    public private(set) var switchingPermissionMode: AgentPermissionMode?
    public var isSwitchingPermissionMode: Bool { switchingPermissionMode != nil }
    @ObservationIgnored private var permissionModeProbed = false

    /// 只有畫面方言有權限模式(Claude Code)且驗證過才開放切換。
    public var supportsPermissionMode: Bool { screenDialect.switchesPermissionMode }

    /// 膠囊可以操作:讀到目前模式、沒在切換、沒離線;唯讀裝置不行(畫面說明)。
    public var canSwitchPermissionMode: Bool {
        supportsPermissionMode && permissionMode != nil && !isSwitchingPermissionMode && permissionModeLock == nil
    }

    /// 面板的權限選項為什麼停用(#380);可切換時是 `nil`。
    public enum PermissionModeLock: Equatable, Sendable {
        case readOnlyDevice
        case offline
        /// Agent 在工作:這個 Agent 的切換只驗證過閒置時(Antigravity)。
        case working
        /// Agent 在等使用者回覆:這時 Shift+Tab 會變成「核准」。
        case waitingForYou
    }

    public var permissionModeLock: PermissionModeLock? {
        if isReadOnly { return .readOnlyDevice }
        if isOffline { return .offline }
        if agentStatus == .blocked { return .waitingForYou }
        if agentStatus == .working, screenDialect.switchesPermissionModeOnlyWhenIdle { return .working }
        return nil
    }

    /// 讀一次畫面:對話紀錄還沒有模式時用它當目前模式,紀錄有值就以紀錄為準(畫面只用來記錄看過哪些模式);認不出沿用上次。
    public func refreshPermissionMode() async {
        guard supportsPermissionMode, let mode = await readPermissionMode() else { return }
        if metadata.permissionMode == nil {
            observeScreen(mode)
        } else {
            observedPermissionModes.insert(mode)
        }
    }

    /// 每次 `run` 第一輪輪詢後讀一次(平常的輪詢不讀畫面,指令預算)。
    private func probePermissionModeIfNeeded() async {
        guard !permissionModeProbed, supportsPermissionMode, !isReadOnly, !isOffline else { return }
        permissionModeProbed = true
        await refreshPermissionMode()
    }

    /// 最近一次切換失敗的原因(#306);切換成功、再試或換 Agent 時清掉。膠囊的 sheet 顯示說明與「再試一次」。
    public private(set) var permissionModeFailure: PermissionModeFailure?

    /// 對上次失敗的目標再切一次。
    public func retryPermissionMode() async {
        guard let target = permissionModeFailure?.target else { return }
        await setPermissionMode(target)
    }

    /// 送 Shift+Tab(herdr `shift+tab`)到畫面顯示目標模式,最多 `maximumSwitchAttempts` 次。
    /// 主機服務沒有專屬切換訊息,所以 SSH 與 HTTPS 都是按鍵加讀畫面;按鍵帶 `expected_session`,對話已換掉就不按。
    /// 目標是略過權限或自動時,輪替一圈回到看過的模式就停(這個 session 沒開,再按也不會出現)。
    /// 失敗記在 `permissionModeFailure`,可再試;離開聊天(取消)時直接結束、不算失敗。
    public func setPermissionMode(_ target: AgentPermissionMode) async {
        guard supportsPermissionMode, !isSwitchingPermissionMode, target.isSwitchable else { return }
        // 有自己輪替的 Agent:目標不在輪替裡(例如略過權限)按不出來,一個鍵都不送。
        if let cycle = screenDialect.permissionModeCycle, !cycle.contains(target) { return }
        guard !isReadOnly else {
            notice = .readOnlyDevice
            return
        }
        // 離線,或 Agent 在等你回覆(這時 Shift+Tab 會變成「核准」):一個鍵都不送。
        guard permissionModeLock == nil else { return }
        permissionModeFailure = nil
        switchingPermissionMode = target
        defer { switchingPermissionMode = nil }
        guard var current = await readPermissionMode() else {
            permissionModeFailure = .unreadable(target: target)
            return
        }
        observeScreen(current)
        let expectation = SendExpectation(session: boundSessionID ?? knownSessionID)
        var visited: Set<AgentPermissionMode> = [current]
        var attempts = 0
        while current != target, attempts < AgentPermissionMode.maximumSwitchAttempts {
            do {
                try await client.sendKeys(paneID: paneID, keys: ["shift+tab"], expecting: expectation)
            } catch is CancellationError {
                return
            } catch {
                permissionModeFailure = error as? HostServiceError == .paneChanged
                    ? .paneChanged(target: target) : .keysFailed(target: target)
                haptics.play(.error)
                return
            }
            attempts += 1
            do { try await sleep(.milliseconds(300)) } catch { return }
            guard var read = await readPermissionMode() else { break }
            // 有自己輪替的 Agent:畫面可能還沒重畫(讀到的模式沒變),先再讀幾次,不要重複按而跳過目標。
            var rereads = 0
            while screenDialect.permissionModeCycle != nil, read == current, rereads < Self.staleModeRereads {
                rereads += 1
                do { try await sleep(.milliseconds(300)) } catch { return }
                guard let again = await readPermissionMode() else { break }
                read = again
            }
            let wrapped = read != current && !visited.insert(read).inserted
            current = read
            observeScreen(read)
            if wrapped, current != target {
                permissionModeFailure = .modeUnavailable(target)
                haptics.play(.error)
                return
            }
        }
        if current != target {
            permissionModeFailure = .notReached(attempts: attempts, target: target)
            haptics.play(.error)
        } else {
            haptics.play(.selection)
        }
    }

    /// 按了 Shift+Tab 後畫面沒變時最多再讀幾次(每次隔 0.3 秒)才再按。
    private static let staleModeRereads = 2

    /// 讀畫面認出目前的權限模式(依畫面方言);狀態列方言順便更新狀態列,讓膠囊與標題跟著變。
    private func readPermissionMode() async -> AgentPermissionMode? {
        guard let screen = await readScreen() else { return nil }
        if screenDialect.statusLine != nil, let line = screenDialect.readStatusLine(in: Self.plainText(ansi: screen)) {
            screenStatusLine = line
            return line.mode
        }
        return screenDialect.readPermissionMode(in: screen)
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
        AgentCatalog.profile(forHerdrName: agent.kind).screen.readsPromptSuggestions && (agentStatus == .done || agentStatus == .idle) && prompt == nil
    }

    /// 在等下一步、這段期間還能讀時，讀含 ANSI 的畫面找建議(#121)。在面板判定之前讀，讀到的畫面去掉 ANSI 後
    /// 給這次輪詢的面板、背景 agents 窗格共用(R-F02);這次輪詢已讀過純文字畫面(分不出灰色建議)就留到下次。
    /// 讀取期間建議被清掉(送出)時結果作廢，畫面也不共用。
    private func readSuggestion(_ agent: Agent) async -> SuggestionRead? {
        guard awaitsNextPrompt(agent), suggestionReadsLeft > 0, screenThisPoll == nil else { return nil }
        let epoch = suggestionEpoch
        suggestionReadsLeft -= 1
        guard let screen = await readScreen(format: .ansi), epoch == suggestionEpoch else { return nil }
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

    /// 標題列(#270):workspace 名稱、狀態與主機名。
    public var header: ConversationHeader {
        ConversationHeader(
            agent: currentAgent, title: title, status: agentStatus, isOffline: isOffline, hostName: hostName(), progress: displayProgress,
            permissionMode: supportsPermissionMode || screenDialect.statusLine != nil ? permissionMode : nil, tabName: tabName)
    }

    /// 重新載入(F5.7):清掉這個聊天的快取、游標與歷史(含停止追蹤的 workflow),重新定位並讀視窗。
    public func reload() async {
        await cache.remove(chatKey: chatKey)
        unbind(keepingDisplay: true)
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
                if screenThisPoll == nil { screenThisPoll = await readScreen() }
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

    /// 解除目前的對話綁定。`keepingDisplay` 時畫面上的訊息留到新內容讀回來(#329),`isRefreshing` 標示讀取中。
    private func unbind(keepingDisplay: Bool = false) {
        stopFollowingUpdates()
        if let path = file?.path {
            let transcripts = transcripts
            Task { await transcripts.stopFollowing(path: path) }
        }
        generation += 1
        workflowModels = [:]
        boundSessionID = nil
        file = nil
        isRefreshing = keepingDisplay
        if keepingDisplay { return }
        clearDisplay()
    }

    /// 清掉顯示中的訊息(沒有新內容可換上時，例如新 session 還沒有對話紀錄)。
    private func clearDisplay() {
        isRefreshing = false
        recent = []
        segments = []
        olderMessages = []
        metadata = TranscriptMetadata()
        progress = AgentProgress()
        older = .reachedStart
        rebuild()
    }

    /// 以目前的訊息整份取代時間軸(開啟、重新整理、清空);已存在的列沿用身分。
    private func rebuild() {
        applyTimeline(timeline.reset(olderMessages + recent))
    }

    /// 把時間軸的變更交給畫面:沒有變更就不動 `items`(不觸發重繪)。
    private func applyTimeline(_ update: ConversationTimeline.Update) {
        guard !update.changes.isEmpty else { return }
        items = timeline.items
        rebuildEntries()
        for change in update.changes {
            switch change {
            case .inserted(.workflow(let card), _), .updated(.workflow(let card), _): workflowModels[card.id]?.update(card: card)
            default: break
            }
        }
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
        let parsed = dialect.parse(lines)
        if !parsed.skips.isEmpty { onTranscriptSkips?(dialect, parsed.skips) }
        return parsed.messages.filter { seen.insert($0.id).inserted }
    }
}

/// 停止列的停止進度與結果(#220)。
public enum StopPhase: Sendable, Equatable {
    case stopping
    /// 已停止(2 秒後自動收起)。
    case stopped
    /// 3 秒內沒停下，或停止中超過 10 秒。
    case stillWorking
    /// 送不出 Esc。
    case failed
    /// 送出後讀不到狀態，不知道停了沒。
    case unconfirmed
    /// agent 在等你回答：停止或強制結束都沒送(F6.7)。
    case needsAnswer
    /// 送不出強制結束的 Ctrl-C。
    case forceQuitFailed
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
    /// 一則最多 10 個附件(F7、#352)。
    case attachmentLimit
    /// 離線時附件不能排隊(#382):連上後才能加入。
    case attachOffline
    /// 讀不出圖片。
    case imageUnreadable
    /// 原始圖片超過單張上限(`ImageUploadLimit.maximumSize`)。
    case imageTooLarge
    /// 圖片上傳失敗：整則沒送出，草稿與圖片保留。
    case uploadFailed
    /// 檔案超過上傳上限(#286):附上檔案大小與上限(bytes)。
    case fileTooLarge(size: Int, limit: Int)
    /// 讀不到挑選的檔案。
    case fileUnreadable
    /// 檔案上傳到主機失敗，路徑沒有插入。
    case fileUploadFailed
    /// 影片壓到最小仍超過上傳上限(#474),或太長壓不進去。
    case videoTooLong
    /// 讀不到挑選的影片。
    case videoUnreadable
    /// HTTPS 主機的主機服務太舊、還不能上傳圖片或檔案(#288):提示更新主機服務。
    case hostServiceUpdateRequired(installedVersion: String?)
    /// 送不出 slash 面板的按鍵(#45)。
    case panelKeysFailed
    /// 切換模型沒有完成(#384):按鍵沒送到主機,對話維持原本的模型。
    case modelSwitchFailed
    /// 這支裝置配對成唯讀，什麼都沒送出。
    case readOnlyDevice
}

/// 切換權限模式失敗的原因(#306)。
public enum PermissionModeFailure: Equatable, Sendable {
    /// 試了 `attempts` 次，畫面上沒有看到 `target`。
    case notReached(attempts: Int, target: AgentPermissionMode)
    /// 輪替一圈沒有出現目標模式(略過權限、自動):這個 session 沒有開。
    case modeUnavailable(AgentPermissionMode)
    /// 讀不到畫面，不知道目前是哪個模式。
    case unreadable(target: AgentPermissionMode)
    /// 按鍵沒送到主機。
    case keysFailed(target: AgentPermissionMode)
    /// 對話已被換成別的(送出前比對不符)，什麼都沒按。
    case paneChanged(target: AgentPermissionMode)

    /// 再試一次要切到的模式;略過權限沒開時再試沒有意義。
    public var target: AgentPermissionMode? {
        switch self {
        case .notReached(_, let target), .unreadable(let target), .keysFailed(let target), .paneChanged(let target): target
        case .modeUnavailable: nil
        }
    }
}
