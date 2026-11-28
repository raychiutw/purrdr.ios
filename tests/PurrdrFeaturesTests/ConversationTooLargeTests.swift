import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機服務回 `transcript_too_large`(對話紀錄超過讀取上限,#729):聊天不能靜默空白,要有橫幅說明。
@MainActor
@Suite("聊天:對話紀錄太大")
struct ConversationTooLargeTests {
    typealias Source = TranscriptFollowViewTests

    @Test("對話紀錄太大:顯示說明橫幅,不是空白也不是一直重試的讀取失敗")
    func showsTooLargeBanner() async {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await connection.serveTranscript(.init(
            locate: { _ in TranscriptFile(path: Source.path, size: Source.size) },
            window: { _, _, _, _ in throw TranscriptReadError.tooLarge },
            tail: { _, _, _, _ in throw TranscriptReadError.tooLarge }))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Source.paneID,
            knownSessionID: Source.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock)

        await model.poll()

        #expect(model.banner == .tooLarge)
        #expect(model.phase == .ready)
        #expect(model.items.isEmpty)
    }
}
