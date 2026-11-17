import Foundation
import PurrdrCore

/// 系統 Compression 的原始 DEFLATE(檔案上傳的 gzip 傳輸，#79)。
public struct SystemDeflate: RawDeflate {
    public init() {}

    public func deflate(_ data: Data) -> Data? {
        nil
    }
}
