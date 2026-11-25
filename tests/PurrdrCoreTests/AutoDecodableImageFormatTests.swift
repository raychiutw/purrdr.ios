import Foundation
import PurrdrCore
import Testing

/// 自動解碼只限 PNG／JPEG／HEIC／GIF／WebP(#579):格式看內容，不看副檔名。
@Suite("自動解碼的圖片格式判斷")
struct AutoDecodableImageFormatTests {
    static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
    static func pad(_ head: [UInt8]) -> Data { Data(head + [UInt8](repeating: 0, count: 32)) }

    @Test("常見格式依 magic bytes 辨識", arguments: [
        (pad([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), AutoDecodableImageFormat.png),
        (pad([0xFF, 0xD8, 0xFF, 0xE0]), .jpeg),
        (pad(ascii("GIF87a")), .gif),
        (pad(ascii("GIF89a")), .gif),
        (pad(ascii("RIFF") + [0, 0, 0, 0] + ascii("WEBP")), .webp),
        (pad([0, 0, 0, 0x18] + ascii("ftypheic")), .heic),
        (pad([0, 0, 0, 0x18] + ascii("ftypheix")), .heic),
    ])
    func detectsCommonFormats(sample: (Data, AutoDecodableImageFormat)) {
        #expect(AutoDecodableImageFormat.detect(sample.0) == sample.1)
    }

    @Test("其他格式與非圖片內容不自動解碼", arguments: [
        pad(ascii("BM")),                                             // BMP
        pad(ascii("II*") + [0]),                                      // TIFF
        pad([0, 0, 1, 0]),                                            // ICO
        pad(ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE")),            // RIFF 但不是 WebP
        pad([0, 0, 0, 0x18] + ascii("ftypavif")),                     // AVIF
        pad([0, 0, 0, 0x18] + ascii("ftypqt  ")),                     // QuickTime 影片
        pad(ascii("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")),    // SVG
        pad(ascii("%PDF-1.7")),                                       // PDF
        Data(),
        Data([0x89, 0x50]),                                           // 太短的 PNG 開頭
    ])
    func rejectsEverythingElse(sample: Data) {
        #expect(AutoDecodableImageFormat.detect(sample) == nil)
    }
}
