import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的檔案情境：ledger 的 agent 改了一個檔、新建了一個測試檔(#224),讀了兩張圖(#225:一張小圖自動載入縮圖，
/// 一張超過 8 MiB 的掃描檔等使用者點擊)。
@Suite("Demo 主機的檔案卡片")
struct DemoAgentFilesTests {
    static func ledgerCards() async throws -> [AgentFileCard] {
        let reader = TranscriptReader(channel: DemoHost())
        let file = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
        return Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:))).compactMap { item in
            if case .agentFile(let card) = item { card } else { nil }
        }
    }

    static let scope = HostFileAccessScope(workingDirectories: ["/Users/demo/ledger"], mentionedPaths: [])

    @Test("ledger 的對話有修改與新建的檔案卡片，內容來自對話紀錄")
    func ledgerHasEditAndCreateCards() async throws {
        let cards = try await Self.ledgerCards().filter { $0.file.kind != .image }

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

    @Test("ledger 讀了兩張圖：預覽圖從 Demo 主機自動載入(PNG),掃描檔超過 8 MiB 等點擊、點了才載入")
    func ledgerImagesLoadFromTheDemoHost() async throws {
        let images = try await Self.ledgerCards().filter { $0.file.origin == .readImage }.map(\.file)
        #expect(images.map(\.name) == ["export-preview.png", "statement-scan.png"])
        let loader = HostFileLoader(fetcher: DemoHostFileFetcher())

        guard images.count == 2, case .loaded(let preview, _) = await loader.load(images[0].path, scope: Self.scope) else {
            Issue.record("預覽圖沒有載入")
            return
        }
        #expect(preview.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(preview.count == images[0].byteCount)
        guard case .overAutomaticLimit(let size) = await loader.load(images[1].path, scope: Self.scope) else {
            Issue.record("掃描檔應該等點擊")
            return
        }
        #expect(size > HostFileFetchLimits.automaticLoad)
        #expect(size == images[1].byteCount)
        guard case .loaded(let scan, _) = await loader.load(images[1].path, scope: Self.scope, userRequested: true) else {
            Issue.record("點擊後沒有載入")
            return
        }
        #expect(scan.count == size)
    }

    @Test("Demo 主機的取檔：沒有的檔案是缺檔")
    func missingFile() async throws {
        let loader = HostFileLoader(fetcher: DemoHostFileFetcher())
        #expect(await loader.load("/Users/demo/ledger/docs/none.png", scope: Self.scope) == .missing)
    }
}
