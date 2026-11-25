import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Synchronization
import Testing

/// 對話紀錄的解析在背景做(#498):開啟視窗與追蹤推送的解析都不在主執行緒，結果仍依序套用。
/// 列表的列由對話時間軸增量更新(#480),不再整份重建，所以只有解析這一步在背景。
@MainActor
@Suite("對話紀錄背景解析")
struct ConversationOffMainTests {
    private final class Probe: Sendable {
        private let threads = Mutex<[Bool]>([])
        func record() { threads.withLock { $0.append(Thread.isMainThread) } }
        var onMain: [Bool] { threads.withLock { $0 } }
    }

    @Test("開啟視窗與推送新訊息時，解析不在主執行緒，訊息仍依序出現")
    func parsingRunsOffMainThread() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await TranscriptFollowViewTests.answering(connection)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection),
            paneID: TranscriptFollowViewTests.paneID, knownSessionID: TranscriptFollowViewTests.sessionID,
            cache: InMemoryConversationCache(), clock: TestClock().clock)
        let probe = Probe()
        model.onTranscriptWork = { probe.record() }
        let chat = Task { await model.run(sleep: RecordingSleeper().sleep) }
        defer { chat.cancel() }
        try await waitUntil { await connection.transcriptFollowOpenings.count == 1 }
        let shown = model.items.count
        #expect(shown > 0)

        await connection.send(.appended(TranscriptFollowViewTests.addedChunk), toFollow: 0)
        try await waitUntil { await MainActor.run { model.items.count == shown + 1 } }

        let calls = probe.onMain
        #expect(calls.count >= 2)  // 視窗解析、推送解析
        #expect(!calls.contains(true))
    }
}
