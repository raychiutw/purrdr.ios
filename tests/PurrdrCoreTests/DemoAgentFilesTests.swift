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

    @Test("ledger 的回覆提到報告 PDF 與預覽圖的路徑(#229):對話紀錄出現過，只靠這點也能從 Demo 主機下載")
    func ledgerReplyMentionsHostPaths() async throws {
        let reader = TranscriptReader(channel: DemoHost())
        let file = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
        let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        let mentioned = HostFileAccessScope.mentionedPaths(in: items)

        #expect(mentioned.isSuperset(of: [DemoHostFileFetcher.reportPath, "/Users/demo/ledger/docs/export-preview.png"]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "purrdr-demo-mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: DemoHostFileFetcher(), directory: directory)
        let onlyMentioned = HostFileAccessScope(workingDirectories: [], mentionedPaths: mentioned)
        guard case .downloaded(let report, _) = await downloader.download(DemoHostFileFetcher.reportPath, scope: onlyMentioned) else {
            Issue.record("提到的 PDF 沒有下載")
            return
        }
        #expect(try Data(contentsOf: report).prefix(5) == Data("%PDF-".utf8))
    }

    @Test("ledger 的對話有修改與新建的檔案卡片，內容來自對話紀錄")
    func ledgerHasEditAndCreateCards() async throws {
        let cards = try await Self.ledgerCards().filter { $0.file.kind != .image }

        #expect(cards.map(\.file.origin) == [.edited, .created, .created, .created])
        #expect(cards.map(\.file.name) == ["CSVExport.swift", "CSVQuotingTests.swift", "history.csv", "draft.csv"])
        guard cards.count == 4, case .edit(let change) = cards[0].file.snapshot,
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

    @Test("點開 ledger 的檔案(#228):測試檔下載成同內容的檔案，匯出檔超過 25 MiB,草稿已刪掉;另有一份 PDF 報告")
    func ledgerFilesOpenFromTheDemoHost() async throws {
        let files = try await Self.ledgerCards().filter { !$0.file.isImageFromAgent }.map(\.file)
        let directory = FileManager.default.temporaryDirectory.appending(path: "purrdr-demo-opens-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: DemoHostFileFetcher(), directory: directory)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.path) })

        guard case .downloaded(let tests, _) = await downloader.download(try #require(byName["CSVQuotingTests.swift"]), scope: Self.scope) else {
            Issue.record("測試檔沒有下載"); return
        }
        #expect(try String(contentsOf: tests, encoding: .utf8).hasPrefix("import Testing\n"))
        guard case .downloaded = await downloader.download(try #require(byName["CSVExport.swift"]), scope: Self.scope) else {
            Issue.record("修改的檔案沒有下載"); return
        }
        guard case .tooLarge(let size) = await downloader.download(try #require(byName["history.csv"]), scope: Self.scope) else {
            Issue.record("匯出檔應該超過上限"); return
        }
        #expect(size > HostFileFetchLimits.maximumSize)
        #expect(await downloader.download(try #require(byName["draft.csv"]), scope: Self.scope) == .missing)
        guard case .downloaded(let report, _) = await downloader.download(DemoHostFileFetcher.reportPath, scope: Self.scope) else {
            Issue.record("PDF 沒有下載"); return
        }
        #expect(try Data(contentsOf: report).prefix(5) == Data("%PDF-".utf8))
    }

    @Test("Demo 主機的取檔：沒有的檔案是缺檔")
    func missingFile() async throws {
        let loader = HostFileLoader(fetcher: DemoHostFileFetcher())
        #expect(await loader.load("/Users/demo/ledger/docs/none.png", scope: Self.scope) == .missing)
    }
}
