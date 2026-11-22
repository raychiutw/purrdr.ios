import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 使用者送出的檔案卡片的顯示規則(#429)。
@Suite("使用者檔案卡片顯示")
struct UserFileCardDisplayTests {
    static let csv = "/var/folders/zz/demo/T/purrdr-uploads-501/budget.csv"
    static let pdf = "/var/folders/zz/demo/T/purrdr-uploads-501/report.pdf"

    @Test("其他種類:查狀態拿到大小,顯示類型圖示與大小,可以點開")
    func plainFileShowsSize() {
        let display = UserFileCardDisplay(path: Self.csv, state: nil, info: .available(size: 2048), open: nil)

        #expect(display.name == "budget.csv")
        #expect(!display.wantsThumbnail)
        #expect(display.sizeText == Int64(2048).formatted(.byteCount(style: .file)))
        #expect(display.note == nil)
        #expect(display.canOpen)
    }

    @Test("PDF:自動縮圖,載入後的大小取自內容;超過自動載入上限只顯示大小")
    func pdfThumbnail() {
        let loaded = UserFileCardDisplay(path: Self.pdf, state: .loaded(Data(count: 900), version: HostFileVersion(checksum: "a")), info: nil, open: nil)
        let big = UserFileCardDisplay(path: Self.pdf, state: .overAutomaticLimit(size: 9_000_000), info: nil, open: nil)

        #expect(loaded.wantsThumbnail)
        #expect(loaded.size == 900)
        #expect(big.size == 9_000_000)
        #expect(big.canOpen)
    }

    @Test("主機上找不到:顯示說明、不能點開;超過 25 MiB:顯示無法開啟")
    func problems() {
        let missing = UserFileCardDisplay(path: Self.csv, state: nil, info: .missing, open: nil)
        let missingPDF = UserFileCardDisplay(path: Self.pdf, state: .missing, info: nil, open: nil)
        let huge = UserFileCardDisplay(path: Self.csv, state: nil, info: .tooLarge(size: 40_000_000), open: nil)

        #expect(missing.note == "This file is no longer on the host.")
        #expect(missingPDF.note == "This file is no longer on the host.")
        #expect(!missing.canOpen)
        #expect(huge.note == "Too large to open here. Open it on the host.")
        #expect(!huge.canOpen)
    }

    @Test("主機服務太舊或讀不到:只顯示檔名,不顯示錯誤說明")
    func unsupportedHasNoNote() {
        for info in [AgentFileLoads.Info.unsupported, .failed, .denied] {
            let display = UserFileCardDisplay(path: Self.csv, state: nil, info: info, open: nil)
            #expect(display.note == nil)
            #expect(display.sizeText == nil)
        }
    }

    @Test("下載中:顯示進度、不再接受點擊,可以取消")
    func downloading() {
        let display = UserFileCardDisplay(path: Self.csv, state: nil, info: .available(size: 100), open: .downloading(received: 25, total: 100))

        #expect(display.isDownloading)
        #expect(display.progress == 0.25)
        #expect(!display.canOpen)
    }
}
