import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 不管輸入都回固定「壓縮結果」的原始 DEFLATE 替身(決定要不要 gzip 只看大小)。
struct FixedDeflate: RawDeflate {
    let output: Data?

    func deflate(_ data: Data) -> Data? { output }
}

/// 上傳的傳輸編碼(#79):gzip 封裝與何時用 gzip。
@Suite("上傳的傳輸編碼")
struct UploadTransferTests {
    static let text = Data(String(repeating: "purrdr upload log line\n", count: 44).utf8.prefix(1_000))

    @Test("gzip 封裝:標頭是 1f 8b 08、結尾是 CRC32 與原始長度(little-endian)")
    func gzipHeaderAndTrailer() throws {
        let deflated = Data([0xAA, 0xBB, 0xCC])

        let gzip = try #require(Gzip.encode(Data("123456789".utf8), using: FixedDeflate(output: deflated)))

        #expect(gzip.count == 10 + 3 + 8)
        #expect(Array(gzip.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00])
        #expect(Data(gzip.dropFirst(10).prefix(3)) == deflated)
        // CRC-32("123456789") = 0xCBF43926(RFC 1952 的 CRC 標準檢查值)。
        #expect(Array(gzip.suffix(8)) == [0x26, 0x39, 0xF4, 0xCB, 0x09, 0x00, 0x00, 0x00])
    }

    @Test("一般檔案壓縮後至少小 10% 時用 gzip")
    func gzipWhenAtLeastTenPercentSmaller() throws {
        // 1,000 bytes:gzip 900 bytes(恰好小 10%)用 gzip;901 bytes 照原樣傳。
        let exactlyTenPercent = UploadTransfer.prepare(Self.text, named: "build.log", deflate: FixedDeflate(output: Data(count: 882)))
        let notEnough = UploadTransfer.prepare(Self.text, named: "build.log", deflate: FixedDeflate(output: Data(count: 883)))

        #expect(exactlyTenPercent.encoding == .gzip)
        #expect(exactlyTenPercent.payload.count == 900)
        #expect(Array(exactlyTenPercent.payload.prefix(2)) == [0x1F, 0x8B])
        #expect(notEnough == UploadTransfer(encoding: .identity, payload: Self.text))
    }

    @Test("已知壓縮格式(依副檔名，不分大小寫)照原樣傳", arguments: [
        "photo.JPG", "a.jpeg", "b.png", "c.heic", "d.webp", "e.mp4", "f.mov", "g.pdf", "h.zip", "i.gz", "j.tar.gz",
    ])
    func compressedFormatsStayIdentity(name: String) {
        let transfer = UploadTransfer.prepare(Self.text, named: name, deflate: FixedDeflate(output: Data(count: 1)))

        #expect(transfer == UploadTransfer(encoding: .identity, payload: Self.text))
    }

    @Test("沒有壓縮實作或壓縮失敗：照原樣傳")
    func noDeflateStaysIdentity() {
        #expect(UploadTransfer.prepare(Self.text, named: "a.txt", deflate: nil) == UploadTransfer(encoding: .identity, payload: Self.text))
        #expect(UploadTransfer.prepare(Self.text, named: "a.txt", deflate: FixedDeflate(output: nil))
            == UploadTransfer(encoding: .identity, payload: Self.text))
    }
}

#if os(macOS)
/// 以系統 `gzip` 驗證封裝(標準工具解得開)。
@Suite("gzip 封裝與標準 gzip")
struct GzipStandardToolTests {
    @Test("可攜核心產生的 gzip 能被標準 gzip 解壓成原檔(含空檔與 1 MB)", arguments: [0, 9, 1_000_000])
    func standardGzipDecompresses(size: Int) throws {
        let original = Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 / 7) &* 13) })

        let gzip = try #require(Gzip.encode(original, using: StandardRawDeflate()))

        #expect(try StandardGzip.decompress(gzip) == original)
    }
}
#endif
