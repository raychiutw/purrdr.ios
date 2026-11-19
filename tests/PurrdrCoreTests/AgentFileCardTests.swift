import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Agent 檔案參照與檔案卡片(#224)。解析的對象是 #223 錄製的 `Fixtures/claude-code/agent-files.jsonl`
/// (Claude Code 2.1.328,Windows 主機;逐行對照見 Fixtures README)。錄不到的情境以其中一行為底改動，改了什麼寫在測試裡。
@Suite("檔案卡片")
struct AgentFileCardTests {
    static let fixture = "agent-files.jsonl"
    static let notesPath = #"C:\Users\demo\Projects\ledger\notes.txt"#

    /// 寫檔的參照(讀圖片、工具結果帶圖見 `AgentImageReferenceTests`)。
    static func fileReferences(_ lines: [String]) -> [AgentFileReference] {
        lines.flatMap(ClaudeTranscriptParser.messages(in:)).flatMap(\.parts).compactMap { part in
            if case .agentFile(let file) = part, [.created, .edited, .overwritten].contains(file.origin) { file } else { nil }
        }
    }

    @Test("Write 新建、Edit、Write 覆寫各成為一個 Agent 檔案參照")
    func writesAndEditsBecomeFileReferences() {
        let files = Self.fileReferences(Fixtures.transcriptLines(Self.fixture))

        #expect(files.map(\.origin) == [.created, .edited, .overwritten])
        #expect(files.allSatisfy { $0.path == Self.notesPath })
        #expect(files.first?.name == "notes.txt")
        #expect(files.first?.snapshot == .content("alpha\nbeta\ngamma", isTruncated: false))
        #expect(files.first?.byteCount == 16)
        #expect(files.last?.snapshot == .content("one\ntwo", isTruncated: false))
    }

    @Test("Edit 的快照是修改摘要:hunk 原樣保留、增刪行數不含檔尾換行註記")
    func editSnapshotIsTheChangeSummary() {
        let files = Self.fileReferences(Fixtures.transcriptLines(Self.fixture))
        guard files.count == 3, case .edit(let change) = files[1].snapshot else { Issue.record("沒有修改摘要"); return }
        let edit = files[1]

        #expect(change.hunks == [AgentFileHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3,
                                               lines: [" alpha", "-beta", "+delta", " gamma", #"\ No newline at end of file"#])])
        #expect(change.addedLines == 1)
        #expect(change.removedLines == 1)
        #expect(change.isTruncated == false)
        #expect(edit.byteCount == nil)
    }

    @Test("寫入失敗(`toolUseResult` 是錯誤字串)不產生檔案參照")
    func failedWriteHasNoFileReference() {
        // 第 3 行(index 2)是 Write 新建的結果：改成 Claude 寫入失敗時的樣子。
        let failed = Fixtures.transcriptLine(2, of: Self.fixture) { object in
            object["toolUseResult"] = "Error: EACCES: permission denied"
            object["message"] = ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_demo_f01", "is_error": true,
                "content": "<tool_use_error>EACCES: permission denied</tool_use_error>",
            ]]]
        }

        #expect(Self.fileReferences([failed]).isEmpty)
    }

    @Test("寫入的內容超過 20,000 字時截斷並標示;大小仍是完整內容的 bytes")
    func longContentIsTruncated() {
        let long = String(repeating: "鍵", count: 25_000)
        let line = Fixtures.transcriptLine(2, of: Self.fixture) { object in
            var result = object["toolUseResult"] as? [String: Any] ?? [:]
            result["content"] = long
            object["toolUseResult"] = result
        }

        let file = Self.fileReferences([line]).first
        #expect(file?.snapshot == .content(String(repeating: "鍵", count: 20_000), isTruncated: true))
        #expect(file?.byteCount == 75_000)
    }

    @Test("檔案卡片排在同一個工具串之後，工具串不因卡片斷開;每張卡片的 id 每次讀都一樣")
    func cardsFollowTheirToolRun() {
        let lines = Array(Fixtures.transcriptLines(Self.fixture).prefix(12))
        let items = Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))

        let kinds = items.map { item -> String in
            switch item {
            case .user: "user"
            case .toolRun(let run): "tools(\(run.steps.count))"
            case .agentFile(let card): "file(\(card.file.origin.rawValue))"
            case .agentText: "agent"
            default: "other"
            }
        }
        // Write、Edit、Read×2、MCP 截圖是同一個工具串;卡片依結果順序排在它之後(圖片卡片見 #225),最後是回覆文字。
        #expect(kinds == ["user", "tools(5)", "file(created)", "file(edited)", "file(readImage)", "file(readImage)", "file(toolImage)", "agent"])
        let again = Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        #expect(items.map(\.id) == again.map(\.id))
        if case .agentFile(let card) = items[2] {
            #expect(card.date == (try? Date("2026-11-19T02:07:38.675Z", strategy: .iso8601)))
        }
    }

    @Test("檔案類型依副檔名(不分大小寫),Windows 與 POSIX 路徑都取最後一段")
    func kindFollowsTheExtension() {
        let kinds = [
            "/Users/demo/ledger/README.md", #"C:\Users\demo\notes.TXT"#, "/Users/demo/ledger/Sources/CSVExport.swift",
            "/tmp/shot.png", "/tmp/report.pdf", "/tmp/rows.csv", "/Users/demo/ledger/Makefile",
        ].map { AgentFileReference(origin: .created, path: $0).kind }

        #expect(kinds == [.markdown, .text, .code, .image, .pdf, .data, .other])
    }

    @Test("修改摘要超過 20,000 字時只留前面的 hunk 並標示;增刪行數照完整的修改")
    func longEditIsTruncated() {
        let longLine = "+" + String(repeating: "x", count: 15_000)
        let line = Fixtures.transcriptLine(4, of: Self.fixture) { object in
            var result = object["toolUseResult"] as? [String: Any] ?? [:]
            result["structuredPatch"] = [
                ["oldStart": 1, "oldLines": 0, "newStart": 1, "newLines": 1, "lines": [longLine]],
                ["oldStart": 9, "oldLines": 1, "newStart": 10, "newLines": 1, "lines": ["-old", longLine]],
            ]
            object["toolUseResult"] = result
        }

        guard case .edit(let change) = Self.fileReferences([line]).first?.snapshot else { Issue.record("沒有修改摘要"); return }
        #expect(change.hunks.map(\.lines) == [[longLine], ["-old"]])
        #expect(change.isTruncated)
        #expect(change.addedLines == 2)
        #expect(change.removedLines == 1)
    }
}
