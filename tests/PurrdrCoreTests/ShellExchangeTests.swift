import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Shell `!` 交換(行為規格 F5.9)。`Fixtures/claude-code/shell.jsonl` 是作者 Mac 上真實 Claude Code 2.1.317–2.1.322
/// 對話紀錄中六組 `!` 指令(輸入行 + 輸出行)去識別化而成;最後一行「執行中」的輸入行是以第一組輸入行為底手寫的。
/// 錄不到的情境(中斷、HTML 跳脫的 `&amp;`、`<persisted-output>`、超長輸出)以其中一行為底改動，改了什麼寫在測試裡。
@Suite("Shell 指令交換")
struct ShellExchangeTests {
    static func items(_ lines: [String]) -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
    }

    static func runs(_ items: [ConversationItem]) -> [ShellRun] {
        items.compactMap { item in
            if case .shell(let run) = item { run } else { nil }
        }
    }

    /// 第 `index` 行(從 0 起算)的使用者文字換成 `content`。
    static func line(_ index: Int, content: String) -> String {
        Fixtures.transcriptLine(index, of: "shell.jsonl") { object in
            object["message"] = ["role": "user", "content": content]
        }
    }

    @Test("每組輸入行與下一行的輸出配成一個 shell 區塊;指令兩端修剪，輸出不再顯示成使用者泡泡")
    func fixturePairsInputWithOutput() {
        let items = Self.items(Fixtures.transcriptLines("shell.jsonl"))
        let runs = Self.runs(items)

        #expect(items.count == 7)
        #expect(runs.map(\.command) == [
            "wc -l < exports/2026-11.csv",
            #"cd /Users/demo/Projects/ledger-api && npx wrangler d1 execute DB --env production --remote --command "SELECT exporter, format, builtin, status FROM exporters""#,
            "cd ~/Projects/ledger-sync && git pull --ff-only origin main && zsh scripts/deploy.sh",
            "find ~ -maxdepth 4 -name '*.json' -mmin -240 -not -path '*/node_modules/*' -not -path '*/Library/*' -not -path '*/.*' 2>/dev/null | head",
            "sudo brew services start tailscale",
            "cd /Users/demo/Projects/ledger-api && pbpaste | npx wrangler secret put LEDGER_EXPORT_TOKEN",
            "swift test --filter CSVExportTests",
        ])
        #expect(runs.first?.date == (try? Date("2026-11-14T10:00:00.000Z", strategy: .iso8601)))
        // 開頭的空白是 wc 自己印的，不能修掉。
        #expect(runs[0].output == .recorded(ShellOutput(stdout: "      17", stderr: "")))
    }

    @Test("輸出：stderr 去掉前後換行;67 行的 stdout 原樣保留")
    func longOutputAndStderr() throws {
        let runs = Self.runs(Self.items(Fixtures.transcriptLines("shell.jsonl")))
        guard case .recorded(let output) = runs[1].output else { Issue.record("沒有輸出"); return }
        #expect(output.stdout.split(separator: "\n", omittingEmptySubsequences: false).count == 67)
        #expect(output.stdout.hasPrefix(" ⛅️ wrangler 4.156.0\n"))
        #expect(output.stdout.hasSuffix("  }\n]"))
        #expect(output.stderr == "Shell cwd was reset to /Users/demo/Projects/ledger")
        #expect(output.isTruncated == false)
    }

    @Test("Claude 跳脫過的 `-&gt;` 解回 `->`")
    func htmlEscapesAreDecoded() {
        let runs = Self.runs(Self.items(Fixtures.transcriptLines("shell.jsonl")))
        guard case .recorded(let output) = runs[2].output else { Issue.record("沒有輸出"); return }
        #expect(output.stdout.contains(" * branch            main       -> FETCH_HEAD\n"))
    }

    @Test("「(Bash completed with no output)」視為沒有輸出;只有 stderr 時 stdout 是空的")
    func emptyOutputs() {
        let runs = Self.runs(Self.items(Fixtures.transcriptLines("shell.jsonl")))
        #expect(runs[3].output == .recorded(ShellOutput(stdout: "", stderr: "")))
        #expect(runs[4].output == .recorded(ShellOutput(
            stdout: "",
            stderr: "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\nsudo: a password is required"
        )))
    }

    @Test("輸出裡的 ANSI 色碼去掉")
    func ansiIsStripped() {
        let runs = Self.runs(Self.items(Fixtures.transcriptLines("shell.jsonl")))
        guard case .recorded(let output) = runs[5].output else { Issue.record("沒有輸出"); return }
        #expect(!output.stdout.contains("\u{1B}"))
        #expect(output.stdout.contains("\n▲ [WARNING] Multiple environments are defined"))
    }

    @Test("對話紀錄最後一行是這個指令 → 執行中")
    func lastLineIsRunning() {
        let runs = Self.runs(Self.items(Fixtures.transcriptLines("shell.jsonl")))
        #expect(runs.last?.output == .running)
    }

    @Test("輸入行的下一則不是輸出(改動：第 1 行換成一般的使用者文字)→ 沒有記錄輸出;那一則照常顯示")
    func interruptedExchangeHasNoRecordedOutput() {
        let lines = Fixtures.transcriptLines("shell.jsonl")
        let items = Self.items([lines[0], Self.line(1, content: "never mind, check the totals instead"), lines[9], lines[10]])

        #expect(Self.runs(items).map(\.output) == [.notRecorded, .recorded(ShellOutput(stdout: "", stderr: ""))])
        #expect(items.contains { if case .user(let bubble) = $0 { bubble.text == "never mind, check the totals instead" } else { false } })
    }

    @Test("sidechain 行(改動：插入一行 isSidechain 的 assistant 文字)不打斷配對")
    func sidechainDoesNotInterrupt() {
        let lines = Fixtures.transcriptLines("shell.jsonl")
        let sidechain = Fixtures.transcriptLine(1, of: "shell.jsonl") { object in
            object["type"] = "assistant"
            object["uuid"] = "sidechain-1"
            object["isSidechain"] = true
            object["message"] = ["role": "assistant", "content": [["type": "text", "text": "subagent progress"]]]
        }
        let runs = Self.runs(Self.items([lines[0], sidechain, lines[1]]))
        #expect(runs.map(\.output) == [.recorded(ShellOutput(stdout: "      17", stderr: ""))])
    }

    @Test("跳脫只解一次、`&amp;` 最後解;`<persisted-output>` 內不解並去掉標籤(改動：第 1 行的輸出內容)")
    func escapingRules() {
        let lines = Fixtures.transcriptLines("shell.jsonl")
        let output = Self.line(1, content: "<bash-stdout>a &amp;lt; b &lt;tag&gt;\n<persisted-output>x &lt; y</persisted-output></bash-stdout><bash-stderr></bash-stderr>")
        let runs = Self.runs(Self.items([lines[0], output]))
        #expect(runs.first?.output == .recorded(ShellOutput(stdout: "a &lt; b <tag>\nx &lt; y", stderr: "")))
    }

    @Test("輸出截在 20,000 字並標註(改動：第 1 行的 stdout 換成 25,000 字)")
    func longOutputIsTruncated() {
        let lines = Fixtures.transcriptLines("shell.jsonl")
        let output = Self.line(1, content: "<bash-stdout>" + String(repeating: "x", count: 25_000) + "</bash-stdout><bash-stderr></bash-stderr>")
        guard case .recorded(let recorded)? = Self.runs(Self.items([lines[0], output])).first?.output else {
            Issue.record("沒有輸出"); return
        }
        #expect(recorded.stdout.count == 20_000)
        #expect(recorded.isTruncated)
    }

    @Test("指令本身不解跳脫(改動：第 0 行的指令含 `&amp;`)")
    func commandIsNotUnescaped() {
        let input = Self.line(0, content: "<bash-input>echo 'a &amp; b'</bash-input>")
        #expect(Self.runs(Self.items([input])).first?.command == "echo 'a &amp; b'")
    }

    @Test("列表預覽：最後一則是 shell 指令時顯示「! 指令」,輸出不當預覽")
    func previewShowsCommand() {
        let lines = Array(Fixtures.transcriptLines("shell.jsonl").prefix(2))
        let preview = Conversation.preview(of: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        #expect(preview?.text == "! wc -l < exports/2026-11.csv")
        #expect(preview?.isFromUser == true)
    }
}
