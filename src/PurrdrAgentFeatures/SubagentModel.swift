import Foundation
import Observation
import PurrdrCore

/// Subagent 畫面(唯讀)的 model(行為規格 F10「Subagent 畫面」)。
///
/// - 依呼叫 id 在 meta 中找檔案，**絕不用最新檔**(`TranscriptReader.locateSubagent`,R-W02);執行中找不到每 2 秒再找。
/// - 找到後以視窗(300 行)開啟，之後從游標追蹤;結束後再讀一次就停止。
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
    private var file: (path: String, cursor: Int)?
    private var messages: [TranscriptMessage] = []
    private var endChecksum: String?
    /// 結束後做過最後一次補讀。
    private var finishedReading = false

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

    /// 畫面可見時執行，直到所在的 task 被取消。
    public func run(sleep: @escaping Sleep = Sleeping.task) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await self.poll()
                    if await MainActor.run(body: { self.finishedReading }) { return }
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
                // 開著的畫面：落後多少都從游標分段接著讀，不改讀新視窗取代已顯示的訊息(#130)。
                switch try await transcripts.catchUp(path: file.path, from: file.cursor) {
                case .unchanged:
                    break
                case .appended(let chunk):
                    self.file?.cursor = chunk.end
                    let known = Set(messages.map(\.id))
                    messages += chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)).filter { !known.contains($0.id) }
                    rebuild()
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

    private func open(path: String) async throws {
        let size = try await transcripts.size(path: path)
        let chunk = try await transcripts.window(path: path, endingAt: size, lines: openLines)
        file = (path, chunk.end)
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
    }

    private func rebuild() {
        items = Conversation.items(from: messages, showSidechain: true)
    }
}
