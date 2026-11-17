import Foundation
import PurrdrCore

/// 系統 Compression 的原始 DEFLATE(檔案上傳的 gzip 傳輸，#79)。
///
/// `NSData.CompressionAlgorithm.zlib` 是不含 zlib 標頭的原始 DEFLATE(RFC 1951)。
public struct SystemDeflate: RawDeflate {
    public init() {}

    public func deflate(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }
}
