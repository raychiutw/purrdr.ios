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
        guard let deflated = deflate.deflate(data) else { return nil }
        // ID1 ID2、CM = 8(DEFLATE)、無旗標、MTIME = 0、XFL = 0、OS = 255(未知)。
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(deflated)
        appendLittleEndian(CRC32.checksum(data), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &output)
        return output
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

/// CRC-32(IEEE 802.3,gzip 用的那個)。
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
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

    /// 已知的壓縮格式(副檔名，小寫):再壓也不會變小。
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
