import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天頂列的 context 百分比與待辦進度(#307)。
@MainActor
@Suite("對話進度(context 與待辦)")
struct ConversationProgressTests {
    static let todoLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"寫測試","status":"completed","activeForm":"寫測試中"},{"content":"改實作","status":"in_progress","activeForm":"改實作中"},{"content":"收尾","status":"pending","activeForm":"收尾中"}]}}]},"uuid":"a9"}"# + "\n"

    @Test("開啟：最後一筆 usage 是 37%，標題列進度「37%」(沒有待辦時只有百分比)")
    func openShowsContextPercent() async throws {
        let setup = try ConversationModelTests.setup()
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())

        await setup.model.poll()

        #expect(setup.model.progress.contextPercent == 37)
        #expect(setup.model.header.progressText == "37%")
    }

    @Test("有 TodoWrite：副標尾端「37% · Todos 1/3」，待辦清單依序列出完成與未完成")
    func headerShowsTodos() async throws {
        let setup = try ConversationModelTests.setup(transcript: ConversationModelTests.fixture + Data(Self.todoLine.utf8))
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())

        await setup.model.poll()

        #expect(setup.model.header.progressText == "37% · Todos 1/3")
        #expect(setup.model.progress.todos.map(\.text) == ["寫測試", "改實作", "收尾"])
    }

    @Test("追蹤到新的 TodoWrite：進度更新")
    func appendedTodoWriteUpdatesProgress() async throws {
        let setup = try ConversationModelTests.setup()
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.noSuggestionScreen)
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.noSuggestionScreen)
        await setup.model.poll()

        try setup.shell.append(Data(Self.todoLine.utf8), to: ConversationModelTests.transcriptPath)
        await setup.model.poll()

        #expect(setup.model.progress.todoTotal == 3)
    }
}
