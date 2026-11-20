import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 工具串收合時的一行摘要(#271,原型 purrdr-screens 定案版:「✓ 已修改 2 個檔案 · 3 個步驟」):
/// 改了檔案時先列檔案數，再列步驟數;失敗放最後。subagent 不計入。
@Suite("工具串摘要文字")
struct ToolRunSummaryTextTests {
    @Test("改了檔案：「Edited N files · N steps」,單複數正確")
    func editedFilesAndSteps() {
        #expect(ToolRunSummary(commands: 1, editedFiles: 2).text(steps: 3) == "Edited 2 files · 3 steps")
        #expect(ToolRunSummary(editedFiles: 1).text(steps: 1) == "Edited 1 file · 1 step")
    }

    @Test("沒改檔案只列步驟數;失敗放最後")
    func stepsOnlyAndFailures() {
        #expect(ToolRunSummary(commands: 2, readFiles: 1).text(steps: 3) == "3 steps")
        #expect(ToolRunSummary(commands: 3, editedFiles: 1, failures: 1).text(steps: 4) == "Edited 1 file · 4 steps · 1 failed")
    }

    @Test("沒有步驟時退回「Used tools」")
    func emptySummary() {
        #expect(ToolRunSummary().text(steps: 0) == "Used tools")
    }
}
