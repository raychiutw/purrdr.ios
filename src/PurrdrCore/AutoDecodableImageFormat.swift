import Foundation

/// 可零點擊自動解碼的圖片格式(#579)。看檔案開頭的 magic bytes，不看副檔名;其他格式要使用者點擊才解碼。
public enum AutoDecodableImageFormat: Sendable, Equatable, CaseIterable {
    case png, jpeg, heic, gif, webp

    /// 判斷內容開頭屬於哪一種;不是這五種(含空資料)回 `nil`。
    public static func detect(_ header: Data) -> AutoDecodableImageFormat? {
        let bytes = Array(header.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return .gif }
        guard bytes.count == 12 else { return nil }
        if bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) { return .webp }
        if bytes[4..<8].elementsEqual("ftyp".utf8), heicBrands.contains(String(decoding: bytes[8..<12], as: UTF8.self)) { return .heic }
        return nil
    }

    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs"]
}
