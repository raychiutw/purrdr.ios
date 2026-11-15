import Foundation
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

    @Test("Claude:打 / 出現在主機上發現的清單(mattpocock-skills 的 27 個都在),選取後草稿換成 /名稱 ")
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
        model.slash.handle(.select)
        #expect(model.draft == "/mattpocock-skills:to-tickets ")
        #expect(!model.slash.isVisible)
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
}
