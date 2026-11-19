import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 檔案卡片的顯示規則(#224)。
@Suite("檔案卡片顯示")
struct AgentFileCardDisplayTests {
    static let edit = AgentFileReference(origin: .edited, path: "/Users/demo/ledger/Sources/CSVExport.swift", snapshot: .edit(AgentFileEdit(
        hunks: [AgentFileHunk(oldStart: 3, oldLines: 2, newStart: 3, newLines: 2, lines: [" enum CSVExport {", "-    let a = 1", "+    let a = 2"])],
        addedLines: 1, removedLines: 1
    )))

    @Test("修改摘要：hunk 標頭加上每一行，依 +／- 分種類;摘要列有動作、類型與增刪行數")
    func editLines() {
        let display = AgentFileCardDisplay(file: Self.edit)

        #expect(display.lines.map(\.kind) == [.hunkHeader, .context, .removed, .added])
        #expect(display.lines.first?.text == "@@ -3,2 +3,2 @@")
        #expect(display.summary == "Edited · Code · +1 −1")
    }

    @Test("VoiceOver 標題念動作、檔名、類型、增刪行數與路徑")
    func accessibilityLabel() {
        #expect(AgentFileCardDisplay(file: Self.edit).accessibilityLabel
            == "Edited file CSVExport.swift, Code, 1 lines added, 1 removed, Path: /Users/demo/ledger/Sources/CSVExport.swift")
    }

    @Test("寫入內容超過 8 行折疊，展開後全部顯示;截斷的內容有說明")
    func longContentFolds() {
        let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let display = AgentFileCardDisplay(file: AgentFileReference(origin: .created, path: "/tmp/a.txt", snapshot: .content(text, isTruncated: true)))

        #expect(display.isFoldable)
        #expect(display.visibleLines(expanded: false).count == 8)
        #expect(display.visibleLines(expanded: true).count == 12)
        #expect(display.truncationNote == "Content truncated at 20,000 characters")
        #expect(display.copyableContent == text)
    }

    @Test("圖片卡片(#225):標題念讀取與大小;超過 8 MiB 顯示大小並提供載入，其他原因各有說明")
    func imageCard() {
        let image = AgentFileReference(origin: .readImage, path: "/Users/demo/ledger/docs/shot.png", byteCount: 2_048)
        #expect(AgentFileCardDisplay(file: image).summary == "Read · Image · 2 KB")
        #expect(AgentFileCardDisplay(file: AgentFileReference(origin: .toolImage, path: "/tmp/a.png")).originText == "Captured")

        let over = AgentImageCardDisplay(state: .overAutomaticLimit(size: 9 * 1024 * 1024))
        #expect(over.note == "9.4 MB · Not loaded automatically")
        #expect(over.offersLoad)
        #expect(AgentImageCardDisplay(state: .missing).note == "This file is no longer on the host.")
        #expect(AgentImageCardDisplay(state: .failed).offersRetry)
        #expect(AgentImageCardDisplay(state: .loading).note == nil)
    }

    @Test("點開檔案(#228):下載中顯示進度與取消;超過 25 MiB、已刪除、主機不支援各有說明;下載好了可分享")
    func openStates() {
        let downloading = AgentFileOpenDisplay(state: .downloading(received: 1_024 * 1_024, total: 4 * 1_024 * 1_024))
        #expect(downloading.progress == 0.25)
        #expect(downloading.offersCancel)
        #expect(!downloading.offersOpen)
        #expect(AgentFileOpenDisplay(state: .downloading(received: 0, total: 0)).progress == nil)

        #expect(AgentFileOpenDisplay(state: .tooLarge(size: 30 * 1024 * 1024)).note == "Too large to open here (31.5 MB). Open it on the host.")
        #expect(AgentFileOpenDisplay(state: .missing).note == "This file is no longer on the host.")
        #expect(AgentFileOpenDisplay(state: .unsupported).note == "Opening files isn’t available for this host yet.")
        #expect(AgentFileOpenDisplay(state: .failed).offersRetry)
        #expect(AgentFileOpenDisplay(state: nil).offersOpen)

        let ready = AgentFileOpenDisplay(state: .ready(URL(filePath: "/tmp/report.pdf")))
        #expect(ready.offersOpen)
        #expect(ready.shareableFile == URL(filePath: "/tmp/report.pdf"))
        #expect(ready.note == nil)
    }
}
