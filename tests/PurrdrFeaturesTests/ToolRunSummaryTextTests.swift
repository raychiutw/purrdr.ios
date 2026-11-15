import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 工具串收合時的一行摘要(行為規格 F5.8):大寫開頭、「 · 」連接;subagent 不計入。
@Suite("工具串摘要文字")
struct ToolRunSummaryTextTests {
    @Test("依種類組成一行，單複數正確，失敗放最後")
    func summaryText() {
        #expect(ToolRunSummary(thoughts: 2, commands: 3, editedFiles: 1, failures: 1).text == "Thought 2 times · Ran 3 commands · Edited 1 file · 1 failed")
        #expect(ToolRunSummary(readFiles: 1, searches: 1, fetches: 2, updatedTodos: true, questions: 1, otherTools: 2).text ==
            "Read 1 file · Searched 1 time · Fetched 2 pages · Updated todos · Asked 1 question · Called 2 tools")
    }

    @Test("沒有可計的工具時退回「Used tools」")
    func emptySummary() {
        #expect(ToolRunSummary().text == "Used tools")
    }
}
