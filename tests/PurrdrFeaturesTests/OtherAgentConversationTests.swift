import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Grok、Antigravity、Pi／OMP 的對話閱讀與列表預覽(行為規格 §4.3–4.5)。【未實測】對話紀錄是依文件撰寫的 fixture;
/// herdr 走假主機(以錄製的 snapshot 為底，把 `w1:p6` 改成其他 agent),對話紀錄腳本在本機對真實檔案執行。
@MainActor
@Suite("對話閱讀：其他 agent")
struct OtherAgentConversationTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID
    static let grokID = "0000a0c0-0000-4000-8000-000000000001"
    static let piID = "0000b0b0-0000-4000-8000-000000000001"

    /// 把 `w1:p6` 改成 `kind` 種類的 agent,session 參照為 `session`(snapshot 的 `agent_session`)。
    static func snapshot(kind: String, session: [String: String]) -> FakeReply {
        .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent(paneID, in: &$0) {
                $0["agent"] = kind
                $0["agent_session"] = ["source": "herdr:\(kind)", "agent": kind].merging(session) { $1 }
            }
        }
    }

    @Test("Grok:以 snapshot 的 session id 找到 updates.jsonl,顯示對話與模型")
    func grokConversation() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: Self.grokID)
        try setup.shell.write(Fixtures.otherAgentTranscript("grok/updates.jsonl"), to: ".grok/sessions/-Users-demo-Projects-garden-journal/\(Self.grokID)/updates.jsonl")
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(kind: "grok", session: ["kind": "id", "value": Self.grokID]))

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.banner == nil)
        #expect(setup.model.items.count == 3)
        #expect(setup.model.metadata.model == "grok-5-fast")
        #expect(await setup.host.shellCommands.count == 2)
    }

    /// Pi／OMP 的 integration 通常以路徑回報 session;之後的輪詢只讀游標之後新增的行。
    @Test("Pi:以路徑回報的 journal 直接讀;新增的行在下次輪詢出現")
    func piConversationFromReportedPath() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: nil)
        let relative = ".pi/agent/sessions/--Users-demo-Projects-garden-journal--/2026-10-14_\(Self.piID).jsonl"
        let path = try setup.shell.write(Fixtures.otherAgentTranscript("pi/session.jsonl"), to: relative).path(percentEncoded: false)
        let reply = Self.snapshot(kind: "pi", session: ["kind": "path", "value": path])
        await setup.host.bridge.expect(Self.bridge, reply: reply)
        await setup.host.bridge.expect(Self.bridge, reply: reply)

        await setup.model.poll()
        #expect(setup.model.items.count == 8)
        #expect(setup.model.metadata == TranscriptMetadata(model: "gpt-5.6", contextTokens: 2800, effort: "high"))

        let line = #"{"type":"message","id":"9a000011","parentId":"9a000010","timestamp":"2026-10-14T09:13:00.000Z","message":{"role":"user","content":"Continue","timestamp":1792055580000}}"#
        try setup.shell.append(Data((line + "\n").utf8), to: relative)
        await setup.model.poll()

        #expect(setup.model.items.count == 9)
        guard case .user(let bubble) = setup.model.items.last else {
            Issue.record("最後一項不是使用者訊息")
            return
        }
        #expect(bubble.text == "Continue")
    }

    /// 符合 session 的檔案不只一個:不開任何檔、不依新舊猜，顯示非干擾式標示。
    @Test("Grok:同名 session 資料夾不只一個時不猜，顯示有歧義的標示")
    func ambiguousTranscriptIsNotGuessed() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: Self.grokID)
        let data = Fixtures.otherAgentTranscript("grok/updates.jsonl")
        try setup.shell.write(data, to: ".grok/sessions/a/\(Self.grokID)/updates.jsonl")
        try setup.shell.write(data, to: ".grok/sessions/b/\(Self.grokID)/updates.jsonl")
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(kind: "grok", session: ["kind": "id", "value": Self.grokID]))

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.banner == .ambiguous)
        #expect(setup.model.items.isEmpty)
        #expect(await setup.host.shellCommands.count == 1)
    }

    @Test("Antigravity:session id 還沒回報時等待(第一個 prompt 送出後才回報)")
    func antigravityWaitsForSession() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: nil)
        await setup.host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent(Self.paneID, in: &$0) {
                $0["agent"] = "agy"
                $0.removeValue(forKey: "agent_session")
            }
        })

        await setup.model.poll()

        #expect(setup.model.phase == .waitingForSession)
        #expect(await setup.host.shellCommands.isEmpty)
    }

    @Test("列表：Grok agent 也有預覽，開對話時帶它的 session")
    func listPreviewForGrok() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.otherAgentTranscript("grok/updates.jsonl"), to: ".grok/sessions/x/\(Self.grokID)/updates.jsonl")
        let host = RoutingHost(shell: shell)
        await host.bridge.expect(Self.bridge, reply: Self.snapshot(kind: "grok", session: ["kind": "id", "value": Self.grokID]))
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host))

        await model.load()

        #expect(model.previews[Self.paneID]?.text.hasPrefix("The total floored half cents.") == true)
        #expect(model.sessionID(ofPane: Self.paneID) == Self.grokID)
        #expect(await host.shellCommands.count == 1)
    }
}
