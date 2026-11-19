import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的寫檔情境(#224):ledger 的 agent 改了一個檔、新建了一個測試檔，對話裡有兩張檔案卡片。
@Suite("Demo 主機的檔案卡片")
struct DemoAgentFilesTests {
    @Test("ledger 的對話有修改與新建的檔案卡片，內容來自對話紀錄")
    func ledgerHasEditAndCreateCards() async throws {
        let reader = TranscriptReader(channel: DemoHost())
        let file = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
        let cards = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:))).compactMap { item in
            if case .agentFile(let card) = item { card } else { nil }
        }

        #expect(cards.map(\.file.origin) == [.edited, .created])
        #expect(cards.map(\.file.name) == ["CSVExport.swift", "CSVQuotingTests.swift"])
        guard cards.count == 2, case .edit(let change) = cards[0].file.snapshot,
              case .content(let content, isTruncated: false) = cards[1].file.snapshot else {
            Issue.record("卡片沒有快照")
            return
        }
        #expect(change.addedLines == 1)
        #expect(change.removedLines == 1)
        #expect(content.hasPrefix("import Testing\n"))
    }
}
