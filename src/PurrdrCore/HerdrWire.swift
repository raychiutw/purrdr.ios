import Foundation

/// herdr 的位元組格式(SSH 連線方式的 wire 層,ADR-0015):herdr 單次請求「一行 NDJSON 進、第一行回應出」、
/// Agent 事件串流逐行、對話紀錄由主機腳本輸出。只有 SSH 連線方式實作它,由 `HerdrWireClient`／`TranscriptWireReader`
/// 解析成型別化的值;`HostConnection` 本身不再有 `Data` 進出的操作。
package protocol HerdrWire: Sendable {
    /// herdr 單次請求:送出一行請求(NDJSON),回傳第一行回應(不含換行)。一律有期限(#86),到了丟 `HerdrError.deadlineExceeded`;
    /// 外層取消丟 `CancellationError`,兩者都立刻返回。
    func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data

    /// Agent 事件串流:送出 `events.subscribe` 請求,逐行回傳 herdr 的回應(ack、事件、錯誤)。呼叫端不再讀時關閉。
    func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error>

    /// 對話紀錄:讀一次,回傳主機的原始輸出(格式見 `TranscriptWireReader`)。主機回報的失敗丟 `TranscriptReadError`。
    func readTranscript(_ request: TranscriptRequest) async throws -> Data

    /// 主機會不會在送出前比對 `SendExpectation`;`false` 時請求不帶比對欄位(SSH 主機)。
    func checksSendExpectations() async -> Bool
}
