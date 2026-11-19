import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 對話畫面的 slash 選單(#15):清單依 agent 種類取得;Claude 的清單在主機上發現(作者 Mac 錄下的 plugin 結構)。
@MainActor
@Suite("對話的 Slash 選單")
struct ConversationSlashTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID

    static func setup() throws -> (RoutingHost, ConversationModel) {
        let shell = try LocalShellHost.temporary()
        try ClaudePluginsFixture.install(into: shell)
        let transcript = Fixtures.transcript() + Fixtures.transcript("skill-listing.jsonl")
        try shell.write(transcript, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let model = ConversationModel(
            client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host), paneID: paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
            slashDiscovery: ClaudeSlashDiscovery(channel: host)
        )
        return (host, model)
    }

    @Test("Claude:打 / 出現在主機上發現的清單(mattpocock-skills 的 27 個都在),選取有副作用的指令只填入 /名稱 ")
    func claudeMenuFromHost() async throws {
        let (host, model) = try Self.setup()
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await model.poll()

        model.draft = "/"
        await model.slash.load()
        #expect(model.slash.isVisible)
        #expect(!model.slash.isIncomplete)
        let matt = model.slash.sections.first { $0.source == .plugin("mattpocock-skills") }?.commands.map(\.name) ?? []
        #expect(matt.count == 27)
        #expect(model.slash.sections.first?.source == .builtIn)
        // 對話紀錄的 skill_listing 也讀到了(Claude Code 自帶、主機上找不到出處的 skill)。
        #expect(model.slash.sections.contains { $0.source == .session })

        model.draft = "/mattpocock-skills:to-ti"
        #expect(model.slash.highlighted == "mattpocock-skills:to-tickets")
        // 有副作用的指令(#45):選取只填入、不送出，選單收起。
        model.draft = "/compac"
        #expect(model.slash.highlighted == "compact")
        model.slash.handle(.select)
        #expect(model.draft == "/compact ")
        #expect(!model.slash.isVisible)
    }

    @Test("組字中不拿暫時文字(/ㄋ)篩選 slash 選單;組字結束後依確認的文字篩選(#138)")
    func slashMenuIgnoresComposingText() async throws {
        let (host, model) = try Self.setup()
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await model.poll()
        model.draft = "/"
        await model.slash.load()

        model.isComposingDraft = true
        model.draft = "/ㄋ"
        #expect(model.slash.isVisible)
        #expect(model.slash.ranked == nil)
        model.draft = "/compac"
        #expect(model.slash.ranked == nil)

        model.isComposingDraft = false
        #expect(model.slash.highlighted == "compact")
    }

    @Test("Grok 用固定清單;Pi 沒有選單")
    func otherAgents() async throws {
        let (grokHost, grok) = try Self.setup()
        await grokHost.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.agent(Self.paneID, in: &$0) { $0["agent"] = "grok" } })
        await grok.poll()
        grok.draft = "/"
        await grok.slash.load()
        #expect(grok.slash.sections.map(\.source) == [.builtIn])
        #expect(grok.slash.sections.first?.commands.contains { $0.name == "imagine" } == true)

        let (piHost, pi) = try Self.setup()
        await piHost.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.agent(Self.paneID, in: &$0) { $0["agent"] = "pi" } })
        await pi.poll()
        pi.draft = "/"
        await pi.slash.load()
        #expect(!pi.slash.isVisible)
    }
    @Test("文字中間打「空格＋/」:只列 skill 與自訂指令，選定只換掉 /字詞,游標停在插入文字之後(#230)")
    func inlinePickKeepsSurroundingText() async throws {
        let (host, model) = try Self.setup()
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await model.poll()
        let draft = "先跑 /tdd 再幫我改"
        model.updateDraftCaret(7, in: draft)
        model.draft = draft
        await model.slash.load()
        #expect(model.slash.isVisible)
        #expect(model.slash.trigger?.placement == .inline)
        #expect(model.slash.commands.contains { $0.name == "mattpocock-skills:tdd" })
        #expect(!model.slash.commands.contains { $0.name == "clear" })

        let tdd = try #require(model.slash.commands.first { $0.name == "mattpocock-skills:tdd" })
        model.slash.pick(tdd)

        #expect(model.draft == "先跑 /mattpocock-skills:tdd 再幫我改")
        #expect(model.draftCaret == 26)
        #expect(model.lastSlashInsertion?.name == "mattpocock-skills:tdd")
        #expect(!model.slash.isVisible)
    }

    @Test("移動游標回到「空格＋/」後也叫出選單;組字中不觸發(#230)")
    func caretMoveAndComposing() async throws {
        let (host, model) = try Self.setup()
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await model.poll()
        model.draft = "hi /mat there"
        await model.slash.load()
        #expect(!model.slash.isVisible)
        model.updateDraftCaret(7, in: model.draft)
        #expect(model.slash.isVisible)
        #expect(model.slash.trigger?.query == "mat")

        model.updateDraftCaret(nil, in: model.draft)
        #expect(!model.slash.isVisible)
        model.isComposingDraft = true
        model.draft = "hi /"
        #expect(!model.slash.isVisible)
        model.isComposingDraft = false
        #expect(model.slash.isVisible)
    }
}
