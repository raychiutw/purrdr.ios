import CoreGraphics
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

    @Test("VoiceOver 標題念動作、檔名、類型、增刪行數(路徑在揭露控制)")
    func accessibilityLabel() {
        #expect(AgentFileCardDisplay(file: Self.edit).accessibilityLabel
            == "Edited file CSVExport.swift, Code, 1 lines added, 1 removed")
    }

    @Test("截斷的內容有說明;可複製的內容是全部的行")
    func contentNotes() {
        let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let display = AgentFileCardDisplay(file: AgentFileReference(origin: .created, path: "/tmp/a.txt", snapshot: .content(text, isTruncated: true)))

        #expect(display.lines.count == 12)
        #expect(display.truncationNote == "Content truncated at 20,000 characters")
        #expect(display.copyableContent == text)
    }

    @Test("緊湊單列(#465):副標依狀態是摘要、下載進度、說明;右側動作是載入、取消、重試或沒有")
    func compactRow() {
        let pdf = AgentFileReference(origin: .created, path: "/Users/demo/ledger/report.pdf", byteCount: 2_400_000)
        let scan = AgentFileReference(origin: .readImage, path: "/Users/demo/ledger/scan.png", byteCount: 9_000_000)
        let zip = AgentFileReference(origin: .created, path: "/Users/demo/ledger/export.zip", byteCount: 14_000_000)

        let plain = AgentFileRowDisplay(file: pdf, thumbnail: .loading, open: nil)
        #expect(plain.subtitle == "Created · PDF · 2.4 MB")
        #expect(plain.action == .none)
        #expect(plain.progress == nil)

        let over = AgentFileRowDisplay(file: scan, thumbnail: .overAutomaticLimit(size: 9 * 1024 * 1024), open: nil)
        #expect(over.subtitle == "Read · Image · 9.4 MB · Not loaded automatically")
        #expect(over.action == .load)

        let downloading = AgentFileRowDisplay(file: zip, thumbnail: nil, open: .downloading(received: 6_100_000, total: 14_000_000))
        #expect(downloading.subtitle == "Downloading · 6.1 MB / 14 MB")
        #expect(downloading.action == .cancel)
        #expect(downloading.progress.map { (0.43...0.44).contains($0) } == true)

        let missing = AgentFileRowDisplay(file: zip, thumbnail: nil, open: .missing)
        #expect(missing.subtitle == "This file is no longer on the host.")
        #expect(missing.action == .none)
        #expect(AgentFileRowDisplay(file: zip, thumbnail: nil, open: .failed).action == .retry)
        #expect(AgentFileRowDisplay(file: pdf, thumbnail: .failed, open: nil).action == .retry)
    }

    @Test("縮圖框的角標:副檔名大寫(最多 5 字),沒有副檔名用空字串")
    func extensionBadge() {
        #expect(AgentFileRowDisplay(file: AgentFileReference(origin: .created, path: "/a/export.zip"), thumbnail: nil, open: nil).badge == "ZIP")
        #expect(AgentFileRowDisplay(file: AgentFileReference(origin: .created, path: "/a/Makefile"), thumbnail: nil, open: nil).badge == "")
    }

    @Test("圖片卡片(#225):標題念讀取與大小;超過 8 MiB 顯示大小並提供載入，其他原因各有說明")
    func imageCard() {
        let image = AgentFileReference(origin: .readImage, path: "/Users/demo/ledger/docs/shot.png", byteCount: 2_500_000)
        // KB 級的單位寫法(KB／kB)依系統版本不同;用 MB 級，與其他大小斷言一致。
        #expect(AgentFileCardDisplay(file: image).summary == "Read · Image · 2.5 MB")
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

    @Test("縮圖規則(#427):PDF 與圖片檔自動縮圖;文字與程式碼沿用內容摘要;其他種類顯示類型圖示")
    func thumbnailPresentation() {
        func presentation(_ name: String, snapshot: AgentFileSnapshot? = nil, origin: AgentFileReference.Origin = .created) -> AgentFileCardDisplay.Preview {
            AgentFileCardDisplay(file: AgentFileReference(origin: origin, path: "/Users/demo/ledger/\(name)", snapshot: snapshot)).preview
        }
        #expect(presentation("report.pdf") == .thumbnail)
        #expect(presentation("chart.png") == .thumbnail)
        #expect(presentation("a.swift", snapshot: .content("let a = 1", isTruncated: false)) == .snapshot)
        #expect(presentation("a.csv", snapshot: .content("a,b", isTruncated: false)) == .snapshot)
        #expect(presentation("backup.zip") == .typeIcon)
        #expect(presentation("history.csv") == .typeIcon)
        #expect(AgentFileCardDisplay(file: AgentFileReference(origin: .created, path: "/a/backup.zip")).symbol == "doc.zipper")
        #expect(AgentFileCardDisplay(file: AgentFileReference(origin: .created, path: "/a/song.mp3")).symbol == "waveform")
    }

    @Test("縮圖區的說明(#427):超過 8 MiB 顯示大小與載入，超過 25 MiB 無法開啟，缺檔說已找不到")
    func thumbnailNotes() {
        let over = AgentFileThumbnailDisplay(state: .overAutomaticLimit(size: 9 * 1024 * 1024))
        #expect(over.note == "9.4 MB · Not loaded automatically")
        #expect(over.offersLoad)
        #expect(AgentFileThumbnailDisplay(state: .tooLarge(size: 30 * 1024 * 1024)).note == "Too large to open here (31.5 MB). Open it on the host.")
        #expect(AgentFileThumbnailDisplay(state: .missing).note == "This file is no longer on the host.")
        #expect(AgentFileThumbnailDisplay(state: .loading).note == nil)
        #expect(AgentFileThumbnailDisplay(state: .failed).offersRetry)
    }

    @Test("PDF 第一頁縮圖(#427):解出尺寸合理的圖;不是 PDF 的資料解不出")
    func pdfFirstPageThumbnail() async throws {
        let pdf = Self.makePDF(width: 612, height: 792)
        let decoded = try #require(await AgentImageDecoder.decodeThumbnail(pdf, kind: .pdf, maxPixels: 512))
        #expect(max(decoded.image.width, decoded.image.height) == 512)
        #expect(decoded.image.width < decoded.image.height)
        #expect(await AgentImageDecoder.decodeThumbnail(Data("not a pdf".utf8), kind: .pdf, maxPixels: 512) == nil)
    }

    static func makePDF(width: CGFloat, height: CGFloat) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
