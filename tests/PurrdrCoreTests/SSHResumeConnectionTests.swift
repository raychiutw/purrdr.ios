import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// SSH 主機續接過去的 session(#535):`sessions.list` 與 `agent.start` 的 `resume_session` 在 SSH 連線層換成主機上的做法
/// (列清單的腳本;`herdr agent start … -- --resume <id>`／`-- --no-daemon resume <id>`),herdr 本身沒有這兩個。
@Suite("SSH 主機:續接 session 的連線層")
struct SSHResumeConnectionTests {
    static let sessionID = "48b84c34-58a1-465f-94b2-370ed0699957"
    static let started = FakeReply(
        stdout: Data((#"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"# + "\n").utf8),
        trigger: .afterStdinLine)

    private func startLine(_ host: FakeHost, kind: String, arguments: [String], resume: String?) async throws -> [String: Any] {
        await host.expect(HerdrCommand.bridge(), reply: Self.started)
        try await HerdrClient(channel: host).startAgent(
            name: "ledger", kind: kind, paneID: "w4:p1", arguments: arguments, resumeSession: resume, timeout: .seconds(5))
        let stdin = try #require(await host.executions.first?.stdin)
        return try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
    }

    @Test("Claude:resume_session 換成 args 的 --resume <id>,接在權限模式之後,請求裡不留 resume_session")
    func claudeResumeBecomesArguments() async throws {
        let host = FakeHost()

        let line = try await startLine(host, kind: "claude", arguments: ["--permission-mode", "plan"], resume: Self.sessionID)

        let params = try #require(line["params"] as? [String: Any])
        #expect(params["args"] as? [String] == ["--permission-mode", "plan", "--resume", Self.sessionID])
        #expect(params["resume_session"] == nil)
        #expect(params["kind"] as? String == "claude")
    }

    @Test("Codex:啟動參數 --no-daemon 之後接 resume <id>")
    func codexResumeBecomesArguments() async throws {
        let host = FakeHost()

        let line = try await startLine(host, kind: "codex", arguments: ["--no-daemon"], resume: Self.sessionID)

        let params = try #require(line["params"] as? [String: Any])
        #expect(params["args"] as? [String] == ["--no-daemon", "resume", Self.sessionID])
        #expect(params["resume_session"] == nil)
    }

    @Test("沒有續接時請求照舊(不加參數)")
    func startWithoutResumeIsUnchanged() async throws {
        let host = FakeHost()

        let line = try await startLine(host, kind: "claude", arguments: [], resume: nil)

        let params = try #require(line["params"] as? [String: Any])
        #expect(params["args"] == nil)
        #expect(params["resume_session"] == nil)
    }

    @Test("session id 不安全(開頭 -、含空白或引號)或種類不能續接:不送出,丟 invalid_request")
    func unsafeIdIsRejectedBeforeSending() async {
        for (kind, id) in [("claude", "--dangerously-skip-permissions"), ("claude", "a b"), ("codex", "x'y"), ("grok", Self.sessionID)] {
            let host = FakeHost()
            await #expect(throws: HerdrError.self, "\(kind) \(id)") {
                try await HerdrClient(channel: host).startAgent(
                    name: "ledger", kind: kind, paneID: "w4:p1", arguments: [], resumeSession: id, timeout: .seconds(5))
            }
            #expect(await host.executions.isEmpty)
        }
    }

    #if os(macOS)
    @Test("sessions.list:不經 herdr bridge,以腳本讀主機上的對話紀錄,回成同一個 client 解析的格式")
    func listsSessionsWithoutBridge() async throws {
        let host = try LocalShellHost.temporary()
        let cwd = "/Users/demo/Projects/garden-journal"
        let folder = ClaudeTranscript.projectFolder(forCWD: cwd)
        let url = try host.write(
            Data((#"{"type":"user","message":{"role":"user","content":"Water the plants"}}"# + "\n").utf8),
            to: ".claude/projects/\(folder)/\(Self.sessionID).jsonl")
        let modified = try Date("2026-11-20T15:02:11Z", strategy: .iso8601)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))

        let sessions = try await HerdrClient(channel: host).listSessions(cwd: cwd, agent: "claude")

        #expect(sessions == [ResumableSession(id: Self.sessionID, modified: modified, summary: "Water the plants")])
        #expect(!host.commands.contains { $0.contains("remote-api-bridge") })
    }

    @Test("sessions.list:不支援的種類(agent_kind 不是 claude／codex)丟 invalid_request,不跑腳本")
    func unknownKindIsRejected() async throws {
        let host = try LocalShellHost.temporary()

        await #expect(throws: HerdrError.self) {
            _ = try await HerdrClient(channel: host).listSessions(cwd: "/Users/demo", agent: "grok")
        }
        #expect(host.commands.isEmpty)
    }
    #endif
}
