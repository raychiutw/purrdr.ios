#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 輸入列上方的「You should know」註記(#37 故事 50):只顯示這個輸入框要送往的 session 的那則;
/// 「在聊天中討論」把註記放進輸入框。
@MainActor
@Suite("對話的 You should know 註記")
struct ConversationNoteTests {
    static func notes(for sessionID: String) throws -> (YouShouldKnowModel, LocalShellHost) {
        let host = try LocalShellHost.temporary()
        let store = #"{"sessions":[{"id":"\#(sessionID)","view":{"kind":"offer","line":"Tests run in parallel","explanation":"Use .serialized.","shownAt":5}}]}"#
        _ = try host.write(Data(store.utf8), to: ".claude/plugins/store/cc-plugin-you-should-know_builtin-ab.json")
        let model = YouShouldKnowModel(host: YouShouldKnowHost(channel: host), hostID: "mac", consent: InMemoryHostWriteConsentStore(), sleep: { _ in })
        return (model, host)
    }

    /// 註記由 initializer 接上(#566):以給定的 You should know 建立聊天。
    static func setup(notes: YouShouldKnowModel) async throws -> ConversationSendTests.Setup {
        try await ConversationSendTests.setup { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, links: .init(youShouldKnow: notes))
        }
    }

    @Test("輸入列上方只顯示這個聊天 session 的註記")
    func noteForThisSession() async throws {
        let (notes, _) = try Self.notes(for: ConversationModelTests.sessionID)
        await notes.refresh()
        let setup = try await Self.setup(notes: notes)
        #expect(setup.model.note?.line == "Tests run in parallel")

        let (other, _) = try Self.notes(for: "00000000-0000-4000-8000-000000000000")
        await other.refresh()
        let otherSetup = try await Self.setup(notes: other)
        #expect(otherSetup.model.note == nil)
    }

    @Test("在聊天中討論：空的輸入框放入草稿;已有文字時接在後面(空一行),不蓋掉")
    func discussInsertsDraft() async throws {
        let (notes, _) = try Self.notes(for: ConversationModelTests.sessionID)
        await notes.refresh()
        let setup = try await Self.setup(notes: notes)
        let note = try #require(setup.model.note)

        setup.model.draft = ""
        setup.model.insertIntoDraft(note.discussionDraft)
        #expect(setup.model.draft == note.discussionDraft)

        setup.model.draft = "my words"
        setup.model.insertIntoDraft(note.discussionDraft)
        #expect(setup.model.draft == "my words\n\n" + note.discussionDraft)
    }
}
#endif
