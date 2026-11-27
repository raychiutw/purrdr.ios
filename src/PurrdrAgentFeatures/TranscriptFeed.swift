import Foundation
import PurrdrCore

/// 對話紀錄來源交給聊天套用的增量(#684):時間軸怎麼變，加上這次之後的 metadata、進度與「往上還有沒有」。
package struct TranscriptDelta {
    package enum Timeline: Sendable {
        /// 時間軸不變(只有狀態,例如補讀途中或往上翻的讀取進行中)。
        case none
        /// 整份換掉(開啟、還原快取、清空、補讀完)。
        case rebuild([TranscriptMessage])
        /// 接在後面;`droppedOldest` 是同時修剪掉的最舊訊息數(沒修剪是 `nil`)。
        case append([TranscriptMessage], droppedOldest: Int?)
        /// 往上補(舊頁接在最前面)。
        case prepend([TranscriptMessage])
    }

    /// 這次內容裡出現過的權限模式要怎麼記(給 Agent 控制的觀察)。
    package enum PermissionModes: Sendable {
        case none
        /// 一批對話紀錄行(同一批有多次切換時，中間的模式也算看過)。
        case lines([String])
        /// 以 metadata 的權限模式為準(從快取還原)。
        case metadata
    }

    package var timeline: Timeline
    package var metadata: TranscriptMetadata
    package var progress: AgentProgress
    package var older: ConversationModel.Older
    package var permissionModes: PermissionModes
}

/// 對話紀錄來源(Transcript feed,#684、GLOSSARY「對話紀錄來源」):一個聊天持續從它的對話紀錄取得增量。
///
/// 綁定 Agent 的 session、開啟時讀檔尾、跟隨最新、往前補讀、修剪過舊的內容，並還原與寫入本機快取。
/// 對外只交出帶原因的增量(`TranscriptDelta`:整份換掉、新增、往上補),由聊天套到對話時間軸;
/// 換了 session 或已經過期的讀取結果在這裡丟掉(世代檢查只在這個 module 內,各步驟用 `isCurrent`),不會交出去。
/// 只經主機連線(`TranscriptReader`)讀取,看不到主機通道。
@MainActor
package final class TranscriptFeed {
    /// 來源交給聊天的事件。
    package enum Event {
        case delta(TranscriptDelta)
        /// 追蹤途中讀取失敗(目前的 session 才會交出)。
        case readFailed(any Error)
        /// 追蹤又收到內容:先前的讀取失敗橫幅可以收起。
        case recovered
    }

    /// 一次 `read` 的結果。
    package enum ReadResult: Equatable {
        /// 已追上主機;新內容之後由追蹤送來(或下次輪詢讀)。
        case caughtUp
        /// 讀取途中換了 session(或解除綁定):結果已丟掉,什麼都沒交出。
        case superseded
        /// 讀取失敗(目前的 session)。找不到檔案、不只一個、壓縮的情況來源已自己放掉檔案。
        case failed(any Error)

        package static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.caughtUp, .caughtUp), (.superseded, .superseded): true
            default: false
            }
        }
    }

    // MARK: 設定

    private let reader: TranscriptReader
    private let cache: any ConversationCache
    private let chatKey: String
    /// 列表傳來的 session:快取只在與它相同時秒開或離線顯示(F5.3、#97)。
    private let knownSessionID: String?
    private let clock: ConversationClock
    private let timings: ChatOpenTimings
    private let openLines: Int
    private let openMaxBytes: Int
    private let pageLines: Int
    private let onSkips: (@Sendable (TranscriptDialect, TranscriptSkips) -> Void)?

    package var onEvent: (@MainActor (Event) -> Void)?
    /// 對話紀錄的路徑出現或換了(清單要連同 session 內的 skill 一起重讀,#469)。
    package var onPathChange: (@MainActor (String) -> Void)?
    /// 對話紀錄的解析與重建在背景做(#498);測試用:每次背景計算開頭呼叫(在背景執行緒上)。
    package var onTranscriptWork: (@Sendable () -> Void)?
    /// 畫面跟隨尾端(由畫面告知)。只有跟隨中才修剪最舊的訊息:讀者正在看的不會被拿掉。
    package var isFollowingLatest = true
    /// `run()` 期間對話紀錄追蹤的節奏(內部輪詢的連線方式用);不在 `run()` 裡時沒有。
    package var followPace: TranscriptFollowPace?

    /// 跟隨尾端時記憶體裡最多保留的訊息數(含往上翻的舊頁;與快取的上限相同)。超過時整段修剪最舊的，可以往上翻回來。
    package static let followingMessageLimit = CachedConversation.maxMessages
    /// 往上翻讀到的舊訊息上限:不跟隨最新時不修剪(使用者正在讀),以這個上限擋住無限成長;回到最新才丟掉舊頁。
    package static let scrollbackMessageLimit = 4 * CachedConversation.maxMessages
    /// 補讀單頁行數上限。
    package static let maximumBackfillPageLines = 1_600
    /// 開啟視窗沒有訊息時最多往前讀幾頁(每頁 `pageLines` 行)。
    package static let maximumEmptyWindowPages = 25
    /// 追蹤事件觸發的快取寫入最短間隔(秒);離開聊天時一定補寫(#510)。
    package static let cacheSaveInterval: TimeInterval = 5

    // MARK: 狀態

    /// 目前綁定的 session(herdr 回報的 id 或路徑)。
    package private(set) var boundSessionID: String?
    /// 對話紀錄的方言:由綁定時的 Agent 設定檔決定,還沒綁定(例如只從快取還原)時沒有。
    package private(set) var dialect: TranscriptDialect?
    /// 對話紀錄的路徑、即時追蹤的游標，以及開啟視窗的 byte 起點(往上翻的錨點)。
    /// `follow.isLive`:這次可見期間已經追上主機，之後落後再多也從游標分段接著讀(#130);還沒追上(剛從快取恢復、
    /// 畫面重新可見)時落後太多改讀新視窗(F5.3 第 3 點、R-B08)。
    private var file: (path: String, follow: TranscriptFollow, windowStart: Int)? {
        didSet {
            guard let path = file?.path, path != oldValue?.path else { return }
            onPathChange?(path)
        }
    }
    /// 開啟視窗與之後追蹤到的訊息(會寫入快取);讀取與快取的真相(分段、修剪、寫快取、重整都以它為準)。
    package private(set) var recent: [TranscriptMessage] = []
    /// `recent` 由哪幾段讀取組成(每段的 byte 起點與訊息數，依序、加總等於 `recent.count`)。修剪與寫快取都以整段為單位，
    /// 視窗起點因此是某一段的開頭，往上翻接得上、不缺訊息(#130)。
    package private(set) var segments: [(start: Int, count: Int)] = []
    /// 往上翻載入的舊訊息(不寫入快取)。
    package private(set) var olderMessages: [TranscriptMessage] = []
    package private(set) var metadata = TranscriptMetadata()
    package private(set) var progress = AgentProgress()
    package private(set) var older: ConversationModel.Older = .reachedStart
    /// 每次綁定新 session 遞增;晚到的舊 session 結果直接丟棄(R-B07)。
    package private(set) var generation = 0

    private var following: ActiveFollow?
    /// 並行定位(#661):列表已知這個聊天的對話目標時,在讀主機狀態的同時就先找對話檔。
    private var prefetchedLocate: (target: TranscriptTarget, task: Task<TranscriptFile, any Error>)?
    /// 對話紀錄各段依到達順序套用的鎖:解析在背景做,結果回主執行緒以增量交出。
    private let applyGate = TranscriptSerialGate()
    private var isLeaving = false
    private var leavingWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lastCacheSaveAt: Date?
    package private(set) var cacheIsDirty = false
    private var cacheNoted = false

    /// 一個進行中的對話紀錄追蹤。`id` 讓結束的追蹤只清掉自己(不清後來開的)。
    private struct ActiveFollow {
        let path: String
        let id: UUID
        let task: Task<Void, Never>

        init(path: String, start: (UUID) -> Task<Void, Never>) {
            self.path = path
            id = UUID()
            task = start(id)
        }
    }

    package init(
        reader: TranscriptReader, cache: any ConversationCache, chatKey: String, knownSessionID: String?, clock: ConversationClock,
        openLines: Int, openMaxBytes: Int, pageLines: Int, timings: OperationTimingSink?,
        onSkips: (@Sendable (TranscriptDialect, TranscriptSkips) -> Void)?
    ) {
        self.reader = reader
        self.cache = cache
        self.chatKey = chatKey
        self.knownSessionID = knownSessionID
        self.clock = clock
        self.openLines = openLines
        self.openMaxBytes = openMaxBytes
        self.pageLines = pageLines
        self.timings = ChatOpenTimings(sink: timings)
        self.onSkips = onSkips
    }

    /// 對話紀錄在主機上的路徑(還沒定位或找不到檔案時是 `nil`)。
    package var path: String? { file?.path }
    /// 目前持有的全部訊息(往上翻的舊頁加開啟視窗與之後追蹤到的)。
    package var messages: [TranscriptMessage] { olderMessages + recent }

    // MARK: - 綁定

    /// 綁定到這個 Agent 的對話紀錄:session 換了(輪替,或回收 slot 中的新聊天)就丟掉舊的游標與快取、舊內容留著到新內容讀回來(#329)。
    /// 方言每次都以 Agent 設定檔給的為準。回傳是不是換了 session。
    package func bind(to target: TranscriptTarget) async -> Bool {
        var changed = false
        if boundSessionID != target.sessionKey {
            // F5.1 第 4 點。
            if boundSessionID != nil { await cache.remove(chatKey: chatKey) }
            // 並行定位(#661)的結果屬於這個 session 時留著(第一次綁定就是這樣),別的 session 的丟掉。
            if prefetchedLocate?.target.sessionKey != target.sessionKey { discardPrefetchedLocate() }
            resetBinding(keepingDisplay: true)
            boundSessionID = target.sessionKey
            changed = true
        }
        dialect = target.dialect
        return changed
    }

    /// 解除綁定:停止追蹤、讓進行中的讀取過期。`keepingDisplay` 時內容留到新內容讀回來,否則清空。
    package func unbind(keepingDisplay: Bool) {
        discardPrefetchedLocate()
        resetBinding(keepingDisplay: keepingDisplay)
    }

    private func resetBinding(keepingDisplay: Bool) {
        stopFollowing()
        if let path = file?.path {
            let reader = reader
            Task { await reader.stopFollowing(path: path) }
        }
        generation += 1
        boundSessionID = nil
        file = nil
        if keepingDisplay { return }
        clear()
    }

    /// 清掉持有的內容(沒有新內容可換上時,例如新 session 還沒有對話紀錄)。
    package func clear() {
        recent = []
        segments = []
        olderMessages = []
        metadata = TranscriptMetadata()
        progress = AgentProgress()
        older = .reachedStart
        emitRebuild()
    }

    /// 畫面重新可見:當作重新開啟(已在追蹤時,離開期間落後太多就讀新視窗,不逐段重播積壓,R-B08)。
    package func reopen() {
        file?.follow.reopen()
    }

    /// 最後一個畫面不在了:主機推送尾端的連線方式(HTTPS)停止追蹤。下次開啟從游標重新開始。
    package func stopHostFollowing() async {
        if let path = file?.path { await reader.stopFollowing(path: path) }
    }

    // MARK: - 讀取

    /// 列表已知對話目標時,不等主機狀態回來就先找對話檔(#661)。已經定位過就不送;上一輪沒用到的結果丟掉(可能過時)。
    /// 之後 `read` 的目標相同就沿用結果,不同(session 換了)就丟掉重找。
    package func prefetchLocate(_ target: TranscriptTarget) {
        guard file == nil else { return }
        discardPrefetchedLocate()
        let reader = reader
        let timings = timings
        prefetchedLocate = (target, Task { try await timings.timed("locate") { try await reader.locate(target) } })
    }

    private func discardPrefetchedLocate() {
        prefetchedLocate?.task.cancel()
        prefetchedLocate = nil
    }

    /// 讀對話紀錄:還沒定位就定位並讀視窗;已追上就從游標接著讀;追蹤中不讀(新內容由追蹤送來,#165)。
    package func read(_ target: TranscriptTarget) async -> ReadResult {
        let generation = generation
        let result: ReadResult
        do {
            if let file, following?.path == file.path {
                // 新內容由追蹤送來(#165),不讀尾端。
                result = .caughtUp
            } else if let file {
                // 已追上：落後多少都從游標分段接著讀，不改讀新視窗取代已顯示與往上翻的訊息(#130、R-B09)。
                // 還沒追上(剛從快取恢復、畫面重新可見):落後太多不逐段重播積壓，讀新視窗(R-B08)。
                let read = try await reader.follow(path: file.path, file.follow)
                guard isCurrent(generation) else { return .superseded }
                switch read.tail {
                case .unchanged:
                    self.file?.follow = read.next
                case .appended(let chunk):
                    self.file?.follow = read.next
                    await append(chunk)
                case .tooFarBehind(let size), .shrank(let size):
                    // 還沒追上時落後太多，或檔案被換掉(變小,真正的斷層):重讀視窗並重建列表。
                    try await openWindow(path: file.path, size: size, generation: generation)
                }
                result = isCurrent(generation) ? .caughtUp : .superseded
            } else {
                let located: TranscriptFile
                if let prefetched = prefetchedLocate, prefetched.target == target {
                    prefetchedLocate = nil
                    located = try await prefetched.task.value
                } else {
                    discardPrefetchedLocate()
                    located = try await timings.timed("locate") { try await reader.locate(target) }
                }
                guard isCurrent(generation) else { return .superseded }
                try await openWindow(path: located.path, size: located.size, generation: generation)
                result = isCurrent(generation) ? .caughtUp : .superseded
            }
            if result == .caughtUp { startFollowing() }
        } catch {
            guard isCurrent(generation) else { return .superseded }
            releaseFileIfGone(error)
            await saveCacheIfBound(to: target)
            return .failed(error)
        }
        if result == .caughtUp { await saveCacheIfBound(to: target) }
        return result
    }

    private func saveCacheIfBound(to target: TranscriptTarget) async {
        if boundSessionID == target.sessionKey { await saveCache() }
    }

    /// 這次讀取還是不是目前的(沒換 session、沒解除綁定)。
    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// 找不到檔案、不只一個、壓縮了:放掉檔案(下次輪詢重新定位)。其他錯誤保留檔案與內容,下次輪詢重試。
    private func releaseFileIfGone(_ error: any Error) {
        switch error {
        case TranscriptReadError.absent, TranscriptReadError.ambiguous, TranscriptReadError.compressed: file = nil
        default: break
        }
    }

    /// 讀最後 `openLines` 行並**取代**目前的訊息。
    private func openWindow(path: String, size: Int, generation: Int) async throws {
        // 以剛探測到的大小為上限:agent 同時在寫也不會變成無上限的補讀(§4.7)。
        var chunk = try await timings.timed("window") {
            try await reader.window(path: path, endingAt: size, lines: openLines, maxBytes: openMaxBytes > 0 ? openMaxBytes : nil)
        }
        guard isCurrent(generation) else { return }
        if chunk.lines.isEmpty, chunk.start > 0 {
            // 最後一行比 byte 上限還大：放寬成只讀那一行(上限的目的是慢網路下別讀太多，但一行都沒有就沒東西可看)。
            chunk = try await reader.window(path: path, endingAt: size, lines: 1)
            guard isCurrent(generation) else { return }
        }
        let opened = chunk
        await applyGate.run {
            guard isCurrent(generation), let dialect else { return }
            let prepared = await TranscriptProcessing.prepareWindow(lines: opened.lines, dialect: dialect, probe: onTranscriptWork)
            guard isCurrent(generation) else { return }
            if !prepared.skips.isEmpty { onSkips?(dialect, prepared.skips) }
            file = (path, TranscriptFollow(cursor: opened.end, isLive: true), opened.start)
            recent = prepared.messages
            segments = [(opened.start, recent.count)]
            olderMessages = []
            metadata = prepared.metadata
            progress = prepared.progress
            older = opened.start > 0 ? .available : .reachedStart
            emitRebuild(permissionModes: .lines(opened.lines))
        }
        guard isCurrent(generation) else { return }
        try await readEarlierUntilMessages(path: path, generation: generation)
    }

    /// 開啟視窗內沒有任何使用者／Agent 文字(最後幾十行都是 system、api-request-blob、file-history-snapshot 這類不產生訊息的紀錄)
    /// 但檔案前面有:往前一頁一頁讀到有訊息為止，不顯示「還沒有訊息」(#418)。有上限，避免超大檔案讀不完。
    private func readEarlierUntilMessages(path: String, generation: Int) async throws {
        var pages = 0
        // 補讀期間只更新訊息清單,補讀完(或中途失敗)才整份重建時間軸一次(#586);可讀與否看訊息,不看還沒更新的畫面項目。
        defer { if pages > 0, isCurrent(generation) { emitRebuild() } }
        while !Self.hasReadableMessage(in: olderMessages + recent), older == .available, let start = file?.windowStart, start > 0,
            pages < Self.maximumEmptyWindowPages
        {
            pages += 1
            // 每頁加倍(上限 `maximumBackfillPageLines`):尾端一長串工具步驟時，往返次數是使用者在等的時間(#508)。
            let lines = min(pageLines << min(pages - 1, 4), max(pageLines, Self.maximumBackfillPageLines))
            let page = try await timings.timed("earlier#\(pages)") { try await reader.window(path: path, endingAt: start, lines: lines) }
            guard isCurrent(generation) else { return }
            // 補讀的頁屬於「開啟視窗」而不是往上翻的舊頁:要進快取，下次開啟才立刻有可讀訊息(#508)。
            await prepend(page, generation: generation, intoWindow: true)
        }
    }

    // MARK: - 跟隨最新

    /// 已追上主機且有節奏(`run()` 裡):開始追蹤目前的對話紀錄，之後的新內容由追蹤送來(#165)。
    package func startFollowing() {
        guard let followPace, let file, file.follow.isLive, following?.path != file.path else { return }
        following?.task.cancel()
        let path = file.path
        let cursor = file.follow.cursor
        let generation = generation
        following = ActiveFollow(path: path) { id in
            Task { await self.applyUpdates(path: path, from: cursor, pace: followPace, generation: generation, id: id) }
        }
    }

    package func stopFollowing() {
        following?.task.cancel()
        following = nil
    }

    /// 套用追蹤事件：新增接在後面;接不上時重讀視窗並從新游標再追蹤。追蹤以錯誤結束時回到輪詢讀一次再開始。
    private func applyUpdates(path: String, from cursor: Int, pace: TranscriptFollowPace, generation: Int, id: UUID) async {
        var isReplaced = false
        do {
            isReplaced = try await TranscriptFollowUpdates.apply(
                await reader.followTranscript(path: path, from: cursor, pace: pace),
                isCurrent: { isCurrent(generation) && file?.path == path },
                appended: { chunk in
                    // 畫面離開中先不套用(返回轉場期間不做整份重算);被取消就不套了。
                    await waitWhileLeaving()
                    guard !Task.isCancelled else { return }
                    file?.follow = TranscriptFollow(cursor: chunk.end, isLive: true)
                    await append(chunk)
                },
                replaced: { size in try await openWindow(path: path, size: size, generation: generation) },
                afterEach: {
                    onEvent?(.recovered)
                    await saveCacheThrottled()
                })
        } catch is CancellationError {
        } catch {
            if isCurrent(generation) {
                releaseFileIfGone(error)
                onEvent?(.readFailed(error))
            }
        }
        guard following?.id == id else { return }
        following = nil
        if isReplaced, !Task.isCancelled { startFollowing() }
    }

    // MARK: 離開中(返回列表的轉場)

    /// 畫面開始離開或回來時呼叫(聊天列表的 `viewWillDisappear`／`viewWillAppear`)。
    /// 離開中每則追加都讓整個聊天畫面重算與重排,全塞進返回動畫(開頭停滯、尾段凍結),而這個畫面馬上就釋放;
    /// 所以暫停套用,回來(取消返回、從子頁回來)再接上。
    package func setLeaving(_ leaving: Bool) {
        guard isLeaving != leaving else { return }
        isLeaving = leaving
        if !leaving {
            let waiters = leavingWaiters
            leavingWaiters = [:]
            for waiter in waiters.values { waiter.resume() }
        }
    }

    /// 離開中就等到回來或被取消。
    private func waitWhileLeaving() async {
        guard isLeaving else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isLeaving, !Task.isCancelled {
                    leavingWaiters[id] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in self.leavingWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    // MARK: - 新增與修剪

    /// 把新讀到的一段接在後面(解析在背景做,依到達順序套用)。
    package func append(_ chunk: TranscriptChunk) async {
        let generation = generation
        await applyGate.run {
            guard isCurrent(generation), let dialect else { return }
            let prepared = await TranscriptProcessing.prepareAppended(
                lines: chunk.lines, dialect: dialect, metadata: metadata, progress: progress, probe: onTranscriptWork)
            guard isCurrent(generation) else { return }
            if !prepared.skips.isEmpty { onSkips?(dialect, prepared.skips) }
            let known = Set(recent.map(\.id))
            let added = prepared.messages.filter { !known.contains($0.id) }
            recent += added
            if !added.isEmpty { segments.append((chunk.start, added.count)) }
            metadata = prepared.metadata
            progress = prepared.progress
            let dropped = trimIfFollowing()
            emit(.append(added, droppedOldest: dropped), permissionModes: .lines(chunk.lines))
        }
    }

    /// 跟隨尾端時訊息超過上限：丟掉往上翻的舊頁，再整段丟掉最舊的(至少留最後一段),視窗起點移到留下的第一段開頭，
    /// 之後往上翻可以讀回來(#130)。回傳丟掉的訊息數(沒修剪是 `nil`)。
    private func trimIfFollowing() -> Int? {
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
        return droppedMessageCount
    }

    // MARK: - 往上翻

    /// 把往上翻讀到的一頁接在最前面(解析在背景做，依到達順序套用)。
    private func prepend(_ page: TranscriptChunk, generation: Int, intoWindow: Bool = false) async {
        await applyGate.run {
            guard isCurrent(generation), let dialect else { return }
            let prepared = await TranscriptProcessing.prepareOlder(lines: page.lines, dialect: dialect, probe: onTranscriptWork)
            guard isCurrent(generation) else { return }
            if !prepared.skips.isEmpty { onSkips?(dialect, prepared.skips) }
            let known = Set((olderMessages + recent).map(\.id))
            let olderPage = prepared.messages.filter { !known.contains($0.id) }
            if intoWindow {
                recent = olderPage + recent
                segments.insert((page.start, olderPage.count), at: 0)
            } else {
                olderMessages = olderPage + olderMessages
            }
            file?.windowStart = page.start
            older = page.start > 0 ? .available : .reachedStart
            if older == .available, !intoWindow, olderMessages.count >= Self.scrollbackMessageLimit { older = .scrollbackLimitReached }
            // 補讀屬於開啟視窗:跟隨最新時維持在底部(「整份取代」的捲動規則),不當成往上翻而停在原列、讓位置跳動(#508)。
            // 補讀(intoWindow)連讀好幾頁時不逐頁重建,由 `readEarlierUntilMessages` 補讀完整份重建一次(#586)。
            emit(intoWindow ? .none : .prepend(olderPage))
        }
    }

    /// 讀上一頁(F5.4)。失敗靜默;session 改變後才到的頁丟棄(R-B05)。
    package func loadOlder() async {
        // 還沒綁定 Agent(只從快取還原、尚無方言)時解析不了舊頁:不動狀態,綁定後再讀。
        guard older == .available, dialect != nil, let file, file.windowStart > 0 else { return }
        let generation = generation
        older = .loading
        emit(.none)
        do {
            let chunk = try await reader.window(path: file.path, endingAt: file.windowStart, lines: pageLines)
            guard isCurrent(generation) else { return }
            await prepend(chunk, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            older = .available
            emit(.none)
        }
    }

    // MARK: - 快取

    /// 快取符合列表給的 session(沒給時只看解析器版本)。
    private func matchesKnownSession(_ cached: CachedConversation) -> Bool {
        knownSessionID.map { cached.matches(sessionID: $0) } ?? (cached.parserVersion == CachedConversation.parserVersion)
    }

    /// 快取符合列表給的 session 且值得還原。
    private func accepts(_ cached: CachedConversation) -> Bool {
        matchesKnownSession(cached) && Self.isWorthRestoring(cached)
    }

    /// 同步還原記憶體層裡這個聊天最近的內容(打開時第一幀就有內容,不閃骨架)。回傳有沒有還原。
    @discardableResult
    package func restoreFromMemory() -> Bool {
        guard let cached = cache.cachedConversation(chatKey: chatKey) else { return false }
        noteCache(cached)
        guard accepts(cached) else { return false }
        restore(cached)
        return true
    }

    /// 列表傳來的 session 與快取相同時，載入快取並從游標續讀(F5.3 第 1 點)。回傳有沒有還原。
    /// 列表還沒給 session(冷啟動、從推播打開)時也先還原這個聊天上次的快取(#356):之後快照回報的 session 不同，
    /// 綁定新 session 時丟掉快取，舊內容留著到新內容讀回來(#329)。
    package func restoreFromCache() async -> Bool {
        let cached = await cache.load(chatKey: chatKey)
        noteCache(cached)
        guard let cached, accepts(cached) else { return false }
        restore(cached)
        return true
    }

    private func restore(_ cached: CachedConversation) {
        boundSessionID = cached.sessionID
        file = (cached.path, TranscriptFollow(cursor: cached.cursor, isLive: false), cached.windowStart)
        recent = cached.messages
        segments = [(cached.windowStart, cached.messages.count)]
        metadata = cached.metadata
        older = cached.windowStart > 0 ? .available : .reachedStart
        emitRebuild(permissionModes: .metadata)
    }

    /// 連不上主機:唯讀顯示同一 session 的快取(只在快取屬於列表看到的 session 時,R-B16)。不綁定、不設游標。
    package func showCachedWhileOffline() async -> Bool {
        guard let knownSessionID, let cached = await cache.load(chatKey: chatKey), cached.matches(sessionID: knownSessionID),
            Self.isWorthRestoring(cached)
        else { return false }
        recent = cached.messages
        segments = [(cached.windowStart, cached.messages.count)]
        metadata = cached.metadata
        emitRebuild(permissionModes: .metadata)
        return true
    }

    /// 丟掉這個聊天的快取(重新載入、換 session)。
    package func removeCache() async {
        await cache.remove(chatKey: chatKey)
    }

    /// 本機快取有沒有命中、命中後有沒有被採用(每個來源只記第一次)。
    private func noteCache(_ cached: CachedConversation?) {
        guard timings.isEnabled, !cacheNoted else { return }
        cacheNoted = true
        guard let cached else { return timings.note("cache miss") }
        timings.note("cache hit")
        if !matchesKnownSession(cached) {
            timings.note("cache rejected session")
        } else if !Self.isWorthRestoring(cached) {
            timings.note("cache rejected content")
        } else {
            timings.note("cache used")
        }
    }

    /// 寫入快取：最多 `CachedConversation.maxMessages` 則(R-B13),以整段為單位從尾端取，視窗起點是取到的第一段開頭，
    /// 從快取恢復後往上翻接得上;往上翻的舊頁不寫入(F5.2)。最後一段本身就超過上限時只存它的最後幾則(往上翻會缺這段的前面)。
    package func saveCache() async {
        guard let snapshot = cacheSnapshot() else { return }
        lastCacheSaveAt = clock.now()
        cacheIsDirty = false
        await cache.save(snapshot, chatKey: chatKey)
    }

    /// 追蹤事件套用後的寫入:距離上次寫入不到 `cacheSaveInterval` 就只記下「有未寫入的內容」,
    /// 之後的事件、`flushCache()`(離開聊天時)再寫;串流中每則事件都重組、重新編碼最多 2000 則訊息會一直占主執行緒(#510)。
    package func saveCacheThrottled() async {
        if let last = lastCacheSaveAt, clock.now().timeIntervalSince(last) < Self.cacheSaveInterval {
            cacheIsDirty = true
            return
        }
        await saveCache()
    }

    /// 把節流期間累積、還沒寫入的內容寫進快取(離開聊天、進背景時呼叫)。
    package func flushCache() async {
        guard cacheIsDirty else { return }
        await saveCache()
    }

    /// 在主執行緒組出要存的內容(只做同步的整理;編碼與寫入在快取 actor)。
    package func cacheSnapshot() -> CachedConversation? {
        guard let boundSessionID, let file else { return nil }
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
        // 尾端只有工具步驟(補讀過才找到可讀訊息):多留到包含可讀訊息，否則下次開啟的快取不值得還原、又得整段補讀(#508)。
        // 只掃新納入那一段的訊息(線性),不重建畫面項目(#510)。
        var limit = CachedConversation.maxMessages
        if count > 0, !Self.hasReadableMessage(in: recent.suffix(count)) {
            while first > 0, count < CachedConversation.maxMessagesWithReadable {
                first -= 1
                let added = segments[first].count
                count += added
                limit = CachedConversation.maxMessagesWithReadable
                if Self.hasReadableMessage(in: recent[(recent.count - count)..<(recent.count - count + added)]) { break }
            }
        }
        let windowStart = first < segments.count ? segments[first].start : file.windowStart
        return CachedConversation(
            sessionID: boundSessionID, messages: Array(recent.suffix(count)), metadata: metadata, path: file.path,
            cursor: file.follow.cursor, windowStart: windowStart, limit: limit
        )
    }

    // MARK: - 可讀訊息

    /// 訊息裡有沒有會變成「可讀項目」的內容(`hasReadableMessage(in: items)` 的線性版本,不重建畫面項目,#510):
    /// 使用者文字(去掉上傳圖片路徑後非空)或圖片、Agent 文字、委派卡、skill、備註、shell 指令、檔案卡都算;
    /// 工具呼叫、結果、thinking、通知不算;sidechain 訊息不顯示所以不算。
    package static func hasReadableMessage<Messages: Sequence>(in messages: Messages) -> Bool where Messages.Element == TranscriptMessage {
        messages.contains { message in
            guard !message.isSidechain else { return false }
            var userTexts: [String] = []
            var images = 0
            for part in message.parts {
                switch part {
                case .text(let text):
                    if message.role == .user { userTexts.append(text) } else { return true }
                case .delegation, .skill, .note, .shellInput, .agentFile: return true
                case .images(let count): images += count
                default: break
                }
            }
            guard !userTexts.isEmpty || images > 0 else { return false }
            let (text, paths) = UploadedImages.extract(from: userTexts.joined(separator: "\n"))
            return !text.isEmpty || max(images, paths.count) > 0
        }
    }

    /// 快取的訊息組出的畫面有可讀訊息(或根本沒有訊息)才值得還原:尾端只有工具步驟的快取會讓開啟時看到一片空白的步驟串(#473)。
    package static func isWorthRestoring(_ cached: CachedConversation) -> Bool {
        cached.messages.isEmpty || hasReadableMessage(in: cached.messages)
    }

    // MARK: - 交出增量

    private func emitRebuild(permissionModes: TranscriptDelta.PermissionModes = .none) {
        emit(.rebuild(olderMessages + recent), permissionModes: permissionModes)
    }

    private func emit(_ timeline: TranscriptDelta.Timeline, permissionModes: TranscriptDelta.PermissionModes = .none) {
        onEvent?(.delta(TranscriptDelta(
            timeline: timeline, metadata: metadata, progress: progress, older: older, permissionModes: permissionModes)))
    }

    // MARK: - 觀察範圍的測試入口(#593)

    package func touchForTesting(_ field: ConversationModel.ObservationIgnoredField, message: TranscriptMessage) {
        switch field {
        case .olderMessages: olderMessages = [message]
        case .segments: segments = [(0, 1)]
        case .generation: generation += 1
        case .dialect: dialect = dialect == .claude ? .codex : .claude
        default: break
        }
    }
}

/// 點進聊天的步驟計時(#659):名稱固定 `chatOpen.*`,只有毫秒與成敗,不含內容;沒接計時時直接執行。
struct ChatOpenTimings: Sendable {
    let sink: OperationTimingSink?

    var isEnabled: Bool { sink != nil }

    func timed<T>(_ name: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async throws -> T {
        try await OperationTimer.measure("chatOpen.\(name)", sink: sink, body)
    }

    func note(_ name: String, milliseconds: Int = 0) {
        sink?(OperationTiming(name: "chatOpen.\(name)", milliseconds: milliseconds, at: Date()))
    }
}
