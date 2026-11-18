import Foundation
import Observation
import PurrdrCore

/// Subagent 畫面(唯讀)的 model(行為規格 F10「Subagent 畫面」)。
///
/// - 依呼叫 id 在 meta 中找檔案，**絕不用最新檔**(`TranscriptReader.locateSubagent`,R-W02);執行中找不到每 2 秒再找。
/// - 找到後以視窗(300 行)開啟，之後等主機連線的追蹤事件(#165,不自己定時讀尾端);結束後再讀一次就停止。
/// - 結束偵測：執行中每 3 秒在父對話紀錄找指名此呼叫／agent 的行，用和卡片相同的規則判斷(R-W04:父聊天被蓋住時
///   停止輪詢，卡片學不到結束)。
/// - 內容如主對話，但 subagent 的行都是 sidechain,一律顯示。
@MainActor
@Observable
public final class SubagentModel {
    public enum Phase: Equatable {
        /// 執行中、還找不到檔案。
        case starting
        /// 已結束卻找不到檔案(例如在別台主機跑的)。
        case notOnHost
        case ready
    }

    public private(set) var phase: Phase = .starting
    public private(set) var items: [ConversationItem] = []
    public private(set) var status: DelegationStatus
    public let title: String
    public let subtitle: String?

    private enum Source {
        /// 從父對話紀錄的呼叫找(subagent 卡)。
        case call(parentTranscript: String, callID: String, agentID: String?)
        /// 已知路徑(workflow 裡的 agent)。
        case path(String)
    }

    private let transcripts: TranscriptReader
    private let source: Source
    private let openLines: Int
    /// 對話紀錄的路徑與即時追蹤的游標(`TranscriptFollow`:追上之後分段接著讀，重新可見時落後太多讀新視窗)。
    private var file: (path: String, follow: TranscriptFollow)?
    private var messages: [TranscriptMessage] = []
    private var endChecksum: String?
    /// 結束後做過最後一次補讀。
    private var finishedReading = false
    /// 追蹤中(#165);結束時停止。
    @ObservationIgnored private var following: Task<Bool, Never>?

    /// Subagent 卡的畫面。卡片沒有呼叫 id 時不該建立(箭頭停用)。
    public init(transcripts: TranscriptReader, parentTranscript: String, card: SubagentCard, openLines: Int = 300) {
        self.transcripts = transcripts
        source = .call(parentTranscript: parentTranscript, callID: card.callID ?? "", agentID: card.agentID)
        status = card.status
        title = card.title
        subtitle = DelegationText.subtitle(of: card)
        self.openLines = openLines
    }

    /// Workflow 裡 agent 的畫面：路徑由 run id 與 agent id 組出。
    public init(transcripts: TranscriptReader, transcriptPath: String, title: String, subtitle: String?, status: DelegationStatus, openLines: Int = 300) {
        self.transcripts = transcripts
        source = .path(transcriptPath)
        self.status = status
        self.title = title
        self.subtitle = subtitle
        self.openLines = openLines
    }

    /// 畫面變成可見(`run()` 一開始):當作重新開啟。離開期間落後太多就讀新視窗，不逐段重播積壓(R-B08)。
    public func reopen() {
        file?.follow.reopen()
    }

    /// 畫面可見時執行，直到所在的 task 被取消。還沒找到檔案(或追蹤出錯)時每 2 秒讀一次;追上之後等追蹤事件，
    /// 結束時停止追蹤並補讀最後一次。
    public func run(sleep: @escaping Sleep = Sleeping.task) async {
        reopen()
        let pace = TranscriptFollowPace(interval: .seconds(2), sleep: sleep)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var isReopened = false
                while !Task.isCancelled {
                    if !isReopened {
                        await self.poll()
                        if await MainActor.run(body: { self.finishedReading }) { return }
                    }
                    isReopened = await self.followWhileRunning(pace: pace)
                    let isRunning = await MainActor.run { self.status == .running }
                    if isReopened || !isRunning { continue }
                    do { try await sleep(.seconds(2)) } catch { return }
                }
            }
            group.addTask {
                while !Task.isCancelled, await MainActor.run(body: { self.status == .running }) {
                    do { try await sleep(.seconds(3)) } catch { return }
                    await self.checkEnd()
                }
            }
        }
    }

    /// 一次讀取：還沒找到檔案就找;找到後從游標追蹤。
    public func poll() async {
        let ended = status != .running
        do {
            if let file {
                // 已追上：落後多少都從游標分段接著讀，不改讀新視窗取代已顯示的訊息(#130);重新可見時落後太多讀新視窗。
                let read = try await transcripts.follow(path: file.path, file.follow)
                switch read.tail {
                case .unchanged:
                    self.file?.follow = read.next
                case .appended(let chunk):
                    self.file?.follow = read.next
                    append(chunk)
                case .tooFarBehind, .shrank:
                    try await open(path: file.path)
                }
            } else {
                let path: String
                switch source {
                case .call(let parent, let callID, _):
                    path = try await transcripts.locateSubagent(sessionFolder: ClaudeTranscript.sessionFolder(ofTranscript: parent), callID: callID)
                case .path(let known):
                    path = known
                }
                try await open(path: path)
            }
            phase = .ready
        } catch TranscriptReadError.absent {
            if file == nil { phase = ended ? .notOnHost : .starting }
        } catch {
            if file == nil, ended { phase = .notOnHost }
        }
        if ended { finishedReading = true }
    }

    /// 已追上且還在執行時追蹤，直到 subagent 結束(`checkEnd` 停止追蹤)、接不上或追蹤結束。
    /// 回傳是否因接不上而重讀了視窗(呼叫端直接從新游標再追蹤)。
    private func followWhileRunning(pace: TranscriptFollowPace) async -> Bool {
        guard status == .running, let file, file.follow.isLive else { return false }
        let task = Task { await self.applyUpdates(path: file.path, from: file.follow.cursor, pace: pace) }
        following = task
        defer { following = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func applyUpdates(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> Bool {
        do {
            for try await event in await transcripts.followTranscript(path: path, from: cursor, pace: pace) {
                switch event {
                case .appended(let chunk):
                    file?.follow = TranscriptFollow(cursor: chunk.end, isLive: true)
                    append(chunk)
                case .replaced:
                    try await open(path: path)
                    return true
                }
            }
        } catch {
            // 回到 `run` 輪詢讀一次再追蹤。
        }
        return false
    }

    private func append(_ chunk: TranscriptChunk) {
        let known = Set(messages.map(\.id))
        messages += chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)).filter { !known.contains($0.id) }
        rebuild()
    }

    private func open(path: String) async throws {
        let size = try await transcripts.size(path: path)
        let chunk = try await transcripts.window(path: path, endingAt: size, lines: openLines)
        file = (path, TranscriptFollow(cursor: chunk.end, isLive: true))
        var seen = Set<String>()
        messages = chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)).filter { seen.insert($0.id).inserted }
        rebuild()
    }

    /// 在父對話紀錄找指名此呼叫／agent 的行，用和卡片相同的規則判斷狀態;內容沒變時主機只回 checksum。
    public func checkEnd() async {
        guard status == .running, case .call(let parent, let callID, let agentID) = source, !callID.isEmpty else { return }
        guard let result = try? await transcripts.delegationLines(path: parent, callID: callID, agentID: agentID, knownChecksum: endChecksum) else { return }
        endChecksum = result.checksum
        guard let lines = result.lines else { return }
        let items = Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        for case .subagent(let card) in items where card.callID == callID {
            status = card.status
        }
        if status != .running { following?.cancel() }
    }

    private func rebuild() {
        items = Conversation.items(from: messages, showSidechain: true)
    }
}
