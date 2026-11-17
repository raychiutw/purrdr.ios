#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import PurrdrFeatures
import Testing
import UniformTypeIdentifiers
import Vision

/// 附圖送出前的手機端前處理：大小上限(#78)。樣本是 `Resources/images/` 的合成影像(產生方式見 make-samples.py)。
@Suite("圖片前處理的大小上限")
struct ImagePreparationTests {
    /// 目標大小 500 KB 與長邊下限 1280px(#78 定案值，以獨立字面值斷言)。
    static let targetBytes = 500 * 1024
    static let minimumLongSide = 1280

    static func sample(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/images"))
        return try Data(contentsOf: url)
    }

    static func longSide(_ prepared: ImagePreparation.Prepared) -> Int {
        max(prepared.width, prepared.height)
    }

    static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
    }

    /// 以系統文字辨識讀出的所有文字(一行一筆)。
    static func recognizedText(_ jpeg: Data) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: jpeg)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    @Test("大張照片：壓到目標大小以內，長邊不低於下限")
    func largePhotoFitsTarget() throws {
        let prepared = try #require(ImagePreparation.prepare(Self.sample("photo-4032x3024.jpg")))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        #expect(Self.longSide(prepared) >= Self.minimumLongSide)
        #expect(Self.longSide(prepared) <= 2048)
        #expect(Self.isJPEG(prepared.jpeg))
        // 長寬比不變(4:3)。
        #expect(abs(Double(prepared.width) / Double(prepared.height) - 4.0 / 3.0) < 0.01)
    }

    @Test("文字截圖：壓到目標大小以內，文字仍可辨識")
    func screenshotStaysReadable() async throws {
        let prepared = try #require(ImagePreparation.prepare(Self.sample("screenshot-1290x2796.png")))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        #expect(Self.longSide(prepared) >= Self.minimumLongSide)
        let text = try await Self.recognizedText(prepared.jpeg)
        for phrase in ["PX-4821", "ImageCodec.swift", "17:45", "3,915.62", "Purrdr Sample Chat"] {
            #expect(text.contains(phrase), "壓縮後讀不出「\(phrase)」")
        }
    }

    @Test("已小於目標大小的圖片：維持品質 0.8 與解析度")
    func smallImageKeepsQualityAndResolution() throws {
        let prepared = try #require(ImagePreparation.prepare(TestImage.png(width: 1600, height: 900)))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        #expect(prepared.quality == 0.8)
        #expect(prepared.width == 1600)
        #expect(prepared.height == 900)
    }

    @Test("怎麼壓都超過目標的圖片：長邊停在下限，不再縮小")
    func incompressibleImageStopsAtMinimumSize() throws {
        let prepared = try #require(ImagePreparation.prepare(NoiseImage.png(width: 3000, height: 2000)))

        #expect(Self.longSide(prepared) == Self.minimumLongSide)
    }
}

/// 每個像素獨立的亂數(固定種子):JPEG 幾乎壓不小。
enum NoiseImage {
    static func png(width: Int, height: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// 暫時的量測(#78 定案參數用，定案後移除):每個長邊 × 品質的輸出大小與文字辨識結果。
@Suite("圖片前處理量測(暫時)")
struct ImagePreparationMeasurement {
    static func encode(_ data: Data, longSide: Int, quality: Double) -> (bytes: Int, jpeg: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output.length, output as Data)
    }

    @Test("輸出大小表")
    func report() async throws {
        let phrases = ["PX-4821", "ImageCodec.swift", "17:45", "3,915.62", "Purrdr Sample Chat"]
        for name in ["photo-4032x3024.jpg", "screenshot-1290x2796.png"] {
            let data = try ImagePreparationTests.sample(name)
            for longSide in [2048, 1792, 1536, 1280] {
                var cells: [String] = []
                for quality in [0.8, 0.7, 0.6, 0.5, 0.4, 0.3] {
                    guard let encoded = Self.encode(data, longSide: longSide, quality: quality) else { continue }
                    var cell = "q\(quality)=\(encoded.bytes / 1024)K"
                    if name.hasPrefix("screenshot") {
                        let text = (try? await ImagePreparationTests.recognizedText(encoded.jpeg)) ?? ""
                        cell += "(ocr \(phrases.filter { text.contains($0) }.count)/\(phrases.count))"
                    }
                    cells.append(cell)
                }
                print("MEASURE \(name) \(longSide) \(cells.joined(separator: " "))")
            }
        }
    }
}
#endif
