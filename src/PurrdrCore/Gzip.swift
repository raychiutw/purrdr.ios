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
