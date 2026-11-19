import Foundation
import PurrdrCore

/// Demo 主機的主機取檔(#225、#228):ledger 的 agent 讀過的兩張圖——小的匯出預覽(自動載入縮圖)與超過 8 MiB 的掃描檔(等點擊);
/// 寫過的檔案(點開以 QuickLook 預覽)、匯出後超過 25 MiB 的 CSV、已刪掉的草稿，與一份 PDF 報告。
/// 內容在記憶體裡產生(不連網路、不帶資源檔)。
public struct DemoHostFileFetcher: HostFileFetching {
    static let previewPath = "/Users/demo/ledger/docs/export-preview.png"
    static let scanPath = "/Users/demo/ledger/docs/statement-scan.png"
    static let exportPath = "/Users/demo/ledger/Sources/Ledger/CSVExport.swift"
    static let quotingTestsPath = "/Users/demo/ledger/Tests/LedgerTests/CSVQuotingTests.swift"
    /// Agent 寫了開頭幾行，之後以指令附加全部紀錄：超過點擊開啟的上限。
    static let historyPath = "/Users/demo/ledger/exports/history.csv"
    static let historySize = 31_457_280
    /// Agent 寫了又刪掉：主機上已沒有這個檔案。
    static let draftPath = "/Users/demo/ledger/exports/draft.csv"
    /// 匯出說明的 PDF(訊息內路徑可點，#229)。
    public static let reportPath = "/Users/demo/ledger/docs/export-report.pdf"

    public init() {}

    static func file(at path: String) -> Data? {
        switch path {
        case previewPath: DemoImages.preview
        case scanPath: DemoImages.scan
        case exportPath: Data(DemoTranscripts.exportSource.utf8)
        case quotingTestsPath: Data(DemoTranscripts.quotingTests.utf8)
        case reportPath: DemoDocuments.report
        default: nil
        }
    }

    /// 檔案大小。圖片由尺寸算出，查狀態時不必先產生內容(掃描檔約 8.8 MiB,等使用者點擊才產生)。
    static func size(at path: String) -> Int? {
        switch path {
        case previewPath: DemoImages.encodedSize(width: DemoImages.previewSize.width, height: DemoImages.previewSize.height)
        case scanPath: DemoImages.encodedSize(width: DemoImages.scanSize.width, height: DemoImages.scanSize.height)
        default: file(at: path)?.count
        }
    }

    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        if target.path == Self.historyPath { return .tooLarge(size: Self.historySize) }
        guard let size = Self.size(at: target.path) else { return .missing }
        return .file(version: Self.version(ofSize: size), size: size)
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        guard let data = Self.file(at: target.path) else { throw HostFileFetchError.unavailable(.missing) }
        guard Self.version(ofSize: data.count) == version else { throw HostFileFetchError.changed }
        let start = min(max(offset, 0), data.count)
        return data.subdata(in: start..<min(start + length, data.count))
    }

    private static func version(ofSize size: Int) -> HostFileVersion {
        HostFileVersion(checksum: "demo:\(size)")
    }
}

/// Demo 的文件。
enum DemoDocuments {
    /// 一頁的 PDF(標題與兩行說明);xref 位移依內容計算。
    static let report: Data = {
        let text = "BT /F1 18 Tf 72 720 Td (Ledger CSV export) Tj /F1 12 Tf 0 -28 Td (Columns: date, amount, note.) Tj "
            + "0 -18 Td (Notes with commas are quoted per RFC 4180.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }()
}

/// Demo 的 PNG:RGB、未壓縮的 deflate 區塊(可攜核心沒有壓縮器)。
enum DemoImages {
    /// 匯出預覽(480×300,約 420 KB):藍綠漸層上的三條「欄位」色帶。
    static let preview = png(width: previewSize.width, height: previewSize.height) { y in
        let shade = UInt8(150 + y * 80 / 300)
        return (0..<previewSize.width).flatMap { x -> [UInt8] in
            let band = (x / 160) % 3
            return band == 0 ? [40, shade, 200] : band == 1 ? [60, 200, shade] : [shade, 120, 60]
        }
    }

    /// 掃描檔(1920×1600,約 8.8 MiB,超過自動載入上限):紙色底與橫線。只有兩種列，先各排好一列再重複(Debug 下也不吃 CPU)。
    static let scan: Data = {
        let line = row(repeating: [180, 190, 200], width: scanSize.width)
        let paper = row(repeating: [246, 242, 232], width: scanSize.width)
        return png(width: scanSize.width, height: scanSize.height) { y in y % 48 < 2 ? line : paper }
    }()

    private static func row(repeating pixel: [UInt8], width: Int) -> [UInt8] {
        Array([[UInt8]](repeating: pixel, count: width).joined())
    }

    static let previewSize = (width: 480, height: 300)
    static let scanSize = (width: 1920, height: 1600)

    /// `png(width:height:)` 產生的檔案大小(對話紀錄的 `originalSize` 用，不必先產生圖片)。
    static func encodedSize(width: Int, height: Int) -> Int {
        let raw = height * (width * 3 + 1)
        let blocks = (raw + 65_534) / 65_535
        return 8 + (12 + 13) + (12 + 2 + raw + blocks * 5 + 4) + 12
    }

    /// - Parameter row: 第 y 列的 RGB bytes(`width * 3` 個)。
    static func png(width: Int, height: Int, row: (Int) -> [UInt8]) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 3 + 1))
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: row(y))
        }
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header += [8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + chunk("IHDR", header) + chunk("IDAT", storedZlib(raw)) + chunk("IEND", Data())
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        data += typed
        data.appendBigEndian(CRC32.checksum(typed))
        return data
    }

    /// zlib 包住的 stored 區塊(每塊最多 65,535 bytes)與 Adler-32。
    private static func storedZlib(_ raw: [UInt8]) -> Data {
        var data = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let count = min(65_535, raw.count - offset)
            let isFinal = offset + count == raw.count
            data.append(isFinal ? 1 : 0)
            data += [UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            raw.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(rebasing: $0[offset..<offset + count])) }
            offset += count
        } while offset < raw.count
        data.appendBigEndian(adler32(raw))
        return data
    }

    /// Adler-32:每 5,552 bytes 才取一次餘數(zlib 的 NMAX,累加不會溢位)。
    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        bytes.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let end = min(start + 5_552, buffer.count)
                for index in start..<end {
                    low &+= UInt32(buffer[index])
                    high &+= low
                }
                low %= 65_521
                high %= 65_521
                start = end
            }
        }
        return high << 16 | low
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
