import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Codex rollout 的解析(行為規格 §4.2)。【未實測】fixture 依行為規格與 openai/codex 公開原始碼撰寫，
/// 不是從真實主機擷取(見 `Fixtures/README.md`)。
@Suite("對話紀錄解析:Codex(rollout)")
struct CodexTranscriptParserTests {
    static let lines = Fixtures.otherAgentTranscriptLines("codex/rollout.jsonl")

    static func items() -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(TranscriptFormat.codex.messages(in:)))
    }

    static func line(_ type: String, _ payload: [String: Any], timestamp: String = "2026-11-14T10:00:00.000Z") -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Agent 種類 codex 用 rollout 解析器，且標示未實測")
    func codexKindUsesRolloutParser() {
        #expect(TranscriptFormat(agentKind: "codex") == .codex)
        #expect(TranscriptFormat.codex.isVerified == false)
    }

    /// 只有 `response_item` 成為泡泡;`event_msg` 是同一輪的重複(R-I16)。developer 角色、`# AGENTS.md`、
    /// `<environment_context>` 這類 harness 訊息、`channel: analysis` 都不顯示。
    @Test("使用者訊息、工具串、agent 文字;event_msg 與 harness 訊息不顯示")
    func fixtureBecomesConversationItems() throws {
        let items = Self.items()

        try #require(items.count == 3)
        guard case .user(let user) = items[0], case .toolRun(let run) = items[1], case .agentText(let text) = items[2] else {
            Issue.record("項目種類不對:\(items)")
            return
        }
        #expect(user.text == "Export the notes to Markdown")
        #expect(user.imageCount == 1)
        #expect(run.summary.thoughts == 1)
        #expect(run.summary.failures == 1)
        // assistant 文字去掉 <oai-mem-citation>。
        #expect(text.markdown == "Exported 2 notes to `out/`.")
    }

    /// 結果沒有錯誤旗標：從文字判斷(第一個 exit code ≠ 0、`Script failed`…)。
    @Test("工具呼叫的名稱、輸入與結果;錯誤從結果文字判斷")
    func toolCallsAndResults() throws {
        guard case .toolRun(let run) = Self.items()[1] else {
            Issue.record("第二項不是工具串")
            return
        }
        let calls = run.steps.compactMap { step -> ToolCallStep? in
            if case .call(let call) = step.kind { return call }
            return nil
        }
        #expect(calls.map(\.name) == ["shell", "apply_patch", "local_shell", "web_search", "shell"])
        #expect(calls[2].input == "sh export.sh")
        #expect(calls[3].input == "sh mkdir -p before cp")
        #expect(calls.map(\.isError) == [false, false, true, false, false])
        #expect(calls[2].result?.hasPrefix("Process exited with code 1") == true)
    }

    @Test("模型與 effort 取最後的 turn_context;context 取 last_token_usage.input_tokens(cached 不重加)")
    func metadata() {
        let metadata = TranscriptFormat.codex.latestMetadata(in: Self.lines)
        #expect(metadata == TranscriptMetadata(model: "gpt-5.5", contextTokens: 18234, effort: "medium"))
    }

    @Test("id 是 codex:<timestamp>:<行雜湊>,同一行每次相同、相同 prompt 稍後重複時不同")
    func stableIDs() throws {
        let line = Self.line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "again"]]])
        let later = Self.line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "again"]]],
                              timestamp: "2026-11-14T10:05:00.000Z")
        let first = try #require(TranscriptFormat.codex.messages(in: line).first)
        #expect(first.id.hasPrefix("codex:2026-11-14T10:00:00.000Z:"))
        #expect(TranscriptFormat.codex.messages(in: line).first?.id == first.id)
        #expect(TranscriptFormat.codex.messages(in: later).first?.id != first.id)
        #expect(first.date == ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z"))
    }

    @Test("錯誤判斷:Script failed、aborted by user、Exit code N;第一個 exit code 為準")
    func errorHeuristics() {
        func isError(_ output: String) -> Bool {
            let parts = TranscriptFormat.codex.messages(in: Self.line("response_item", ["type": "function_call_output", "call_id": "c", "output": output]))
                .flatMap(\.parts)
            guard case .toolResult(_, _, let error)? = parts.first else { return false }
            return error
        }
        #expect(isError("Script failed: boom"))
        #expect(isError("  aborted by user"))
        #expect(isError("failed to spawn sh"))
        #expect(isError("Exit code: 2\nOutput:\n"))
        #expect(isError(#"{"output":"x","metadata":{"exit_code":127}}"#))
        #expect(!isError(#"{"metadata":{"exit_code":0},"output":"Exit code: 3"}"#))
        #expect(isError(#"{"output":"Exit code: 3","metadata":{"exit_code":0}}"#))
        #expect(!isError("all good"))
    }

    @Test("使用者文字：整段 permissions 區塊移除、send_user_message_question_reply 顯示其內容")
    func userTextCleaning() {
        func text(_ raw: String) -> String? {
            let parts = TranscriptFormat.codex.messages(in: Self.line("response_item", ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": raw]]])).flatMap(\.parts)
            guard case .text(let value)? = parts.first else { return nil }
            return value
        }
        #expect(text("<permissions instructions>x</permissions instructions>\nFix it") == "Fix it")
        #expect(text("<send_user_message_question_reply>Option B</send_user_message_question_reply>") == "Option B")
        #expect(text("<heartbeat>tick</heartbeat>") == nil)
    }

    @Test("reasoning 只取 summary 當 thinking;agent_message 是 sidechain 的「作者 → 收件者」")
    func reasoningAndAgentMessages() throws {
        let reasoning = TranscriptFormat.codex.messages(in: Self.line("response_item", ["type": "reasoning", "summary": [], "encrypted_content": "x"]))
        #expect(reasoning.isEmpty)
        let message = try #require(TranscriptFormat.codex.messages(in: Self.line("response_item",
            ["type": "agent_message", "author": "planner", "recipient": "worker", "content": [["type": "input_text", "text": "Run the tests"]]])).first)
        #expect(message.isSidechain)
        #expect(message.parts == [.text("planner → worker: Run the tests")])
    }

    @Test("session_meta 的 id 必須與回報的 session 相同")
    func headerMatches() {
        #expect(CodexTranscriptParser.headerMatches(Self.lines[0], expectedID: "0000c0de-0000-4000-8000-000000000001"))
        #expect(!CodexTranscriptParser.headerMatches(Self.lines[0], expectedID: "0000c0de-0000-4000-8000-000000000002"))
        #expect(!CodexTranscriptParser.headerMatches(Self.lines[1], expectedID: "0000c0de-0000-4000-8000-000000000001"))
    }
}
