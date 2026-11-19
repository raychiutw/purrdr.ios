import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機上 Claude Code agent 的對話紀錄(行為規格 F21)。
///
/// 形狀照 Claude Code 2.1.3xx 的 JSONL(type、uuid、timestamp、message.content 的 block),內容是自己寫的範例。
/// 對真正 client 會送出的**精確**指令(`TranscriptCommand`)回應：定位、讀視窗、從游標追蹤、列表預覽。
enum DemoTranscripts {
    struct Session {
        let sessionID: String
        let cwd: String
        let paneID: String
        let lines: [String]

        var path: String { "/Users/demo/.claude/projects/\(ClaudeTranscript.projectFolder(forCWD: cwd))/\(sessionID).jsonl" }
        var data: Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

        /// 加上送出 prompt 後接在後面的行。
        func appending(_ extra: [String]) -> Session {
            Session(sessionID: sessionID, cwd: cwd, paneID: paneID, lines: lines + extra)
        }
    }

    static let sessions = [ledger, weather]

    /// 對指令的 stdout;不是對話紀錄指令時回傳 `nil`。`appended` 是送出 prompt 後各 session 接上的行。
    static func respond(to command: String, appended: [String: [String]] = [:]) -> Data? {
        if let delegation = respondToDelegation(command) { return delegation }
        let sessions = sessions.map { $0.appending(appended[$0.sessionID] ?? []) }
        for session in sessions {
            let size = session.data.count
            if command == TranscriptCommand.locate(sessionID: session.sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: session.cwd)) {
                return Data("\(session.path)\n\(size)\n".utf8)
            }
            if command == TranscriptCommand.window(path: session.path, end: size, lines: 300) {
                // 視窗起點是最後 300 行之前的 byte 數(行數超過 300 時不是 0)。
                let window = Array(session.lines.suffix(300))
                let start = size - window.reduce(0) { $0 + $1.utf8.count + 1 }
                return Data("\(start) \(size)\n".utf8) + records(window)
            }
            // 游標可能停在任何一個行邊界(送出 prompt 前讀到的大小)。
            var cursor = 0
            for (index, line) in session.lines.enumerated() {
                cursor += line.utf8.count + 1
                if command == TranscriptCommand.tail(path: session.path, from: cursor, limit: 64 << 10) {
                    // 落後超過上限時主機只印大小(開啟時改讀新視窗)。
                    guard size - cursor <= 64 << 10 else { return Data("\(size)\n".utf8) }
                    return Data("\(size)\n".utf8) + records(Array(session.lines[(index + 1)...]))
                }
                // 分段追趕的上限有兩種(一般、落後很多時)。
                for limit in [TranscriptReader.catchUpLimit, TranscriptReader.catchUpBacklogLimit]
                where command == TranscriptCommand.catchUp(path: session.path, from: cursor, limit: limit) {
                    return Data("\(size)\n".utf8) + records(catchUp(Array(session.lines[(index + 1)...]), limit: limit))
                }
            }
        }
        // 預覽的分隔標記每次隨機：取出標記後，以同一個標記重建指令比對。
        if let marker = previewMarker(in: command) {
            let requests = sessions.map { ($0.paneID, $0.sessionID, ClaudeTranscript.projectFolder(forCWD: $0.cwd)) }
            for count in 1...requests.count {
                for subset in combinations(requests, count) where command == TranscriptCommand.previews(marker: marker, requests: subset) {
                    return subset.reduce(into: Data()) { output, request in
                        guard let session = sessions.first(where: { $0.sessionID == request.1 }) else { return }
                        output += Data("\(marker) \(request.0)\n".utf8) + session.data + Data("\n".utf8)
                    }
                }
            }
        }
        return nil
    }

    /// 是否為對話畫面定位某個 Demo session 對話紀錄的指令(對話畫面讀對話紀錄的第一步)。
    static func isLocate(_ command: String) -> Bool {
        sessions.contains {
            command == TranscriptCommand.locate(sessionID: $0.sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: $0.cwd))
        }
    }

    /// 分段追趕：累計不超過 `limit` 的完整行;第一行就超過時只有那一行(與主機腳本相同;Demo 的行都比上限小，不必截短)。
    private static func catchUp(_ lines: [String], limit: Int) -> [String] {
        var total = 0
        var taken: [String] = []
        for line in lines {
            total += line.utf8.count + 1
            if total > limit, !taken.isEmpty { break }
            taken.append(line)
        }
        return taken
    }

    private static func records(_ lines: [String]) -> Data {
        Data(lines.map { "\($0.utf8.count)\t\($0)\n" }.joined().utf8)
    }

    private static func previewMarker(in command: String) -> String? {
        guard let start = command.range(of: "' sh '") else { return nil }
        let rest = command[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    /// 保持順序的子集合(預覽請求依 snapshot 順序)。
    private static func combinations<T>(_ items: [T], _ count: Int) -> [[T]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        let first = items[0]
        let rest = Array(items.dropFirst())
        return combinations(rest, count - 1).map { [first] + $0 } + combinations(rest, count)
    }

    // MARK: - 範例內容

    static let ledger = Session(
        sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger", paneID: "w1:p1",
        lines: [
            user("d3m0-l-01", "2026-11-16T09:00:00.000Z", "Tidy up the CSV export: dates first, and escape commas in notes."),
            assistantText("d3m0-l-02", "2026-11-16T09:00:04.000Z", "I'll start by running the export tests to see where we are."),
            assistantTool("d3m0-l-03", "2026-11-16T09:00:05.000Z", id: "toolu_demo_01", name: "Bash", input: ["command": "swift test --filter CSVExportTests"]),
            toolResult("d3m0-l-04", "2026-11-16T09:00:09.000Z", id: "toolu_demo_01", text: "Test run with 6 tests passed after 0.18 seconds."),
            assistantTool("d3m0-l-05", "2026-11-16T09:00:10.000Z", id: "toolu_demo_02", name: "Skill", input: ["skill": "tdd"]),
            toolResult("d3m0-l-06", "2026-11-16T09:00:10.500Z", id: "toolu_demo_02", text: "Launching skill: tdd"),
            assistantTool("d3m0-l-07", "2026-11-16T09:00:12.000Z", id: "toolu_demo_03", name: "Read", input: ["file_path": "/Users/demo/ledger/Sources/Ledger/CSVExport.swift"]),
            toolResult("d3m0-l-08", "2026-11-16T09:00:12.200Z", id: "toolu_demo_03", text: "static let columns = [\"amount\", \"date\", \"note\"]"),
            assistantTool("d3m0-l-09", "2026-11-16T09:00:20.000Z", id: "toolu_demo_04", name: "Edit", input: [
                "file_path": "/Users/demo/ledger/Sources/Ledger/CSVExport.swift",
                "old_string": "[\"amount\", \"date\", \"note\"]", "new_string": "[\"date\", \"amount\", \"note\"]",
            ]),
            // 寫檔情境(#224):Edit 與 Write 的結果帶 `toolUseResult`(形狀照 #223 錄製的 Claude Code 2.1.328),聊天顯示檔案卡片。
            toolResult("d3m0-l-10", "2026-11-16T09:00:20.300Z", id: "toolu_demo_04",
                       text: "The file /Users/demo/ledger/Sources/Ledger/CSVExport.swift has been updated successfully.", toolUseResult: [
                "filePath": "/Users/demo/ledger/Sources/Ledger/CSVExport.swift",
                "oldString": "[\"amount\", \"date\", \"note\"]", "newString": "[\"date\", \"amount\", \"note\"]",
                "structuredPatch": [[
                    "oldStart": 3, "oldLines": 3, "newStart": 3, "newLines": 3,
                    "lines": [" enum CSVExport {", "-    static let columns = [\"amount\", \"date\", \"note\"]", "+    static let columns = [\"date\", \"amount\", \"note\"]", " "],
                ]],
                "userModified": false, "replaceAll": false,
            ]),
            assistantTool("d3m0-l-10a", "2026-11-16T09:00:21.000Z", id: "toolu_demo_06", name: "Write", input: [
                "file_path": "/Users/demo/ledger/Tests/LedgerTests/CSVQuotingTests.swift", "content": quotingTests,
            ]),
            toolResult("d3m0-l-10b", "2026-11-16T09:00:21.200Z", id: "toolu_demo_06",
                       text: "File created successfully at: /Users/demo/ledger/Tests/LedgerTests/CSVQuotingTests.swift", toolUseResult: [
                "type": "create", "filePath": "/Users/demo/ledger/Tests/LedgerTests/CSVQuotingTests.swift", "content": quotingTests,
                "structuredPatch": [Any](), "originalFile": NSNull(), "userModified": false,
            ]),
            // 圖片縮圖情境(#225):Read 圖片的結果帶 `toolUseResult.type == image`(形狀照 #223 錄製;圖片資料像主機剝圖後一樣是空的)。
            // 預覽圖自動載入縮圖，掃描檔超過 8 MiB 等點擊;內容由 `DemoHostFileFetcher` 提供。
            assistantTool("d3m0-l-10c", "2026-11-16T09:00:21.400Z", id: "toolu_demo_07", name: "Read", input: ["file_path": DemoHostFileFetcher.previewPath]),
            imageResult("d3m0-l-10d", "2026-11-16T09:00:21.600Z", id: "toolu_demo_07", size: DemoImages.previewSize),
            assistantTool("d3m0-l-10e", "2026-11-16T09:00:21.700Z", id: "toolu_demo_08", name: "Read", input: ["file_path": DemoHostFileFetcher.scanPath]),
            imageResult("d3m0-l-10f", "2026-11-16T09:00:21.900Z", id: "toolu_demo_08", size: DemoImages.scanSize),
            // 點開檔案情境(#228):寫了匯出檔的開頭再附加全部紀錄(超過 25 MiB),寫了草稿又刪掉(主機上已沒有)。
            assistantTool("d3m0-l-10g", "2026-11-16T09:00:22.100Z", id: "toolu_demo_f1", name: "Write", input: [
                "file_path": DemoHostFileFetcher.historyPath, "content": historyHeader,
            ]),
            toolResult("d3m0-l-10h", "2026-11-16T09:00:22.200Z", id: "toolu_demo_f1",
                       text: "File created successfully at: \(DemoHostFileFetcher.historyPath)", toolUseResult: [
                "type": "create", "filePath": DemoHostFileFetcher.historyPath, "content": historyHeader,
                "structuredPatch": [Any](), "originalFile": NSNull(), "userModified": false,
            ]),
            assistantTool("d3m0-l-10i", "2026-11-16T09:00:22.300Z", id: "toolu_demo_f2", name: "Write", input: [
                "file_path": DemoHostFileFetcher.draftPath, "content": historyHeader,
            ]),
            toolResult("d3m0-l-10j", "2026-11-16T09:00:22.400Z", id: "toolu_demo_f2",
                       text: "File created successfully at: \(DemoHostFileFetcher.draftPath)", toolUseResult: [
                "type": "create", "filePath": DemoHostFileFetcher.draftPath, "content": historyHeader,
                "structuredPatch": [Any](), "originalFile": NSNull(), "userModified": false,
            ]),
            assistantTool("d3m0-l-10k", "2026-11-16T09:00:23.000Z", id: "toolu_demo_f3", name: "Bash", input: [
                "command": "swift run ledger export --all --skip-header >> exports/history.csv && rm exports/draft.csv",
            ]),
            toolResult("d3m0-l-10l", "2026-11-16T09:00:25.000Z", id: "toolu_demo_f3", text: "Exported 412,880 rows."),
            assistantTool("d3m0-l-11", "2026-11-16T09:00:22.000Z", id: "toolu_demo_05", name: "Bash", input: ["command": "swift test --filter CSVExportTests"]),
            toolResult("d3m0-l-12", "2026-11-16T09:00:26.000Z", id: "toolu_demo_05", text: "Test run with 7 tests passed after 0.21 seconds."),
            assistantText("d3m0-l-13", "2026-11-16T09:00:30.000Z", """
            Done. The export now writes **date, amount, note**, and notes with commas are quoted.

            | Column | Type | Example |
            |:--|:--|--:|
            | date | `String` | 2026-11-16 |
            | amount | `Decimal` | 12.50 |
            | note | `String` | "coffee, beans" |

            ```swift
            static let columns = ["date", "amount", "note"]
            ```

            Quoting follows [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180); local notes are in [the README](file:///Users/demo/ledger/README.md).
            """),
        ]
    )

    /// ledger 的 agent 新建的測試檔(寫檔情境)。
    static let quotingTests = """
    import Testing
    @testable import Ledger

    @Test func notesWithCommasAreQuoted() {
        let row = CSVExport.row(date: "2026-11-16", amount: 12.5, note: "coffee, beans")
        #expect(row == "2026-11-16,12.50,\"coffee, beans\"")
    }

    @Test func datesComeFirst() {
        #expect(CSVExport.columns.first == "date")
    }
    """

    /// ledger 匯出檔的開頭(點開檔案情境)。
    static let historyHeader = """
    date,amount,note
    2026-11-14,4.20,coffee
    2026-11-15,12.50,"coffee, beans"

    """

    /// ledger 的 CSVExport.swift(Demo 主機上修改後的內容)。
    static let exportSource = """
    import Foundation

    enum CSVExport {
        static let columns = ["date", "amount", "note"]

        static func row(date: String, amount: Decimal, note: String) -> String {
            [date, String(format: "%.2f", NSDecimalNumber(decimal: amount).doubleValue), quoted(note)].joined(separator: ",")
        }

        static func quoted(_ field: String) -> String {
            field.contains(",") ? "\\"\\(field)\\"" : field
        }
    }

    """

    static let weather = Session(
        sessionID: "d3m0d3m0-0000-4000-8000-000000000002", cwd: "/Users/demo/weather-app", paneID: "w2:p1",
        lines: [
            user("d3m0-w-01", "2026-11-16T08:40:00.000Z", "Cache the hourly forecast so the widget doesn't refetch every time."),
            assistantText("d3m0-w-02", "2026-11-16T08:40:06.000Z", "I'll add a small on-disk cache keyed by location and hour."),
            assistantTool("d3m0-w-03", "2026-11-16T08:40:08.000Z", id: "toolu_demo_11", name: "Grep", input: ["pattern": "fetchHourly"]),
            toolResult("d3m0-w-04", "2026-11-16T08:40:08.400Z", id: "toolu_demo_11", text: "Sources/Forecast/ForecastClient.swift:31"),
            assistantTool("d3m0-w-04a", "2026-11-16T08:40:09.000Z", id: subagentCall, name: "Agent", input: [
                "description": "Check how the widget refreshes", "subagent_type": "Explore", "model": "sonnet",
                "prompt": "Find where the widget asks for a new forecast and how often.",
            ]),
            toolResult("d3m0-w-04b", "2026-11-16T08:41:15.000Z", id: subagentCall, text: """
            [Subagent hand-back] The text below is the final report of a subagent this session delegated to. The report follows:
              The widget's timeline asks for a new entry every 15 minutes.
              Each entry calls `ForecastClient.fetchHourly()`, so a cache keyed by hour saves three of every four calls.
            agentId: \(subagentID) (use SendMessage with to: '\(subagentID)' to continue this agent)
            <usage>subagent_tokens: 21500
            tool_uses: 6
            duration_ms: 66000</usage>
            """),
            assistantTool("d3m0-w-04c", "2026-11-16T08:41:20.000Z", id: "toolu_demo_14", name: "Workflow", input: [
                "script": "export const meta = {\n  name: 'forecast-audit',\n  description: 'Check the cache, then review the widget copy',\n}\n",
            ]),
            toolResult("d3m0-w-04d", "2026-11-16T08:41:20.200Z", id: "toolu_demo_14", text: "Workflow launched in the background.\nRun ID: \(workflowRun)\nYou will be notified when it finishes."),
            assistantTool("d3m0-w-05", "2026-11-16T08:40:15.000Z", id: "toolu_demo_12", name: "Write", input: [
                "file_path": "/Users/demo/weather-app/Sources/Forecast/ForecastCache.swift", "content": "struct ForecastCache {}",
            ]),
            assistantText("d3m0-w-06", "2026-11-16T08:40:16.000Z", "I need permission to create `ForecastCache.swift`."),
        ]
    )

    // MARK: - 送出 prompt

    /// Demo 的 agent 收到 prompt 時接在對話紀錄後面的兩行：使用者那一行與固定的回覆。
    static func reply(to prompt: String, number: Int, at date: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if prompt.hasPrefix("!") {
            // Shell `!` 指令(F5.9):Claude 記成兩個連續的使用者行——輸入與輸出。
            let command = String(prompt.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                user("d3m0-p-\(number)-i", formatter.string(from: date), "<bash-input>\(command)</bash-input>"),
                user("d3m0-p-\(number)-o", formatter.string(from: date.addingTimeInterval(1)),
                     "<bash-stdout>demo: this is the demo host, so the command did not run.\nOn your own computer, its output would appear here.</bash-stdout><bash-stderr></bash-stderr>"),
            ]
        }
        return [
            userPrompt("d3m0-p-\(number)-u", formatter.string(from: date), prompt),
            assistantText("d3m0-p-\(number)-a", formatter.string(from: date.addingTimeInterval(2)), """
            This is the demo host, so nothing actually ran. On your own computer, the agent would pick up your message \
            and its reply would appear here.
            """),
        ]
    }

    /// 大量輸出(`-demoLargeOutput`,#130):agent 一口氣讀了 160 份記錄檔，一次寫出 321 行、超過 64 KiB
    /// (超過開啟時「落後太多」的門檻，也比開啟視窗的 300 行多)。最後一則是收尾的文字。
    /// `run` 區分同一個對話裡的多次大量輸出(每次的行 id 不同)。
    static func largeOutput(run: Int = 0, at date: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
        var lines: [String] = []
        for number in 1...160 {
            let id = "toolu_demo_log_\(run)_\(number)"
            lines.append(assistantTool("d3m0-log-\(run)-\(number)-c", timestamp, id: id, name: "Read", input: ["file_path": "/Users/demo/ledger/logs/export-\(number).log"]))
            lines.append(toolResult("d3m0-log-\(run)-\(number)-r", timestamp, id: id, text: String(repeating: "2026-11-16 09:01:00 export row \(number) ok\n", count: 12)))
        }
        lines.append(assistantText("d3m0-log-\(run)-done", timestamp, largeOutputSummary))
        return lines
    }

    /// 長對話(`-demoLargeOutputOnPrompt`):150 輪你來我往的文字訊息，畫面上有很多高的列。
    static func longChat(at date: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
        let paragraph = "The export keeps dates first and quotes notes that contain commas, so spreadsheets open them cleanly."
        return (1...150).flatMap { number in
            [
                user("d3m0-chat-\(number)-u", timestamp, "Question \(number): is row \(number) of the export correct?"),
                assistantText("d3m0-chat-\(number)-a", timestamp, "Row \(number) looks right.\n\n" + Array(repeating: paragraph, count: 3).joined(separator: "\n\n")),
            ]
        }
    }

    static let largeOutputSummary = "I read all 160 export logs; every row exported cleanly."

    // MARK: - Subagent 與 workflow(行為規格 F21:已完成的 subagent、執行中的 workflow)

    static let subagentCall = "toolu_demo_13"
    static let subagentID = "ad3m0000000000001"
    static let workflowRun = "wf_demo01"
    static let workflowAgentID = "aw0demo0000000001"

    static var weatherFolder: String { String(weather.path.dropLast(".jsonl".count)) }

    /// 唯讀的附屬檔案：subagent 對話紀錄與 workflow 裡 agent 的對話紀錄。
    static var sideFiles: [(path: String, lines: [String])] {
        [
            ("\(weatherFolder)/subagents/agent-\(subagentID).jsonl", [
                sidechain(user("d3m0-s-01", "2026-11-16T08:40:09.100Z", "Find where the widget asks for a new forecast and how often.")),
                sidechain(assistantTool("d3m0-s-02", "2026-11-16T08:40:12.000Z", id: "toolu_demo_s1", name: "Grep", input: ["pattern": "TimelineProvider"])),
                sidechain(toolResult("d3m0-s-03", "2026-11-16T08:40:12.300Z", id: "toolu_demo_s1", text: "Widget/ForecastTimeline.swift:12")),
                sidechain(assistantText("d3m0-s-04", "2026-11-16T08:41:14.000Z", "The timeline refreshes every 15 minutes and fetches each time.")),
            ]),
            ("\(weatherFolder)/subagents/workflows/\(workflowRun)/agent-\(workflowAgentID).jsonl", [
                sidechain(user("d3m0-f-01", "2026-11-16T08:41:21.000Z", "Check that cached forecasts expire after an hour.")),
                sidechain(assistantText("d3m0-f-02", "2026-11-16T08:41:40.000Z", "Entries older than an hour are dropped on read.")),
            ]),
        ]
    }

    static let subagentMeta = #"{"agentType":"Explore","description":"Check how the widget refreshes","toolUseId":"toolu_demo_13","spawnDepth":1,"requestShape":"foreground"}"#

    static let journal = [
        #"{"type":"launched","runId":"wf_demo01"}"#,
        #"{"type":"started","agentId":"aw0demo0000000001","label":"cache expiry","phase":"Check"}"#,
        #"{"type":"started","agentId":"aw0demo0000000002","label":"offline mode","phase":"Check"}"#,
        #"{"type":"result","agentId":"aw0demo0000000001","result":"Entries older than an hour are dropped on read."}"#,
        #"{"type":"started","agentId":"aw0demo0000000003","label":"widget copy","phase":"Review"}"#,
    ]
    static let journalChecksum = "journal 2718281828 412"

    /// subagent 定位、附屬檔案的大小與視窗、workflow journal。
    static func respondToDelegation(_ command: String) -> Data? {
        if command == TranscriptCommand.findSubagent(sessionFolder: weatherFolder, callID: subagentCall) {
            return Data("\(weatherFolder)/subagents/agent-\(subagentID).meta.json\n\(subagentMeta)\n".utf8)
        }
        for file in sideFiles {
            let size = Data(file.lines.map { $0 + "\n" }.joined().utf8).count
            if command == TranscriptCommand.tail(path: file.path, from: TranscriptReader.probeCursor, limit: 64 << 10) {
                return Data("\(size)\n".utf8)
            }
            if command == TranscriptCommand.window(path: file.path, end: size, lines: 300) {
                return Data("0 \(size)\n".utf8) + records(file.lines)
            }
            if command == TranscriptCommand.tail(path: file.path, from: size, limit: 64 << 10)
                || [TranscriptReader.catchUpLimit, TranscriptReader.catchUpBacklogLimit].contains(where: {
                    command == TranscriptCommand.catchUp(path: file.path, from: size, limit: $0)
                }) {
                return Data("\(size)\n".utf8)
            }
        }
        if command == TranscriptCommand.readWorkflow(sessionFolder: weatherFolder, runID: workflowRun, knownChecksum: "") {
            return Data((journalChecksum + "\n" + journal.map { $0 + "\n" }.joined()).utf8)
        }
        if command == TranscriptCommand.readWorkflow(sessionFolder: weatherFolder, runID: workflowRun, knownChecksum: journalChecksum) {
            return Data((journalChecksum + "\n").utf8)
        }
        return nil
    }

    private static func sidechain(_ line: String) -> String {
        line.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
    }

    // MARK: - 行

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func base(_ type: String, _ uuid: String, _ timestamp: String) -> [String: Any] {
        ["type": type, "uuid": uuid, "timestamp": timestamp, "isSidechain": false, "version": "2.1.325", "userType": "external"]
    }

    private static func user(_ uuid: String, _ timestamp: String, _ text: String) -> String {
        var object = base("user", uuid, timestamp)
        object["promptId"] = uuid
        object["origin"] = ["kind": "human"]
        object["message"] = ["role": "user", "content": text]
        return line(object)
    }

    /// 送出的 prompt 記成使用者行。帶上傳圖片時照 Claude Code 的寫法：路徑行換成 `[Image #N]`,
    /// 每張另有圖片區塊與 `[Image: source: <路徑>]`(行為規格 F6.6)。
    private static func userPrompt(_ uuid: String, _ timestamp: String, _ prompt: String) -> String {
        let (text, paths) = UploadedImages.extract(from: prompt)
        guard !paths.isEmpty else { return user(uuid, timestamp, prompt) }
        var object = base("user", uuid, timestamp)
        object["promptId"] = uuid
        object["origin"] = ["kind": "human"]
        let markers = paths.indices.map { "[Image #\($0 + 1)]" }.joined(separator: " ")
        var content: [[String: Any]] = [["type": "text", "text": text.isEmpty ? markers : text + "\n\n" + markers]]
        for path in paths {
            content.append(["type": "text", "text": "[Image: source: \(path)]"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": ""]])
        }
        object["message"] = ["role": "user", "content": content]
        return line(object)
    }

    private static func assistantText(_ uuid: String, _ timestamp: String, _ text: String) -> String {
        var object = base("assistant", uuid, timestamp)
        object["effort"] = "medium"
        object["message"] = [
            "role": "assistant", "model": "claude-opus-5-5", "type": "message",
            "content": [["type": "text", "text": text]],
            "usage": ["input_tokens": 3, "cache_creation_input_tokens": 1_200, "cache_read_input_tokens": 18_000],
        ]
        return line(object)
    }

    private static func assistantTool(_ uuid: String, _ timestamp: String, id: String, name: String, input: [String: Any]) -> String {
        var object = base("assistant", uuid, timestamp)
        object["message"] = [
            "role": "assistant", "model": "claude-opus-5-5", "type": "message",
            "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
        ]
        return line(object)
    }

    /// Read 圖片的結果(PNG)。
    private static func imageResult(_ uuid: String, _ timestamp: String, id: String, size: (width: Int, height: Int)) -> String {
        var object = base("user", uuid, timestamp)
        object["promptId"] = uuid
        object["message"] = ["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": id,
            "content": [["type": "image", "source": ["type": "base64", "data": "", "media_type": "image/png"]]],
        ]]]
        let dimensions = ["originalWidth": size.width, "originalHeight": size.height, "displayWidth": size.width, "displayHeight": size.height]
        object["toolUseResult"] = ["type": "image", "file": [
            "base64": "", "type": "image/png", "originalSize": DemoImages.encodedSize(width: size.width, height: size.height),
            "dimensions": dimensions,
        ] as [String: Any]]
        return line(object)
    }

    private static func toolResult(_ uuid: String, _ timestamp: String, id: String, text: String, toolUseResult: [String: Any]? = nil) -> String {
        var object = base("user", uuid, timestamp)
        object["promptId"] = uuid
        object["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": false]]]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        return line(object)
    }
}
