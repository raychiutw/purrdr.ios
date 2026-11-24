import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// SSH 主機列出過去的 Claude Code／Codex session(#535):一次性腳本以 `LocalShellHost` 對暫存家目錄實跑,
/// 輸出對齊主機服務的 `sessions.list`(id、最後修改時間、第一則使用者訊息摘要,新到舊,最多 50 個)。
@Suite("SSH 主機:過去的 session 清單")
struct SSHSessionHistoryTests {
    let host: LocalShellHost
    let cwd = "/Users/demo/Projects/garden-journal"

    init() throws {
        host = try LocalShellHost.temporary()
    }

    private var claudeFolder: String { ".claude/projects/" + ClaudeTranscript.projectFolder(forCWD: cwd) }

    @discardableResult
    private func seed(_ lines: [String], at path: String, modified: Date) throws -> URL {
        let url = try host.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    private static func claudeUser(_ text: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(jsonString(text))},"uuid":"u1"}"#
    }

    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func list(_ kind: String) async throws -> [ResumableSession] {
        try await SSHSessionHistory(channel: host).sessions(cwd: cwd, kind: kind)
    }

    private func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

    @Test("Claude:這個資料夾的 session 新到舊,id 是檔名,時間是檔案修改時間,摘要是第一則使用者自己打的訊息")
    func claudeNewestFirst() async throws {
        try seed([Self.claudeUser("Add a daily watering reminder to README.md")], at: claudeFolder + "/48b84c34-58a1-465f-94b2-370ed0699957.jsonl", modified: date("2026-11-20T15:02:11Z"))
        try seed([#"{"type":"summary"}"#], at: claudeFolder + "/0b9e6f1c-2d4a-4c8e-9f00-5a1b2c3d4e5f.jsonl", modified: date("2026-11-19T09:40:03Z"))
        try seed([Self.claudeUser("older")], at: claudeFolder + "/11111111-2222-3333-4444-555555555555.jsonl", modified: date("2026-11-21T01:00:00Z"))
        // 別的資料夾與不是 .jsonl 的檔案不算。
        try seed([Self.claudeUser("elsewhere")], at: ".claude/projects/-Users-demo-other/99999999-0000-0000-0000-000000000000.jsonl", modified: date("2026-11-22T00:00:00Z"))
        try seed(["x"], at: claudeFolder + "/notes.txt", modified: date("2026-11-22T00:00:00Z"))

        let sessions = try await list("claude")

        #expect(sessions == [
            ResumableSession(id: "11111111-2222-3333-4444-555555555555", modified: date("2026-11-21T01:00:00Z"), summary: "older"),
            ResumableSession(id: "48b84c34-58a1-465f-94b2-370ed0699957", modified: date("2026-11-20T15:02:11Z"), summary: "Add a daily watering reminder to README.md"),
            ResumableSession(id: "0b9e6f1c-2d4a-4c8e-9f00-5a1b2c3d4e5f", modified: date("2026-11-19T09:40:03Z"), summary: nil),
        ])
    }

    @Test("Claude 摘要:略過 isMeta、<…> 開頭的指令與系統注入、中斷提示、工具結果;陣列內容取第一個文字;空白合併、逸出還原、最長 120 字")
    func claudeSummaryRules() async throws {
        let long = String(repeating: "字", count: 200)
        try seed([
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta text"}}"#,
            Self.claudeUser("<command-name>/clear</command-name>"),
            Self.claudeUser("[Request interrupted by user]"),
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"tool output"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"assistant words"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"  Fix   the\n\ttest \"quoted\" \#(long)"}]}}"#,
            Self.claudeUser("later message"),
        ], at: claudeFolder + "/a1.jsonl", modified: date("2026-11-20T00:00:00Z"))

        let sessions = try await list("claude")

        let summary = try #require(sessions.first?.summary)
        #expect(summary.hasPrefix("Fix the test \"quoted\" "))
        #expect(summary.count == 120)
    }

    @Test("Claude:檔名不安全(開頭 -、含空白)的不列;最多 50 個")
    func claudeUnsafeNamesAndLimit() async throws {
        for index in 0..<55 {
            try seed([Self.claudeUser("m\(index)")], at: claudeFolder + "/s\(String(format: "%02d", index)).jsonl", modified: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        }
        try seed([Self.claudeUser("bad")], at: claudeFolder + "/-rf.jsonl", modified: Date(timeIntervalSince1970: 1_900_000_000))
        try seed([Self.claudeUser("bad")], at: claudeFolder + "/a b.jsonl", modified: Date(timeIntervalSince1970: 1_900_000_000))

        let sessions = try await list("claude")

        #expect(sessions.count == 50)
        #expect(sessions.first?.id == "s54")
        #expect(sessions.last?.id == "s05")
    }

    private static func codexMeta(id: String, cwd: String) -> String {
        #"{"timestamp":"2026-11-20T15:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":\#(jsonString(cwd)),"originator":"codex_cli_rs"}}"#
    }

    @Test("Codex:sessions/ 底下 session_meta 的 cwd 等於這個資料夾的 rollout,新到舊,摘要略過 <…> 的環境訊息")
    func codexMatchesCwd() async throws {
        try seed([
            Self.codexMeta(id: "019a0000-0000-7000-8000-000000000001", cwd: cwd),
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Summarize the repo","kind":"plain"}}"#,
        ], at: ".codex/sessions/2026/11/20/rollout-2026-11-20T15-00-00-019a0000-0000-7000-8000-000000000001.jsonl", modified: date("2026-11-20T15:30:00Z"))
        try seed([
            Self.codexMeta(id: "019a0000-0000-7000-8000-000000000002", cwd: cwd),
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Second one"}]}}"#,
        ], at: ".codex/sessions/2026/11/21/rollout-2026-11-21T08-00-00-019a0000-0000-7000-8000-000000000002.jsonl", modified: date("2026-11-21T09:00:00Z"))
        try seed([Self.codexMeta(id: "019a0000-0000-7000-8000-000000000003", cwd: "/Users/demo/other")],
                 at: ".codex/sessions/2026/11/22/rollout-2026-11-22T08-00-00-019a0000-0000-7000-8000-000000000003.jsonl", modified: date("2026-11-22T09:00:00Z"))
        try seed([Self.codexMeta(id: "019a0000-0000-7000-8000-000000000004", cwd: cwd)],
                 at: ".codex/sessions/2026/11/22/not-a-rollout.jsonl", modified: date("2026-11-22T09:00:00Z"))

        let sessions = try await list("codex")

        #expect(sessions == [
            ResumableSession(id: "019a0000-0000-7000-8000-000000000002", modified: date("2026-11-21T09:00:00Z"), summary: "Second one"),
            ResumableSession(id: "019a0000-0000-7000-8000-000000000001", modified: date("2026-11-20T15:30:00Z"), summary: "Summarize the repo"),
        ])
    }

    @Test("沒有任何紀錄(資料夾不存在):空清單,不丟錯")
    func emptyWhenNothingThere() async throws {
        #expect(try await list("claude").isEmpty)
        #expect(try await list("codex").isEmpty)
    }

    @Test("指令帶自我時限,參數(種類、資料夾、Claude 專案資料夾名)以位置參數傳入")
    func commandCarriesLimit() throws {
        let command = SessionHistoryCommand.command(kind: "claude", cwd: cwd)
        #expect(command.contains(HostScriptTimeLimit.posixMarker))
        #expect(SessionHistoryCommand.arguments(in: command) == ["claude", cwd, ClaudeTranscript.projectFolder(forCWD: cwd)])
    }
}

#endif
