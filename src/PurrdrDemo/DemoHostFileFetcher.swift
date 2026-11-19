import Foundation
import PurrdrCore

/// Demo 主機的主機取檔(#225):ledger 的 agent 讀過的兩張圖——小的匯出預覽(自動載入縮圖)與超過 8 MiB 的掃描檔(等點擊)。
/// 內容在記憶體裡產生(不連網路、不帶資源檔)。
public struct DemoHostFileFetcher: HostFileFetching {
    static let previewPath = "/Users/demo/ledger/docs/export-preview.png"
    static let scanPath = "/Users/demo/ledger/docs/statement-scan.png"

    public init() {}

    static func file(at path: String) -> Data? {
        switch path {
        case previewPath: DemoImages.preview
        case scanPath: DemoImages.scan
        default: nil
        }
    }

    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        guard let data = Self.file(at: target.path) else { return .missing }
        return .file(version: Self.version(of: data), size: data.count)
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        guard let data = Self.file(at: target.path) else { throw HostFileFetchError.unavailable(.missing) }
        guard Self.version(of: data) == version else { throw HostFileFetchError.changed }
        let start = min(max(offset, 0), data.count)
        return data.subdata(in: start..<min(start + length, data.count))
    }

    private static func version(of data: Data) -> HostFileVersion {
        HostFileVersion(checksum: "demo:\(data.count)")
    }
}

/// Demo 的 PNG:RGB、未壓縮的 deflate 區塊(可攜核心沒有壓縮器)。
enum DemoImages {
    /// 匯出預覽(480×300,約 420 KB):藍綠漸層上的三條「欄位」色帶。
    static let preview = png(width: previewSize.width, height: previewSize.height) { x, y in
        let band = (x / 160) % 3
        let shade = UInt8(150 + y * 80 / 300)
        return band == 0 ? (40, shade, 200) : band == 1 ? (60, 200, shade) : (shade, 120, 60)
    }

    /// 掃描檔(1920×1600,約 8.8 MiB,超過自動載入上限):紙色底與橫線。
    static let scan = png(width: scanSize.width, height: scanSize.height) { _, y in
        y % 48 < 2 ? (180, 190, 200) : (246, 242, 232)
    }

    static let previewSize = (width: 480, height: 300)
    static let scanSize = (width: 1920, height: 1600)

    /// `png(width:height:)` 產生的檔案大小(對話紀錄的 `originalSize` 用，不必先產生圖片)。
    static func encodedSize(width: Int, height: Int) -> Int {
        let raw = height * (width * 3 + 1)
        let blocks = (raw + 65_534) / 65_535
        return 8 + (12 + 13) + (12 + 2 + raw + blocks * 5 + 4) + 12
    }

    static func png(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 3 + 1))
        for y in 0..<height {
            raw.append(0)
            for x in 0..<width {
                let (red, green, blue) = pixel(x, y)
                raw += [red, green, blue]
            }
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
            data += raw[offset..<offset + count]
            offset += count
        } while offset < raw.count
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in raw {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        data.appendBigEndian(high << 16 | low)
        return data
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
