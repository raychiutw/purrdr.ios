import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 返回列表的轉場期間(畫面已經在離開)不再套用新的對話紀錄:每則追加都會讓整個聊天畫面重算與重排,
/// 全部塞在 pop 動畫裡,造成開頭停滯與尾段凍結。離開中暫停套用、回來(取消返回、從子頁回來)再接上。
@MainActor
@Suite("聊天離開中:暫停套用追蹤內容")
struct ConversationLeavingTests {
    typealias W = ConversationWorkingOpenTests
    typealias R = ConversationReadableMessageTests

    private func openedModel() async throws -> (ConversationModel, FakeHostConnection, Task<Void, Never>) {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        let model = R.model(connection)
        let chat = try await R.open(model, connection)
        return (model, connection, chat)
    }

    private func append(_ connection: FakeHostConnection, index: Int, from cursor: Int) async -> Int {
        let added = W.toolPair(index)
        let end = cursor + added.reduce(0) { $0 + $1.utf8.count + 1 }
        await connection.send(.appended(TranscriptChunk(start: cursor, end: end, lines: added)), toFollow: 0)
        return end
    }

    @Test("離開中收到的追蹤內容先不套用,回來之後才接上")
    func holdsAppendsWhileLeaving() async throws {
        let (model, connection, chat) = try await openedModel()
        defer { chat.cancel() }
        let before = model.cacheSnapshot()?.cursor

        model.setLeaving(true)
        let end = await append(connection, index: 600, from: W.size)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.cacheSnapshot()?.cursor == before, "離開中不該套用新內容")

        model.setLeaving(false)
        try await waitUntil { await model.cacheSnapshot()?.cursor == end }
    }

    @Test("離開中被取消(返回完成、run 結束)不會卡住")
    func cancelWhileLeavingDoesNotHang() async throws {
        let (model, connection, chat) = try await openedModel()
        model.setLeaving(true)
        _ = await append(connection, index: 601, from: W.size)
        try await Task.sleep(for: .milliseconds(100))
        chat.cancel()
        await chat.value
    }

    @Test("沒有離開時照常即時套用")
    func appliesImmediatelyWhenNotLeaving() async throws {
        let (model, connection, chat) = try await openedModel()
        defer { chat.cancel() }
        let end = await append(connection, index: 602, from: W.size)
        try await waitUntil { await model.cacheSnapshot()?.cursor == end }
    }
}
