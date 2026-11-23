import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Codex 的對話閱讀與 slash 選單(行為規格 §4.2、F9.1、#37 G17)。【未實測】對話紀錄是依行為規格與 openai/codex
/// 原始碼撰寫的 fixture;herdr 走假主機(以錄製的 snapshot 為底，把 `w1:p6` 改成 Codex),對話紀錄腳本在本機對真實檔案執行。
@MainActor
@Suite("對話閱讀:Codex")
struct CodexConversationTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID
    static let sessionID = "0000c0de-0000-4000-8000-000000000001"
    static let rollout = ".codex/sessions/2026/11/14/rollout-2026-11-14T09-00-00-\(sessionID).jsonl"

    static func snapshot(session: [String: String]? = ["kind": "id", "value": sessionID]) -> FakeReply {
        .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent(paneID, in: &$0) {
                $0["agent"] = "codex"
                if let session {
                    $0["agent_session"] = ["source": "herdr:codex", "agent": "codex"].merging(session) { $1 }
                } else {
                    $0["agent_session"] = nil
                }
            }
        }
    }

    @Test("以 snapshot 的 session id 找到 rollout,顯示對話、模型與 context")
    func codexConversation() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: Self.sessionID)
        try setup.shell.write(Fixtures.otherAgentTranscript("codex/rollout.jsonl"), to: Self.rollout)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.banner == nil)
        #expect(setup.model.items.count == 3)
        #expect(setup.model.metadata == TranscriptMetadata(model: "gpt-5.5", contextTokens: 18234, effort: "medium", approvalPolicy: "on-request"))
    }

    /// Codex 會壓縮 7 天未動的 rollout:讀不了，但不是「還沒有訊息」。
    @Test("只有壓縮過的 rollout:顯示已壓縮的標示，不當成空聊天")
    func compressedRollout() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: Self.sessionID)
        try setup.shell.write(Data([0x28, 0xB5, 0x2F, 0xFD]), to: Self.rollout + ".zst")
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.banner == .compressed)
        #expect(setup.model.items.isEmpty)
    }

    @Test("Codex 打 / 出現 Codex 自己的指令清單")
    func codexSlashMenu() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(session: nil))
        await setup.model.poll()
        #expect(setup.model.phase == .waitingForSession)
        #expect(setup.model.agentKind == "codex")

        setup.model.draft = "/"
        await setup.model.slash.load()

        #expect(setup.model.slash.isVisible)
        let names = setup.model.slash.sections.flatMap(\.commands).map(\.name)
        #expect(names.contains("review"))
        #expect(names.contains("model"))
        #expect(!names.contains("imagine"))
    }
}
