import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 重新載入時畫面上的訊息保留到新內容回來(#329):主機回應慢時聊天不能先變成空白。
@MainActor
@Suite("重新載入保留畫面上的訊息")
struct ConversationReloadKeepsContentTests {
    static func makeModel(_ connection: FakeHostConnection) async -> ConversationModel {
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await TranscriptFollowViewTests.answering(connection)
        return ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection),
            paneID: TranscriptFollowViewTests.paneID, knownSessionID: TranscriptFollowViewTests.sessionID,
            cache: InMemoryConversationCache(), clock: TestClock().clock)
    }

    @Test("重新載入：讀取進行中仍顯示舊訊息，並標示更新中；讀完才換上新內容")
    func keepsItemsWhileReloading() async throws {
        let connection = FakeHostConnection()
        let model = await Self.makeModel(connection)
        await model.poll()
        let shown = model.items.count
        #expect(shown > 0)
        #expect(!model.isRefreshing)

        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.holdTranscripts()
        let reloading = Task { await model.reload() }
        try await waitUntil { await MainActor.run { model.isRefreshing } }

        #expect(model.items.count == shown, "讀取中不清空畫面")

        await connection.releaseTranscripts()
        await reloading.value
        #expect(model.items.count == shown)
        #expect(!model.isRefreshing)
    }

    @Test("重新載入失敗：舊訊息仍在，顯示讀取失敗橫幅")
    func keepsItemsWhenReloadFails() async throws {
        let connection = FakeHostConnection()
        let model = await Self.makeModel(connection)
        await model.poll()
        let shown = model.items.count

        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.answerTranscripts { _ in throw FakeHostConnectionError.unsupported }
        await model.reload()

        #expect(model.items.count == shown)
        #expect(model.banner != nil)
        #expect(!model.isRefreshing)
    }
}
