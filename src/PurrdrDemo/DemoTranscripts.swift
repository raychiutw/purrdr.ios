import Foundation
import PurrdrCore

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
    }

    static let sessions = [ledger, weather]

    /// 對指令的 stdout;不是對話紀錄指令時回傳 `nil`。
    static func respond(to command: String) -> Data? {
        for session in sessions {
            let size = session.data.count
            if command == TranscriptCommand.locate(sessionID: session.sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: session.cwd)) {
                return Data("\(session.path)\n\(size)\n".utf8)
            }
            if command == TranscriptCommand.window(path: session.path, end: size, lines: 300) {
                return Data("0 \(size)\n".utf8) + records(session.lines)
            }
            if command == TranscriptCommand.tail(path: session.path, from: size, limit: 64 << 10) {
                return Data("\(size)\n".utf8)
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
            toolResult("d3m0-l-10", "2026-11-16T09:00:20.300Z", id: "toolu_demo_04", text: "The file has been updated."),
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

    static let weather = Session(
        sessionID: "d3m0d3m0-0000-4000-8000-000000000002", cwd: "/Users/demo/weather-app", paneID: "w2:p1",
        lines: [
            user("d3m0-w-01", "2026-11-16T08:40:00.000Z", "Cache the hourly forecast so the widget doesn't refetch every time."),
            assistantText("d3m0-w-02", "2026-11-16T08:40:06.000Z", "I'll add a small on-disk cache keyed by location and hour."),
            assistantTool("d3m0-w-03", "2026-11-16T08:40:08.000Z", id: "toolu_demo_11", name: "Grep", input: ["pattern": "fetchHourly"]),
            toolResult("d3m0-w-04", "2026-11-16T08:40:08.400Z", id: "toolu_demo_11", text: "Sources/Forecast/ForecastClient.swift:31"),
            assistantTool("d3m0-w-05", "2026-11-16T08:40:15.000Z", id: "toolu_demo_12", name: "Write", input: [
                "file_path": "/Users/demo/weather-app/Sources/Forecast/ForecastCache.swift", "content": "struct ForecastCache {}",
            ]),
            assistantText("d3m0-w-06", "2026-11-16T08:40:16.000Z", "I need permission to create `ForecastCache.swift`."),
        ]
    )

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

    private static func toolResult(_ uuid: String, _ timestamp: String, id: String, text: String) -> String {
        var object = base("user", uuid, timestamp)
        object["promptId"] = uuid
        object["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": false]]]
        return line(object)
    }
}
