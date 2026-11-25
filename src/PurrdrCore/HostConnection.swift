import Foundation

/// 主機連線：上層功能(Agent 列表、對話閱讀、送 prompt、Pane 終端機)對一台主機能做的 herdr 操作。
///
/// 每種連線方式一個實作(SSH:`SSHHostConnection`),上層只看這個介面，不知道背後是哪種連線方式。
/// 登入 Shell 不在這裡：它只有 SSH 提供，直接用主機通道(ADR-0010)。
public protocol HostConnection: Sendable {
    /// herdr 單次請求：送出一行請求(NDJSON),回傳第一行回應(不含換行)。一律有期限(#86),到了丟 `HerdrError.deadlineExceeded`;
    /// 外層取消丟 `CancellationError`,兩者都立刻返回。
    func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data

    /// Agent 事件串流：送出 `events.subscribe` 請求，逐行回傳 herdr 的回應(ack、事件、錯誤)。呼叫端不再讀時關閉。
    func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error>

    /// 對話紀錄：讀一次，回傳主機的原始輸出(格式見 `TranscriptReader`)。主機回報的失敗丟 `TranscriptReadError`。
    func readTranscript(_ request: TranscriptRequest) async throws -> Data

    /// 追蹤對話紀錄尾端：從 `cursor` 起有新增的完整行就送 `.appended`;接不上時送 `.replaced` 並結束。
    /// 多久看一次由連線方式決定(推送的直接轉;內部輪詢的照 `pace`)。呼叫端停止讀取或 `stopFollowingTranscript(path:)` 時結束。
    func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error>

    /// 不再追蹤 `path` 的尾端(對話關閉或換了 session)。主機推送尾端的連線方式(HTTPS)據此請主機停止追蹤;
    /// 每次都向主機讀的連線方式不用做事(預設實作)。之後再讀這個路徑會重新開始追蹤。
    func stopFollowingTranscript(path: String) async

    /// Pane 終端機：以 controller 身分接上 `target`(pane id 或 terminal id)。
    func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection

    /// 關掉底層連線。下一個操作會重新連線。
    func disconnect() async

    /// 這支裝置是否配對成唯讀(寫入類操作會被拒絕)。
    func isReadOnlyDevice() async throws -> Bool

    /// 主機上 Purrdr 主機服務的版本(畫面據此提示更新，#198);沒有主機服務的連線方式(SSH)是 `nil`。
    func hostServiceVersion() async throws -> String?

    /// 主機會不會在送出前比對 `SendExpectation`(#304)。`false` 時 herdr 請求不帶比對欄位(SSH 主機、舊版主機服務)。
    func checksSendExpectations() async -> Bool

    // MARK: - 型別化操作(ADR-0015、#594;與上面的 `Data` 操作並存，呼叫端遷移在 #595)

    /// 讀主機目前的全量狀態。SSH 以 herdr 的 `session.snapshot` 實作，HTTPS 直接對應 `agents.list`。
    func readSnapshot() async throws -> HostSnapshot

    /// 送 herdr 鍵名(`enter`、`esc`、`ctrl+c`…)到 pane。`expecting` 只在主機會比對時才送出(HTTPS 0.7.0 起)；不符丟 `HostServiceError.paneChanged`。
    func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws

    /// 把文字原樣打進 pane(不含 Enter)。`expecting` 同 `sendKeys`。
    func sendText(paneID: String, text: String, expecting: SendExpectation) async throws

    /// 讀 pane 目前看得到的畫面。
    func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String

    /// 定位對話紀錄並取得大小；已做位置安全、路徑與 header 檢查(失敗丟 `TranscriptReadError`)。
    func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile

    /// 讀以 `end` 為終點的最後 `lines` 行；`maxBytes` 大於 0 時範圍不超過該 byte 數。
    func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk

    /// 開始快速偵測斷線(聊天畫面可見時;每次開始對應一次結束)。
    func beginQuickDisconnectDetection() async

    /// 結束一次 `beginQuickDisconnectDetection()`。
    func endQuickDisconnectDetection() async
}

extension HostConnection {
    public func beginQuickDisconnectDetection() async {}
    public func endQuickDisconnectDetection() async {}
}

extension HostConnection {
    /// SSH 等沒有裝置權限的連線方式一律可寫入。
    public func isReadOnlyDevice() async throws -> Bool { false }

    public func hostServiceVersion() async throws -> String? { nil }

    /// herdr 不認得比對欄位：SSH 主機的對象由送出前重讀的 snapshot 確認。
    public func checksSendExpectations() async -> Bool { false }
}

/// 型別化操作的預設實作：經既有的 `Data` 操作(herdr NDJSON 與對話紀錄腳本格式)。SSH 沿用它，
/// herdr wire 格式仍在 `HerdrClient`／`TranscriptReader`(遷移完成後才收進 SSH adapter，見 ADR-0015)；HTTPS 覆寫成直接對應主機服務訊息。
extension HostConnection {
    public func readSnapshot() async throws -> HostSnapshot {
        try await HerdrClient(connection: self).snapshot()
    }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        try await HerdrClient(connection: self).sendKeys(paneID: paneID, keys: keys, expecting: expecting)
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        try await HerdrClient(connection: self).sendText(paneID: paneID, text: text, expecting: expecting)
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        try await HerdrClient(connection: self).readPane(paneID: paneID, lines: lines, format: format)
    }

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile {
        try await TranscriptReader(connection: self).locate(location)
    }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        try await TranscriptReader(connection: self).window(path: path, endingAt: end, lines: lines, maxBytes: maxBytes > 0 ? maxBytes : nil)
    }
}

extension HostConnection {
    public func stopFollowingTranscript(path: String) async {}
}

/// 一次對話紀錄讀取。參數已由 `TranscriptReader` 驗證過安全性。
public enum TranscriptRequest: Sendable, Equatable {
    /// 任一種 agent 的對話紀錄位置與大小(通用的定位請求,位置規則帶在 `TranscriptLocation`);
    /// 位置規則要檢查 header 時多印檔案開頭。
    case locate(TranscriptLocation)
    /// 以 `end` 為終點的最後 `lines` 行;`maxBytes` 大於 0 時範圍不超過該 byte 數(只回範圍內完整的行，#356)。
    case window(path: String, end: Int, lines: Int, chunkBytes: Int, maxBytes: Int)
    /// 游標之後新增的完整行。
    case tail(path: String, from: Int, limit: Int)
    /// 從游標讀最多 `limit` bytes 的完整行，即使後面還有(即時追蹤的分段追趕，#130)。
    case catchUp(path: String, from: Int, limit: Int)
    /// 列表預覽：每個聊天對話紀錄的檔尾。
    case previews(marker: String, requests: [PreviewRequest])
    /// 呼叫 `callID` 啟動的 subagent 的 meta。
    case findSubagent(sessionFolder: String, callID: String)
    /// workflow 進度。
    case readWorkflow(sessionFolder: String, runID: String, knownChecksum: String)
    /// 父對話紀錄中指名這個委派的行。
    case delegationLines(path: String, callID: String, agentID: String, knownChecksum: String)
}
