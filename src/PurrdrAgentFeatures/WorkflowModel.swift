import Foundation
import Observation
import PurrdrCore

/// 一個 workflow run 的進度(行為規格 F10「Workflow 卡/畫面」、R-W03)。卡片與畫面共用同一個實例
/// (`ConversationModel.workflowModel(for:)`),所以每個 run 同時只有一個讀取在途。
///
/// - run 檔只在結束時寫入，所以執行中讀 journal;以 checksum 比對，沒變不傳內容。
/// - 讀到寫一半的 run 檔：保留上次成功的解析**與舊 checksum**(下次會再讀)。
/// - 結束條件:run 檔狀態不是執行中;或對話紀錄說結束 → 再讀一次就停止;或仍說執行中但 30 分鐘沒變化 →
///   停止追蹤並標示「不再追蹤」。
@MainActor
@Observable
public final class WorkflowModel {
    public private(set) var run: WorkflowRun?
    /// 還在追蹤(會繼續輪詢)。
    public private(set) var isTracking = true
    /// 因為 30 分鐘沒變化而停止追蹤(畫面標示「不再追蹤 · 重新載入可再檢查」)。
    public private(set) var stoppedTracking = false
    /// 讀不了(HTTPS 主機的主機服務太舊)時的說明;有值時不再追蹤。
    public private(set) var unavailableReason: String?
    public private(set) var card: WorkflowCard
    package private(set) var checksum: String?

    public let sessionFolder: String
    private let transcripts: TranscriptReader
    private let clock: ConversationClock
    private var lastChange: Date?
    private var inFlight = false
    /// 對話紀錄說結束了：再讀一次就停止。
    private var finalReadPending = false

    package static let staleAfter: TimeInterval = 30 * 60

    public init(transcripts: TranscriptReader, sessionFolder: String, card: WorkflowCard, clock: ConversationClock = ConversationClock()) {
        self.transcripts = transcripts
        self.sessionFolder = sessionFolder
        self.card = card
        self.clock = clock
        if card.status != .running { finalReadPending = true }
    }

    /// 對話紀錄裡的卡片更新了(例如拿到 run id、或通知說結束)。
    public func update(card: WorkflowCard) {
        let wasRunning = self.card.status == .running
        self.card = card
        if wasRunning, card.status != .running { finalReadPending = true }
    }

    /// 執行中每 3 秒讀一次，直到不再追蹤或所在的 task 被取消。
    public func track(sleep: @escaping Sleep = Sleeping.task) async {
        while !Task.isCancelled, isTracking {
            await poll()
            guard isTracking else { return }
            do { try await sleep(.seconds(3)) } catch { return }
        }
    }

    public func poll() async {
        guard isTracking, !inFlight, let runID = card.runID else { return }
        inFlight = true
        defer { inFlight = false }
        let finalRead = finalReadPending
        let now = clock.now()
        do {
            switch try await transcripts.readWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: checksum) {
            case .unchanged:
                break
            case .run(let newChecksum, let data):
                // 寫一半的 JSON:保留上次的解析與舊 checksum,下次會再讀。
                if let parsed = WorkflowRun.parse(runFile: data) {
                    run = parsed
                    checksum = newChecksum
                    lastChange = now
                }
            case .journal(let newChecksum, let lines):
                run = WorkflowRun.parse(journal: lines)
                checksum = newChecksum
                lastChange = now
            }
        } catch HostServiceError.hostServiceUpdateRequired(let feature, let installedVersion) {
            unavailableReason = HostErrorText.hostServiceMessage(.hostServiceUpdateRequired(feature, installedVersion: installedVersion))
            isTracking = false
            return
        } catch {
            // 還沒有檔案或讀取失敗：下次再試。
        }
        if lastChange == nil { lastChange = now }
        if let run, !run.isRunning {
            isTracking = false
        } else if finalRead {
            isTracking = false
        } else if let lastChange, now.timeIntervalSince(lastChange) > Self.staleAfter {
            isTracking = false
            stoppedTracking = true
        }
    }
}
