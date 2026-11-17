import Foundation

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

    /// 已知的壓縮格式(副檔名，小寫):再壓也不會變小。
    /// 選法：內容本身已壓縮的常見格式(封存、圖片、影音、zip 包裝的文件與安裝檔),票上列的之外補上同類。
    static let compressedExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "br",
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif",
        "mp3", "m4a", "aac", "mp4", "mov", "m4v", "mkv", "webm",
        "pdf", "docx", "xlsx", "pptx", "jar", "apk", "ipa", "dmg",
    ]

    /// 上傳到資料夾的一般檔案：已知壓縮格式(依副檔名)照原樣傳;gzip 後沒有至少小 10% 也照原樣傳。
    public static func prepare(_ data: Data, named name: String, deflate: (any RawDeflate)?) -> UploadTransfer {
        let identity = UploadTransfer(encoding: .identity, payload: data)
        let fileExtension = name.contains(".") ? name.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        guard let deflate, !compressedExtensions.contains(fileExtension),
              let gzip = Gzip.encode(data, using: deflate), gzip.count * 10 <= data.count * 9 else { return identity }
        return UploadTransfer(encoding: .gzip, payload: gzip)
    }
}
