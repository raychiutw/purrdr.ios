import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 圖片的 Agent 檔案參照(#225):Read 圖片、工具結果帶圖、Codex 圖片生成成為檔案卡片，畫面依此讀縮圖。
/// 解析對象是 #223 錄製的 `Fixtures/claude-code/agent-files.jsonl`(Claude Code 2.1.328,Windows 主機)。
@Suite("圖片的 Agent 檔案參照")
struct AgentImageReferenceTests {
    static let fixture = "agent-files.jsonl"
    static let project = #"C:\Users\demo\Projects\ledger"#

    static func cards(_ lines: [String], parser: (String) -> [TranscriptMessage] = ClaudeTranscriptParser.messages(in:)) -> [AgentFileReference] {
        Conversation.items(from: lines.flatMap(parser)).compactMap { item in
            if case .agentFile(let card) = item { card.file } else { nil }
        }
    }

    @Test("Read 圖片的卡片：路徑取自工具呼叫，大小與 MIME 取自 toolUseResult")
    func readImagesBecomeCards() {
        let images = Self.cards(Fixtures.transcriptLines(Self.fixture)).filter { $0.origin == .readImage }

        #expect(images.map(\.path) == [Self.project + #"\orange.png"#, Self.project + #"\teal.jpg"#, Self.project + #"\wide.png"#])
        #expect(images.map(\.byteCount) == [81, 634, 22332])
        #expect(images.map(\.mediaType) == ["image/png", "image/jpeg", "image/png"])
        #expect(images.allSatisfy { $0.kind == .image })
    }

    @Test("Read 圖片保留 toolUseResult 的原始尺寸(列高由資料決定,#482);MCP 圖片沒有尺寸")
    func readImagesKeepDimensions() {
        let cards = Self.cards(Fixtures.transcriptLines(Self.fixture))

        let readSizes = cards.filter { $0.origin == .readImage }.map(\.pixelSize)
        #expect(readSizes == [
            ImagePixelSize(width: 16, height: 16), ImagePixelSize(width: 16, height: 16), ImagePixelSize(width: 3000, height: 2000),
        ])
        #expect(cards.filter { $0.origin == .toolImage }.allSatisfy { $0.pixelSize == nil })
    }

    @Test("MCP 工具結果帶圖：卡片路徑是 `[Image: source: …]` 另存的檔案")
    func mcpImageBecomesCard() {
        let images = Self.cards(Fixtures.transcriptLines(Self.fixture)).filter { $0.origin == .toolImage }

        #expect(images.map(\.path) == [
            #"C:\Users\demo\.claude\projects\C--Users-demo-Projects-ledger\00000000-0000-4000-a000-000000000223\tool-results\mcp-shot-blob-1795054063199-quz0nt.png"#,
        ])
        #expect(images.first?.byteCount == nil)
    }

    @Test("找不到對應的工具呼叫(呼叫在視窗之前)時不顯示 Read 圖片的卡片")
    func readImageWithoutCallHasNoCard() {
        // 只有第 7 行(index 6,orange.png 的結果),沒有前一行的 tool_use。
        let lines = [Fixtures.transcriptLines(Self.fixture)[6]]

        #expect(Self.cards(lines).isEmpty)
    }

    @Test("卡片排在工具串之後、依結果的順序")
    func imageCardsFollowTheToolRun() {
        let lines = Array(Fixtures.transcriptLines(Self.fixture).prefix(12))
        let origins = Self.cards(lines).map(\.origin)

        #expect(origins == [.created, .edited, .readImage, .readImage, .toolImage])
    }

    @Test("Codex 圖片生成的 saved_path 成為產生圖片的卡片;同一張圖的項目與事件只算一張")
    func codexGeneratedImage() {
        // 沒有 Codex 錄製檔(#223):欄位依 openai/codex `ImageGenerationEndEvent`(saved_path),未實測。
        let item = #"{"timestamp":"2026-11-19T03:00:00.000Z","type":"response_item","payload":{"type":"image_generation_call","id":"ig_1","status":"completed","revised_prompt":"A cat","saved_path":"/Users/demo/.codex/generated_images/ig_1.png"}}"#
        let event = #"{"timestamp":"2026-11-19T03:00:00.100Z","type":"event_msg","payload":{"type":"image_generation_end","call_id":"ig_1","status":"completed","revised_prompt":"A cat","saved_path":"/Users/demo/.codex/generated_images/ig_1.png"}}"#

        let images = Self.cards([item, event], parser: CodexTranscriptParser.messages(in:))

        #expect(images == [AgentFileReference(origin: .generatedImage, path: "/Users/demo/.codex/generated_images/ig_1.png")])
    }
}
