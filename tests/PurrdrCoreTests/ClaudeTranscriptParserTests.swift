import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 解析的對象是從作者 Mac 上真實 Claude Code 2.1.3xx 對話紀錄擷取、去識別化的 `Fixtures/claude-code/session.jsonl`
/// (結構與旗標原樣，文字換成假值)。錄不到的情境以其中一行為底改動，改了什麼寫在測試裡。
@Suite("Claude 對話紀錄解析")
struct ClaudeTranscriptParserTests {
    static func items(_ lines: [String]) -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
    }

    /// 把對話項目寫成一行好讀的字，期望值依行為規格 §4.1、F5.8 對照 fixture 逐行手算。
    static func describe(_ item: ConversationItem) -> String {
        switch item {
        case .user(let bubble): "user: \(bubble.text)"
        case .agentText(let text): "agent: \(text.markdown.prefix(16))"
        case .skill(let skill): "skill: \(skill.name)"
        case .note(let note): "note: \(note.text.prefix(26))"
        case .subagent(let card): "subagent: \(card.title)"
        case .workflow(let card): "workflow: \(card.name)"
        case .toolRun(let run):
            "tools: " + run.steps.map { step in
                switch step.kind {
                case .thinking: "thinking"
                case .call(let call): call.name + (call.isError ? "!" : "") + (call.result == nil ? "?" : "")
                }
            }.joined(separator: ",")
        }
    }

    @Test("對話項目：使用者泡泡、agent 文字、工具串、skill、系統註記依序出現;harness 行與其他 type 不產生項目")
    func fixtureBecomesConversationItems() {
        let items = Self.items(Fixtures.transcriptLines())

        #expect(items.map(Self.describe) == [
            "user: /effort",
            "note: Set effort level to medium",
            "user: 幫我把 CSV 匯出整理一下 🧾",
            "tools: Bash",
            "agent: 測試都過了。先看匯出的欄位順序。",
            "tools: Bash!,thinking",
            "skill: tdd",
            "user: 順便把備註裡的換行處理掉",
            "agent: 收到，備註的換行也一起處理。",
            "tools: Bash,Edit",
            "user: /csv-check",
            "skill: csv-check",
            "agent: CSV 匯出整理好了 ✅,欄位順",
        ])
    }

    @Test("工具串摘要：依種類計數、編輯依路徑去重、失敗另計;skill 不算工具")
    func toolRunSummaryCountsByCategory() {
        let runs = Self.items(Fixtures.transcriptLines()).compactMap { item -> ToolRun? in
            if case .toolRun(let run) = item { return run }
            return nil
        }

        #expect(runs.map(\.summary) == [
            ToolRunSummary(commands: 1),
            ToolRunSummary(thoughts: 1, commands: 1, failures: 1),
            ToolRunSummary(commands: 1, editedFiles: 1),
        ])
        // 列 key 以最後一個項目命名(往上翻頁會加在前面);展開狀態 key 以第一個項目命名(R-V02)。
        #expect(runs[1].id != runs[1].expansionID)
    }

    @Test("工具結果依 tool_use_id 配對，結果的 is_error 標示失敗")
    func toolResultsPairByID() throws {
        let items = Self.items(Fixtures.transcriptLines())
        guard case .toolRun(let run) = items[3], case .call(let call) = run.steps.first?.kind else {
            Issue.record("第 4 項不是工具串")
            return
        }
        #expect(call.input == "swift test --filter CSVExportTests")
        #expect(call.result == "Test run with 12 tests passed after 0.21 seconds.")
        #expect(call.isError == false)
    }

    @Test("沒有 id 的工具結果依先進先出配給沒有 id 的呼叫")
    func toolResultsWithoutIDPairFirstInFirstOut() {
        // 以第 20、22 行為底：拿掉 tool_use 與 tool_result 的 id。
        let call = Fixtures.transcriptLine(20) { Self.editContent(&$0) { $0.removeValue(forKey: "id") } }
        let result = Fixtures.transcriptLine(22) { Self.editContent(&$0) { $0.removeValue(forKey: "tool_use_id") } }

        let items = Self.items([call, result])

        #expect(items.map(Self.describe) == ["tools: Bash"])
    }

    @Test("使用者打的字：每次解析得到同一個 id(uuid);沒有 uuid 時用去除圖片後的內容算確定性雜湊")
    func messageIDsAreStable() {
        let typed = Fixtures.transcriptLines()[6]
        #expect(ClaudeTranscriptParser.messages(in: typed).map(\.id) == ["00000000-0000-4000-8000-000000000008"])

        let withoutUUID = Fixtures.transcriptLine(6) { $0.removeValue(forKey: "uuid") }
        let first = ClaudeTranscriptParser.messages(in: withoutUUID).map(\.id)
        let second = ClaudeTranscriptParser.messages(in: withoutUUID).map(\.id)
        #expect(first.count == 1)
        #expect(first == second)
        #expect(first != ["00000000-0000-4000-8000-000000000008"])
    }

    @Test("使用者訊息帶時間戳(ISO 8601,含毫秒)")
    func userMessageHasTimestamp() throws {
        let message = try #require(ClaudeTranscriptParser.messages(in: Fixtures.transcriptLines()[6]).first)
        #expect(abs((message.date?.timeIntervalSince1970 ?? 0) - 1_794_614_143.547) < 0.001)
    }

    /// R-I15:harness 行(isMeta、isCompactSummary、promptSource system、origin 不是 human)永不成為使用者泡泡。
    @Test("Harness 行隱藏:isCompactSummary、promptSource system、origin 不是 human")
    func harnessLinesAreHidden() {
        let compact = Fixtures.transcriptLine(6) { $0["isCompactSummary"] = true }
        let system = Fixtures.transcriptLine(6) { $0["promptSource"] = "system" }
        let peer = Fixtures.transcriptLine(6) { $0["origin"] = ["kind": "task-notification"] }

        #expect(Self.items([compact, system, peer]).isEmpty)
    }

    @Test("使用者文字清理：解開 pasted_content、剝掉開頭的 harness 元素")
    func userTextIsCleaned() {
        let pasted = Fixtures.transcriptLine(6) {
            $0["message"] = ["role": "user", "content": #"看這段 <pasted_content id="1">長長的貼上</pasted_content id="1">"#]
        }
        let reminder = Fixtures.transcriptLine(6) {
            $0["message"] = ["role": "user", "content": "<system-reminder>harness 加的</system-reminder>真正打的字"]
        }

        #expect(Self.items([pasted, reminder]).map(Self.describe) == ["user: 看這段 長長的貼上", "user: 真正打的字"])
    }

    @Test("Sidechain 訊息預設隱藏")
    func sidechainIsHiddenByDefault() {
        let sidechain = Fixtures.transcriptLine(11) { $0["isSidechain"] = true }
        #expect(Self.items([sidechain]).isEmpty)
    }

    @Test("本地指令輸出成為系統註記：去 ANSI、修剪、600 字截斷;空的不顯示")
    func localCommandOutputBecomesNote() {
        let ansi = Fixtures.transcriptLine(4) {
            $0["message"] = ["role": "user", "content": "<local-command-stdout>\u{1B}[1mKept model as Opus\u{1B}[22m  </local-command-stdout>"]
        }
        let long = Fixtures.transcriptLine(4) {
            $0["message"] = ["role": "user", "content": "<local-command-stdout>" + String(repeating: "a", count: 700) + "</local-command-stdout>"]
        }
        let empty = Fixtures.transcriptLine(4) {
            $0["message"] = ["role": "user", "content": "<local-command-stdout>   </local-command-stdout>"]
        }

        let notes = Self.items([ansi, long, empty]).compactMap { item -> String? in
            if case .note(let note) = item { return note.text }
            return nil
        }
        #expect(notes.count == 2)
        #expect(notes.first == "Kept model as Opus")
        #expect(notes.last?.count == 601)
        #expect(notes.last?.hasSuffix("…") == true)
    }

    @Test("Header 中繼資料：模型、context(三種 input token 相加)、effort 取自最後一則 assistant 行")
    func metadataComesFromAssistantLines() {
        let metadata = TranscriptMetadata.latest(in: Fixtures.transcriptLines())

        #expect(metadata.model == "claude-opus-5-5")
        #expect(metadata.contextTokens == 2 + 584 + 73_066)
        #expect(metadata.effort == "medium")
    }

    /// R-I15、#80:API 錯誤、限流是 `<synthetic>` 模型的 assistant 行,照常顯示但永不設定 header 模型或 context。
    @Test("Header 中繼資料:<synthetic> 與 isApiErrorMessage 的行不設定模型與 context")
    func syntheticLinesDoNotSetMetadata() {
        let synthetic = Fixtures.transcriptLine(27) { line in
            var message = line["message"] as? [String: Any] ?? [:]
            message["model"] = "<synthetic>"
            line["message"] = message
            line["isApiErrorMessage"] = true
        }

        let metadata = TranscriptMetadata.latest(in: Array(Fixtures.transcriptLines()[0...21]) + [synthetic])

        #expect(metadata.model == "claude-sonnet-5-5")
        #expect(Self.items([synthetic]).map(Self.describe) == ["agent: CSV 匯出整理好了 ✅,欄位順"])
    }

    @Test("模型顯示名：去掉日期與 [] 尾碼、provider 前綴;非 Claude id 原樣")
    func modelDisplayNames() {
        #expect(TranscriptMetadata.displayName(ofModel: "claude-opus-5-5") == "Opus 5.5")
        #expect(TranscriptMetadata.displayName(ofModel: "claude-opus-4-1-20250805") == "Opus 4.1")
        #expect(TranscriptMetadata.displayName(ofModel: "claude-sonnet-4-20250514") == "Sonnet 4")
        #expect(TranscriptMetadata.displayName(ofModel: "claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(TranscriptMetadata.displayName(ofModel: "anthropic/claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(TranscriptMetadata.displayName(ofModel: "gpt-5-codex") == "gpt-5-codex")
    }

    @Test("看不懂的行(被截斷的尾行)略過")
    func malformedLinesAreSkipped() {
        let truncated = String(Fixtures.transcriptLines()[6].prefix(40))
        #expect(ClaudeTranscriptParser.messages(in: truncated).isEmpty)
    }

    @Test("列表預覽：最後一則非工具、非系統的訊息;去掉 markdown 記號、壓縮空白")
    func previewIsLastReadableMessage() {
        let preview = Conversation.preview(of: Fixtures.transcriptLines().flatMap(ClaudeTranscriptParser.messages(in:)))

        #expect(preview?.text == "CSV 匯出整理好了 ✅,欄位順序改成 日期、金額、備註。 | 欄位 | 型別 | 對齊 | |:--|:-:|--:| | date | String | 左 | | amount | Decimal | 右 | | note | String \\| nil | swift static let columns = [\"date\", \"amount\", \"note\"] 細節見 [RFC 4180…")
        #expect(preview?.isFromUser == false)
        #expect(preview?.date != nil)
    }

    static func editContent(_ line: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var message = line["message"] as? [String: Any], var content = message["content"] as? [[String: Any]] else { return }
        for index in content.indices { change(&content[index]) }
        message["content"] = content
        line["message"] = message
    }
}
