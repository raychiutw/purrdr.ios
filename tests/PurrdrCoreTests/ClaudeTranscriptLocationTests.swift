import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@Suite("Claude 對話紀錄的位置與 session")
struct ClaudeTranscriptLocationTests {
    /// 行為規格 §4.1、R-I11:每個不是 `[A-Za-z0-9]` 的 UTF-16 code unit 換成 `-`。
    @Test("資料夾名：非英數的 UTF-16 code unit 換成 -(emoji 兩個 unit 變 --)")
    func projectFolderReplacesEachNonAlphanumericUTF16Unit() {
        #expect(ClaudeTranscript.projectFolder(forCWD: "/Users/x/Documents/obsidian/07_homelab") == "-Users-x-Documents-obsidian-07-homelab")
        // 實測:作者 Mac 上 `/Users/ray/Projects/trip-planner.flutter` 的資料夾是 `-Users-ray-Projects-trip-planner-flutter`。
        #expect(ClaudeTranscript.projectFolder(forCWD: "/Users/demo/Projects/trip-planner.flutter") == "-Users-demo-Projects-trip-planner-flutter")
        #expect(ClaudeTranscript.projectFolder(forCWD: "/Users/demo/🐱貓") == "-Users-demo----")
    }

    /// 超過 200 字：取前 200 字 + `-` + 原 cwd 的 Java `hashCode` 取絕對值的 base36(期望值以獨立的 Python 實作算出)。
    @Test("資料夾名：超過 200 字時截斷並加上 hashCode 的 base36")
    func projectFolderTruncatesLongPathsWithHash() {
        let cwd = "/Users/demo/" + String(repeating: "very-long-folder-name/", count: 12)
        #expect(ClaudeTranscript.projectFolder(forCWD: cwd) ==
            "-Users-demo-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-fo-y6dbva")
    }

    @Test("Session:snapshot 的 agent_session(kind id)成為 Agent 的 session 參照")
    func snapshotDecodesAgentSession() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))

        let snapshot = try await HerdrClient(channel: host).snapshot()

        #expect(snapshot.agents.first?.session == AgentSessionReference(kind: "id", value: "00000000-0000-0000-0000-000000000001"))
        #expect(snapshot.agents.first?.claudeSessionID == "00000000-0000-0000-0000-000000000001")
    }

    /// R-I12:id 在進入 shell 前驗證，不符合就拒絕(不是引號化了事);路徑參照對 Claude 不接受。
    @Test("Session:只接受 kind id 且只含英數與 - 的 session id")
    func claudeSessionIDRejectsUnsafeOrPathReferences() {
        func agent(_ session: AgentSessionReference?, kind: String = "claude") -> Agent {
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: kind, status: .idle, session: session)
        }
        #expect(agent(AgentSessionReference(kind: "id", value: "abc-123")).claudeSessionID == "abc-123")
        #expect(agent(AgentSessionReference(kind: "id", value: "../../etc/passwd")).claudeSessionID == nil)
        #expect(agent(AgentSessionReference(kind: "id", value: "a b")).claudeSessionID == nil)
        #expect(agent(AgentSessionReference(kind: "id", value: "")).claudeSessionID == nil)
        #expect(agent(AgentSessionReference(kind: "path", value: "/Users/demo/x.jsonl")).claudeSessionID == nil)
        #expect(agent(nil).claudeSessionID == nil)
        #expect(agent(AgentSessionReference(kind: "id", value: "abc"), kind: "codex").claudeSessionID == nil)
    }
}
