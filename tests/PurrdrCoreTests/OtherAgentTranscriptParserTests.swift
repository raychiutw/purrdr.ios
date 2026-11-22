import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Grok、Antigravity、Pi／OMP 的對話紀錄解析(行為規格 §4.3–4.5)。【未實測】fixture 依各 agent 的文件與行為規格撰寫，
/// 不是從真實主機擷取(見 `Fixtures/README.md`)。
@Suite("對話紀錄解析：Grok(ACP log)")
struct GrokTranscriptParserTests {
    static let lines = Fixtures.otherAgentTranscriptLines("grok/updates.jsonl")

    static func items() -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(TranscriptDialect.grok.messages(in:)))
    }

    @Test("Agent 種類 grok 用 ACP log 解析器")
    func grokKindUsesACPParser() {
        #expect(AgentCatalog.profile(forHerdrName: "grok").transcript == .grok)
    }

    @Test("使用者訊息、工具串、agent 文字;Grok 自己寫的 prompt(syntheticPrompt)不顯示")
    func fixtureBecomesConversationItems() throws {
        let items = Self.items()

        try #require(items.count == 3)
        guard case .user(let user) = items[0], case .toolRun(let run) = items[1], case .agentText(let text) = items[2] else {
            Issue.record("項目種類不對:\(items)")
            return
        }
        #expect(user.text == "Why does the totals test fail?")
        #expect(run.summary == ToolRunSummary(thoughts: 1, commands: 1, editedFiles: 1, readFiles: 1, failures: 1))
        #expect(text.markdown.hasPrefix("The total floored half cents."))
    }

    /// 只有 completed／failed 的 `tool_call_update` 是結果;之前的更新是進度。diff 顯示成「Edited <path>」。
    @Test("工具名取 x.ai/tool、結果只取完成或失敗的更新，diff 顯示為已編輯")
    func toolCallsAndResults() throws {
        guard case .toolRun(let run) = Self.items()[1] else {
            Issue.record("第二項不是工具串")
            return
        }
        let calls = run.steps.compactMap { step -> ToolCallStep? in
            if case .call(let call) = step.kind { return call }
            return nil
        }
        #expect(calls.map(\.name) == ["read_file", "search_replace", "run_terminal_command"])
        #expect(calls.map(\.input) == ["src/totals.test.ts", "src/totals.ts", "npm test"])
        #expect(calls.map(\.result) == ["expect(total([4.005, 8])).toBe(12.01)", "Edited src/totals.ts", "1 failing: totals rounds half cents"])
        #expect(calls.map(\.isError) == [false, false, true])
    }

    @Test("id 取 eventId、時間取 agentTimestampMs,沒有時退用行雜湊與 timestamp 秒數")
    func idsAndDates() throws {
        let messages = Self.lines.flatMap(TranscriptDialect.grok.messages(in:))
        let first = try #require(messages.first)
        #expect(first.id == "acp:ev-1")
        #expect(first.date == Date(timeIntervalSince1970: 1_792_073_586.001))
        let last = try #require(messages.last)
        #expect(last.id.hasPrefix("line-"))
        #expect(last.date == Date(timeIntervalSince1970: 1_792_073_592))
        #expect(TranscriptDialect.grok.messages(in: Self.lines[11]).map(\.id) == [last.id])
    }

    @Test("Header:模型取任何 update 的 _meta.modelId;沒有 context")
    func metadata() {
        let metadata = TranscriptDialect.grok.latestMetadata(in: Self.lines)
        #expect(metadata == TranscriptMetadata(model: "grok-5-fast"))
    }
}

/// 工具串裡的呼叫(依序)。
func toolCalls(in items: [ConversationItem]) -> [ToolCallStep] {
    items.flatMap { item -> [ToolCallStep] in
        guard case .toolRun(let run) = item else { return [] }
        return run.steps.compactMap { step in
            if case .call(let call) = step.kind { return call }
            return nil
        }
    }
}

@Suite("對話紀錄解析：Antigravity(agy steps)")
struct AntigravityTranscriptParserTests {
    static let lines = Fixtures.otherAgentTranscriptLines("antigravity/transcript.jsonl")

    static func items(_ lines: [String] = lines) -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(TranscriptDialect.antigravity.messages(in:)))
    }

    @Test("Agent 種類 agy 用 agy steps 解析器")
    func agyKindUsesStepsParser() {
        #expect(AgentCatalog.profile(forHerdrName: "agy").transcript == .antigravity)
    }

    @Test("只有 USER_EXPLICIT 是人打的(取 USER_REQUEST 內文);PLANNER_RESPONSE 是 agent;其他 step 不顯示")
    func fixtureBecomesConversationItems() throws {
        let items = Self.items()

        try #require(items.count == 5)
        guard case .user(let user) = items[0], case .toolRun(let thinking) = items[1], case .agentText(let first) = items[2],
              case .toolRun(let tools) = items[3], case .agentText(let last) = items[4] else {
            Issue.record("項目種類不對:\(items)")
            return
        }
        #expect(user.text == "Add a dark mode toggle to settings")
        #expect(thinking.summary == ToolRunSummary(thoughts: 1))
        #expect(first.markdown == "I'll look at the settings screen first.")
        #expect(tools.summary == ToolRunSummary(commands: 1, readFiles: 1))
        #expect(last.markdown.hasPrefix("Added a **Dark mode** toggle"))
    }

    /// 參數值是 JSON 字串、各自解析;去掉 toolAction;鍵改名(AbsolutePath → file_path、CommandLine → command…)。
    /// GENERIC 的輸出去掉開頭的 Created At／Completed At,CRLF 換成 LF。
    @Test("工具參數解析與改名;GENERIC 輸出去掉時間行並正規化換行")
    func toolCallsAndResults() {
        let calls = toolCalls(in: Self.items())

        #expect(calls.map(\.name) == ["view_file", "run_command"])
        #expect(calls.map(\.input) == ["/home/demo/notes/Sources/SettingsView.swift", "swift build"])
        #expect(calls.first?.path == "/home/demo/notes/Sources/SettingsView.swift")
        #expect(calls.map(\.result) == ["struct SettingsView: View {\n    var body: some View { Form {} }\n}", "Build complete! (21.4s)"])
    }

    /// R-I17:輸出配給**前一個 step** 的呼叫，不依順序——一個呼叫被中斷後，依順序配對會讓之後每個輸出都配錯。
    @Test("GENERIC 輸出配給前一個 step 的呼叫;被中斷的呼叫沒有結果")
    func outputPairsWithPreviousStep() {
        let lines = [
            #"{"step_index":10,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-10-12T09:00:00Z","content":"","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"sleep 100\""}}]}"#,
            #"{"step_index":11,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-10-12T09:00:05Z","content":"","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"ls\""}}]}"#,
            #"{"step_index":12,"source":"SYSTEM","type":"GENERIC","created_at":"2026-10-12T09:00:06Z","content":"README.md"}"#,
        ]
        let calls = toolCalls(in: Self.items(lines))

        #expect(calls.map(\.input) == ["sleep 100", "ls"])
        #expect(calls.map(\.result) == [nil, "README.md"])
    }

    @Test("id 是 agy:<created_at>:<step_index>,時間取 created_at")
    func idsAndDates() throws {
        let first = try #require(TranscriptDialect.antigravity.messages(in: Self.lines[0]).first)
        #expect(first.id == "agy:2026-10-12T08:00:00Z:0")
        #expect(first.date == Date(timeIntervalSince1970: 1_791_792_000))
    }

    @Test("Header:模型取 USER_INPUT 的 Model Selection 切換;context = input_tokens + cache_read_tokens")
    func metadata() {
        let metadata = TranscriptDialect.antigravity.latestMetadata(in: Self.lines)
        #expect(metadata == TranscriptMetadata(model: "Gemini 3.5 Flash", contextTokens: 11200))
    }
}

@Suite("對話紀錄解析:Pi／OMP(journal)")
struct PiJournalParserTests {
    static let lines = Fixtures.otherAgentTranscriptLines("pi/session.jsonl")

    static func items() -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(TranscriptDialect.piJournal.messages(in:)))
    }

    @Test("Agent 種類 pi 與 omp 共用 journal 解析器")
    func piAndOMPShareJournalParser() {
        #expect(AgentCatalog.profile(forHerdrName: "pi").transcript == .piJournal)
        #expect(AgentCatalog.profile(forHerdrName: "omp").transcript == .piJournal)
        #expect(AgentCatalog.profile(forHerdrName: "opencode").transcript == nil)
    }

    /// 依檔案順序讀(不重建分支樹);system 訊息與 header、模型／思考層級變更不產生內容。
    @Test("使用者、工具串、agent 文字;壓縮、分支摘要、重置成為系統註記")
    func fixtureBecomesConversationItems() throws {
        let items = Self.items()

        try #require(items.count == 8)
        guard case .user(let first) = items[0], case .toolRun(let run) = items[1], case .agentText(let answer) = items[2],
              case .note(let compacted) = items[3], case .note(let branch) = items[4], case .note(let reset) = items[5],
              case .user(let second) = items[6], case .agentText(let aborted) = items[7] else {
            Issue.record("項目種類不對:\(items)")
            return
        }
        #expect(first.text == "Total the March receipts")
        #expect(run.summary == ToolRunSummary(thoughts: 1, commands: 1, readFiles: 1, failures: 1))
        #expect(answer.markdown == "March total is **$412.30**.")
        #expect(compacted.text == "Context compacted")
        #expect(branch.text == "Branch summary: Tried rounding per line first.")
        #expect(reset.text == "Context reset")
        #expect(second.text == "Now April")
        #expect(second.imageCount == 1)
        #expect(aborted.markdown == "Starting on April")
    }

    @Test("工具呼叫與結果依 toolCallId 配對，錯誤旗標照記錄;redacted thinking 不顯示")
    func toolCallsAndResults() throws {
        let calls = toolCalls(in: Self.items())
        #expect(calls.map(\.name) == ["read", "bash"])
        #expect(calls.map(\.input) == ["src/totals.ts", "npm test"])
        #expect(calls.map(\.result) == ["export function total(items) { return 0 }", "1 failing"])
        #expect(calls.map(\.isError) == [false, true])
    }

    @Test("id 是 omp:<entry id>;時間取 message.timestamp(毫秒),沒有時取 entry 的 ISO 時間")
    func idsAndDates() throws {
        let user = try #require(TranscriptDialect.piJournal.messages(in: Self.lines[4]).first)
        #expect(user.id == "omp:9a000004")
        #expect(user.date == Date(timeIntervalSince1970: 1_792_054_802))
        let note = try #require(TranscriptDialect.piJournal.messages(in: Self.lines[12]).first)
        #expect(note.id == "omp:9a00000c")
        #expect(note.date == Date(timeIntervalSince1970: 1_791_969_090))
    }

    /// R-I18:中斷的輪次 usage 是 0,不算 context;模型與 effort 分別取最後的值。
    @Test("Header:模型取 model_change／assistant、effort 取 thinking_level_change、中斷輪次不算 context")
    func metadata() {
        let metadata = TranscriptDialect.piJournal.latestMetadata(in: Self.lines)
        #expect(metadata == TranscriptMetadata(model: "gpt-5.6", contextTokens: 2800, effort: "high"))
    }

    /// 出錯的輪次 usage 可能只有部分數字，同樣不算(stopReason 為 aborted／error 一律不看 usage)。
    @Test("Header:出錯輪次的 usage 不更新 context")
    func erroredTurnUsageIsIgnored() {
        let lines = Array(Self.lines[0...9]) + [
            #"{"type":"message","id":"e1","timestamp":"2026-10-14T09:13:00.000Z","message":{"role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input":7,"cacheRead":0,"cacheWrite":0},"stopReason":"error","errorMessage":"overloaded"}}"#,
        ]
        #expect(TranscriptDialect.piJournal.latestMetadata(in: lines).contextTokens == 2800)
    }

    @Test("Header:contextSnapshot.promptTokens 優先;model_change 的 model 帶 provider 前綴，顯示時去掉")
    func contextSnapshotAndProviderPrefix() {
        let lines = [
            #"{"type":"model_change","id":"m1","timestamp":"2026-10-14T09:00:00.000Z","model":"openai/gpt-5.6"}"#,
            #"{"type":"message","id":"a1","timestamp":"2026-10-14T09:00:01.000Z","message":{"role":"assistant","content":[],"usage":{"input":10,"cacheRead":20,"cacheWrite":30},"contextSnapshot":{"promptTokens":4321},"stopReason":"stop"}}"#,
        ]
        let metadata = TranscriptDialect.piJournal.latestMetadata(in: lines)
        #expect(metadata.model == "openai/gpt-5.6")
        #expect(metadata.model.map(TranscriptMetadata.displayName(ofModel:)) == "gpt-5.6")
        #expect(metadata.contextTokens == 4321)
    }
}
