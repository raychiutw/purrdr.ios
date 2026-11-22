import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的 Antigravity 情境(`antigravity`,#446):多一個 Antigravity Agent「garden」,對話紀錄是 agy 的真實格式,
/// 畫面狀態列是「accept-edits · Gemini 4 Neon · medium」。預設的 Demo 沒有它(不改變其他 UI 測試的列數)。
@Suite("Demo 主機的 Antigravity")
struct DemoAntigravityTests {
    static let conversationID = "d3m0a9a9-0000-4000-8000-000000000004"
    static let target = TranscriptTarget(
        dialect: .antigravity, location: TranscriptLocation(locator: .antigravity, reference: .id(conversationID)), sessionKey: conversationID)

    @Test("預設的 Demo 沒有 Antigravity;情境多一個 agy Agent,帶 session id")
    func scenarioAddsAnAntigravityAgent() async throws {
        let standard = try await HerdrClient(channel: DemoHost()).snapshot()
        #expect(!standard.agents.contains { $0.kind == "agy" })

        let snapshot = try await HerdrClient(channel: DemoHost(scenario: .antigravity)).snapshot()
        let agy = try #require(snapshot.agents.first { $0.kind == "agy" })
        #expect(agy.paneID == "w4:p1" && agy.workspaceLabel == "garden" && agy.status == .done)
        #expect(agy.session == AgentSessionReference(kind: "id", value: Self.conversationID))
        #expect(snapshot.agents.count == standard.agents.count + 1)
        #expect(AgentCatalog.profile(forHerdrName: agy.kind).id == .agy)
    }

    @Test("對話紀錄用 agy 的位置規則定位,解析成對話並讀得到模型與 token")
    func transcriptIsReadWithTheAntigravityDialect() async throws {
        let host = DemoHost(scenario: .antigravity)
        let reader = TranscriptReader(channel: host)
        let file = try await reader.locate(Self.target)
        #expect(file.path == "/Users/demo/.gemini/antigravity-cli/brain/\(Self.conversationID)/.system_generated/logs/transcript.jsonl")

        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
        let dialect = TranscriptDialect.antigravity
        let items = Conversation.items(from: chunk.lines.flatMap(dialect.messages(in:)))
        #expect(items.count >= 3)
        let metadata = dialect.latestMetadata(in: chunk.lines)
        #expect(metadata.model == "Gemini 4 Neon" && metadata.effort == "medium")
        #expect(metadata.contextTokens == 3600 + 5100)
    }

    @Test("pane 畫面有 Antigravity 的狀態列:accept-edits、Gemini 4 Neon、medium")
    func screenHasStatusLine() async throws {
        let screen = try await HerdrClient(channel: DemoHost(scenario: .antigravity)).readPane(paneID: "w4:p1")

        let line = AgentCatalog.profile(for: .agy).screen.readStatusLine(in: screen)
        #expect(line == AgentStatusLine(mode: .acceptEdits, model: "Gemini 4 Neon", effort: "medium"))
    }

    @Test("送出 prompt:對話紀錄接上使用者那一行與示範回覆;! 指令也一樣只回示範說明")
    func promptIsAppended() async throws {
        let host = DemoHost(scenario: .antigravity)
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w4:p1", text: "!ls", wait: nil)
        let reader = TranscriptReader(channel: host)
        let file = try await reader.locate(Self.target)
        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)

        let items = Conversation.items(from: chunk.lines.flatMap(TranscriptDialect.antigravity.messages(in:)))
        guard case .user(let user) = items.dropLast().last else {
            Issue.record("倒數第二項不是使用者訊息:\(items)")
            return
        }
        #expect(user.text == "!ls")
        guard case .agentText(let reply) = items.last else {
            Issue.record("最後一項不是回覆")
            return
        }
        #expect(reply.markdown.contains("demo host"))
    }
}
