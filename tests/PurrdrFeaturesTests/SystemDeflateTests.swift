import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

#if os(macOS)
/// iOS 的原始 DEFLATE(系統 Compression)包成 gzip 後，標準 gzip 解得開(#79)。
@Suite("系統 DEFLATE")
struct SystemDeflateTests {
    @Test("文字檔以系統 DEFLATE 包成 gzip:標準 gzip 解壓與原檔相同，而且明顯變小")
    func standardGzipDecompresses() throws {
        let log = Data((0..<500_000).map { UInt8(97 + ($0 / 3) % 26) })

        let gzip = try #require(Gzip.encode(log, using: SystemDeflate()))

        #expect(try StandardGzip.decompress(gzip) == log)
        #expect(gzip.count < log.count / 10)
    }
}
#endif
