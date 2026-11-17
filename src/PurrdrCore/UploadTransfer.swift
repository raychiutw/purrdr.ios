import Foundation

/// 原始 DEFLATE(RFC 1951)壓縮，由平台注入(iOS 用系統 Compression)。
public protocol RawDeflate: Sendable {
    /// 壓縮失敗回 `nil`。
    func deflate(_ data: Data) -> Data?
}

/// gzip 封裝(RFC 1952):標頭、原始 DEFLATE、CRC32、原始長度。
public enum Gzip {
    /// 壓縮失敗回 `nil`。
    public static func encode(_ data: Data, using deflate: any RawDeflate) -> Data? {
        nil
    }
}

/// 上傳時 bytes 在 stdin 上的編碼。
public enum UploadTransferEncoding: String, Sendable, Equatable {
    case identity
    case gzip
}

/// 一次上傳實際送出的 bytes 與編碼。
public struct UploadTransfer: Sendable, Equatable {
    public var encoding: UploadTransferEncoding
    public var payload: Data

    public init(encoding: UploadTransferEncoding, payload: Data) {
        self.encoding = encoding
        self.payload = payload
    }

    /// 上傳到資料夾的一般檔案：已知壓縮格式(依副檔名)照原樣傳;gzip 後沒有至少小 10% 也照原樣傳。
    public static func prepare(_ data: Data, named name: String, deflate: (any RawDeflate)?) -> UploadTransfer {
        UploadTransfer(encoding: .identity, payload: data)
    }
}
