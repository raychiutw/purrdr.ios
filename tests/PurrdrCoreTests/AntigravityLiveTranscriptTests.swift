import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Antigravity 對話紀錄對真實錄製(agy 1.5.14、`other-agents/antigravity/live-1.5.14/transcript.jsonl`,#445)的驗證(#446)。
@Suite("對話紀錄解析：Antigravity 真實錄製(1.5.14)")
struct AntigravityLiveTranscriptTests {
    static let lines = Fixtures.otherAgentTranscriptLines("antigravity/live-1.5.14/transcript.jsonl")

    static func items() -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(TranscriptDialect.antigravity.messages(in:)))
    }

    private func calls() -> [ToolCallStep] {
        Self.items().flatMap { item -> [ToolCallStep] in
            guard case .toolRun(let run) = item else { return [] }
            return run.steps.compactMap { step in
                if case .call(let call) = step.kind { return call }
                return nil
            }
        }
    }

    @Test("使用者請求、回覆與工具串都解析得出來;系統訊息不顯示")
    func conversationItems() {
        let items = Self.items()
        let users = items.compactMap { item -> String? in
            if case .user(let user) = item { return user.text }
            return nil
        }
        #expect(users == [
            "Create a new file named note.txt in the current folder containing the single line: hi. Do nothing else.",
            "Run the shell command: date -u  (just run it, then reply with the output only)",
            "Edit sample.txt: replace the word hello with hello world. Do nothing else.",
            "Use your ask_question tool to ask me one single-choice question: which color should the button be? Options: Red, Green, Blue. Do not do anything else.",
        ])
        let replies = items.compactMap { item -> String? in
            if case .agentText(let text) = item { return text.markdown }
            return nil
        }
        #expect(replies == ["Sun Nov 22 16:35:56 UTC 2026", "You selected **Green**."])
    }

    @Test("工具呼叫:write_file、run_command、read_file、edit_file、ask_question 的輸入取路徑與指令")
    func toolCalls() {
        let calls = calls()
        #expect(calls.map(\.name) == ["write_file", "run_command", "read_file", "edit_file", "ask_question"])
        #expect(calls[0].input == "/Users/demo/Projects/fixture-work/note.txt")
        #expect(calls[0].path == "/Users/demo/Projects/fixture-work/note.txt")
        #expect(calls[1].input == "date -u")
        #expect(calls[2].path == "/Users/demo/Projects/fixture-work/sample.txt")
        #expect(calls[3].path == "/Users/demo/Projects/fixture-work/sample.txt")
    }

    @Test("權限被拒的工具結果是錯誤,內容取 error 欄位(不含時間行)")
    func deniedResultIsError() {
        let calls = calls()
        #expect(calls[0].isError)
        #expect(calls[0].result?.hasPrefix("permission check failed for write_file") == true)
        #expect(calls[0].result?.contains("Created At") == false)
        #expect(!calls[1].isError)
        #expect(calls[1].result == "Command exited with code 0.\n\nCommand output:\nSun Nov 22 16:35:56 UTC 2026")
        #expect(calls[3].isError)
    }

    @Test("Header:模型與 effort 取最後一則 PLANNER_RESPONSE 的 model id;context = input + cache_read tokens")
    func metadata() {
        let metadata = TranscriptDialect.antigravity.latestMetadata(in: Self.lines)
        #expect(metadata.model == "Gemini 4 Neon")
        #expect(metadata.effort == "medium")
        #expect(metadata.contextTokens == 2279 + 8582)
    }

    @Test("model id 的 effort 字尾拆出來;換模型後取新的")
    func modelIdParsing() {
        var metadata = TranscriptMetadata()
        let line = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-11-22T16:35:01Z","model":"gemini-4-argon-high","input_tokens":10,"cache_read_tokens":5,"output_tokens":1,"content":"x"}"#
        TranscriptDialect.antigravity.updateMetadata(&metadata, with: line)
        #expect(metadata.model == "Gemini 4 Argon")
        #expect(metadata.effort == "high")
    }

    @Test("使用者切換模型的設定變更「Gemini 4 Neon (Medium)」也拆成模型與 effort")
    func settingChange() {
        var metadata = TranscriptMetadata()
        TranscriptDialect.antigravity.updateMetadata(&metadata, with: Self.lines[0])
        #expect(metadata.model == "Gemini 4 Neon")
        #expect(metadata.effort == "medium")
    }
}
