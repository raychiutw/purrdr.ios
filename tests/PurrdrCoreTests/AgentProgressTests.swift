import Foundation
import PurrdrCore
import Testing

/// 列表與聊天頂列的 context 百分比與待辦進度(#307):由對話紀錄推得，SSH 與 HTTPS 共用。
@Suite("Agent 進度(context 與待辦)")
struct AgentProgressTests {
    static func claudeAssistant(model: String = "claude-opus-4-7", input: Int, cacheRead: Int = 0, cacheCreation: Int = 0) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation)}},"uuid":"a1"}"#
    }

    static func todoWrite(_ items: [(String, String)]) -> String {
        let todos = items.map { #"{"content":"\#($0.0)","status":"\#($0.1)","activeForm":"\#($0.0)中"}"# }.joined(separator: ",")
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[\#(todos)]}}]},"uuid":"a2"}"#
    }

    @Test("Claude:context 是最後一筆 usage 的 token 數佔 200k 的百分比")
    func claudeContextPercent() {
        let progress = AgentProgress.latest(in: [Self.claudeAssistant(input: 10, cacheRead: 100_000, cacheCreation: 40_000)], dialect: .claude)
        #expect(progress.contextPercent == 70)
        #expect(progress.contextLevel == .warning)
    }

    @Test("Claude:模型帶 [1m] 時上限是 1M")
    func claudeOneMillionWindow() {
        let progress = AgentProgress.latest(in: [Self.claudeAssistant(model: "claude-opus-4-7[1m]", input: 100_000)], dialect: .claude)
        #expect(progress.contextPercent == 10)
        #expect(progress.contextLevel == .normal)
    }

    @Test("context 的已用 token 數與上限(用量 sheet 的「21 萬／100 萬」)")
    func contextTokenCounts() {
        let standard = AgentProgress.latest(in: [Self.claudeAssistant(input: 10, cacheRead: 100_000, cacheCreation: 40_000)], dialect: .claude)
        #expect(standard.contextTokens == 140_010)
        #expect(standard.contextLimit == 200_000)
        let million = AgentProgress.latest(in: [Self.claudeAssistant(model: "claude-opus-4-7[1m]", input: 100_000)], dialect: .claude)
        #expect(million.contextTokens == 100_000)
        #expect(million.contextLimit == 1_000_000)
        #expect(AgentProgress().contextTokens == nil)
        #expect(AgentProgress().contextLimit == nil)
    }

    static func sidechain(_ line: String) -> String {
        line.replacingOccurrences(of: #""type":"assistant""#, with: #""isSidechain":true,"type":"assistant""#)
    }

    @Test("Claude:超過 200k 判定是 1M 視窗(不會顯示 100%)")
    func claudeOverTwoHundredKIsOneMillion() {
        let progress = AgentProgress.latest(in: [Self.claudeAssistant(input: 10, cacheRead: 300_000, cacheCreation: 0)], dialect: .claude)
        #expect(progress.contextPercent == 30)
    }

    @Test("Claude:剛好 200k 仍是 200k 視窗")
    func claudeExactlyTwoHundredK() {
        let progress = AgentProgress.latest(in: [Self.claudeAssistant(input: 0, cacheRead: 200_000)], dialect: .claude)
        #expect(progress.contextPercent == 100)
    }

    @Test("Claude:判定為 1M 後，之後降到 200k 以下(壓縮)仍以 1M 計")
    func claudeOneMillionIsSticky() {
        let progress = AgentProgress.latest(in: [
            Self.claudeAssistant(input: 0, cacheRead: 250_000),
            Self.claudeAssistant(input: 0, cacheRead: 100_000),
        ], dialect: .claude)
        #expect(progress.contextPercent == 10)
    }

    @Test("Claude:/model 註記帶 [1m] 時上限是 1M")
    func claudeModelCommandOneMillion() {
        let note = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to Opus 4.7 (claude-opus-4-7[1m]) for this session only</local-command-stdout>"},"uuid":"u1"}"#
        let progress = AgentProgress.latest(in: [Self.claudeAssistant(input: 0, cacheRead: 100_000), note], dialect: .claude)
        #expect(progress.contextPercent == 10)
    }

    @Test("Claude:sidechain(子 Agent)的用量不蓋掉主對話")
    func claudeIgnoresSidechain() {
        let progress = AgentProgress.latest(in: [
            Self.claudeAssistant(input: 0, cacheRead: 100_000),
            Self.sidechain(Self.claudeAssistant(model: "claude-haiku-4-5", input: 0, cacheRead: 20_000)),
        ], dialect: .claude)
        #expect(progress.contextPercent == 50)
    }

    @Test("Claude:sidechain 的 TodoWrite 不蓋掉主對話的待辦")
    func claudeIgnoresSidechainTodos() {
        let progress = AgentProgress.latest(in: [
            Self.todoWrite([("主", "pending")]),
            Self.sidechain(Self.todoWrite([("子", "completed")])),
        ], dialect: .claude)
        #expect(progress.todos.map(\.text) == ["主"])
    }

    @Test("Header 中繼資料也排除 sidechain")
    func metadataIgnoresSidechain() {
        let metadata = TranscriptMetadata.latest(in: [
            Self.claudeAssistant(input: 0, cacheRead: 100_000),
            Self.sidechain(Self.claudeAssistant(model: "claude-haiku-4-5", input: 0, cacheRead: 20_000)),
        ])
        #expect(metadata.contextTokens == 100_000)
        #expect(metadata.model == "claude-opus-4-7")
    }

    @Test("context 的警示門檻：70% 起橙、85% 起紅、最多 100")
    func contextLevels() {
        #expect(AgentProgress(contextPercent: 69).contextLevel == .normal)
        #expect(AgentProgress(contextPercent: 70).contextLevel == .warning)
        #expect(AgentProgress(contextPercent: 85).contextLevel == .critical)
        let over = AgentProgress.latest(in: [Self.claudeAssistant(input: 1_200_000)], dialect: .claude)
        #expect(over.contextPercent == 100)
    }

    @Test("Claude:待辦取最後一次 TodoWrite，完成數與總數")
    func claudeTodos() {
        let lines = [
            Self.todoWrite([("A", "pending")]),
            Self.todoWrite([("A", "completed"), ("B", "in_progress"), ("C", "pending")]),
        ]
        let progress = AgentProgress.latest(in: lines, dialect: .claude)
        #expect(progress.todoDone == 1)
        #expect(progress.todoTotal == 3)
        #expect(progress.todos.map(\.status) == [.completed, .inProgress, .pending])
        #expect(progress.todos.map(\.text) == ["A", "B", "C"])
    }

    @Test("Codex:update_plan 的 plan 是待辦，context 用 model_context_window")
    func codexPlanAndContext() {
        let plan = #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","call_id":"c1","arguments":"{\"plan\":[{\"step\":\"讀碼\",\"status\":\"completed\"},{\"step\":\"改碼\",\"status\":\"in_progress\"}]}"}}"#
        let tokens = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":136000},"model_context_window":272000}}}"#
        let progress = AgentProgress.latest(in: [plan, tokens], dialect: .codex)
        #expect(progress.todoTotal == 2)
        #expect(progress.todoDone == 1)
        #expect(progress.todos.map(\.text) == ["讀碼", "改碼"])
        #expect(progress.contextPercent == 50)
    }

    @Test("沒有 usage 也沒有待辦：全部是空的，不顯示")
    func emptyWhenNothingKnown() {
        let progress = AgentProgress.latest(in: [#"{"type":"user","message":{"role":"user","content":"hi"}}"#], dialect: .claude)
        #expect(progress.contextPercent == nil)
        #expect(progress.todos.isEmpty)
        #expect(progress.isEmpty)
    }

    @Test("合併：較新的讀取沒帶待辦時沿用舊的，有就覆蓋")
    func mergingKeepsOlderValues() {
        let older = AgentProgress.latest(in: [Self.todoWrite([("A", "pending")]), Self.claudeAssistant(input: 20_000)], dialect: .claude)
        let newer = AgentProgress.latest(in: [Self.claudeAssistant(input: 100_000)], dialect: .claude)
        let merged = newer.merging(over: older)
        #expect(merged.contextPercent == 50)
        #expect(merged.todoTotal == 1)
    }
}
