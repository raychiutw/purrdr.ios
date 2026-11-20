#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import PurrdrAgentFeatures
import PurrdrFeatures
import Testing
import UniformTypeIdentifiers

/// 附圖送出前的手機端前處理：大小上限(#78)。樣本是執行時產生的合成影像(`SyntheticImages`)。
@Suite("圖片前處理的大小上限")
struct ImagePreparationTests {
    /// 目標大小 500 KB 與長邊下限 1280px(#78 定案值，以獨立字面值斷言)。
    static let targetBytes = 500 * 1024
    static let minimumLongSide = 1280

    static func longSide(_ prepared: ImagePreparation.Prepared) -> Int {
        max(prepared.width, prepared.height)
    }

    static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
    }

    /// 截圖文字區(下方 36%,樣本的文字從 y = 1770/2796 開始)的亮度 PSNR(dB):
    /// 與原圖以同樣尺寸縮小、未經 JPEG 的結果比較。
    static func textRegionPSNR(_ jpeg: Data, original: Data) throws -> Double {
        let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let source = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(decoded.width, decoded.height),
        ]
        let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        let width = decoded.width, height = decoded.height
        let decodedPixels = try rgba(decoded, width: width, height: height)
        let referencePixels = try rgba(reference, width: width, height: height)
        // CGContext 的列由上而下;文字區是下方 36%。
        let firstRow = height * 64 / 100
        var squaredError = 0.0
        var count = 0
        for row in firstRow..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                func luma(_ pixels: [UInt8]) -> Double {
                    0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                }
                let difference = luma(decodedPixels) - luma(referencePixels)
                squaredError += difference * difference
                count += 1
            }
        }
        let meanSquaredError = max(squaredError / Double(count), 1e-9)
        return 10 * log10(255 * 255 / meanSquaredError)
    }

    static func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return pixels
    }

    @Test("大張照片：壓到目標大小以內，長邊不低於下限")
    func largePhotoFitsTarget() throws {
        let prepared = try #require(ImagePreparation.prepare(SyntheticImages.photo))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        #expect(Self.longSide(prepared) >= Self.minimumLongSide)
        #expect(Self.longSide(prepared) <= 2048)
        #expect(Self.isJPEG(prepared.jpeg))
        // 長寬比不變(4:3)。
        #expect(abs(Double(prepared.width) / Double(prepared.height) - 4.0 / 3.0) < 0.01)
        // 先降品質再縮長邊:2048px 降到 0.4 仍超過，才縮到 1792px(品質從 0.8 重試，到 0.4 才夠;CI 實測值)。
        #expect(Self.longSide(prepared) == 1792)
        #expect(prepared.quality == 0.4)
    }

    @Test("文字截圖：壓到目標大小以內，文字區與原圖差異小(文字仍可讀)")
    func screenshotStaysReadable() throws {
        let original = SyntheticImages.screenshot
        let prepared = try #require(ImagePreparation.prepare(original))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        // 先降品質：降到 0.5 就夠，不縮小解析度。
        #expect(Self.longSide(prepared) == 2048)
        #expect(prepared.quality == 0.5)
        // 下限(1280px、品質 0.4)約 31 dB,目視文字仍清楚。
        #expect(try Self.textRegionPSNR(prepared.jpeg, original: original) >= 30)
    }

    @Test("已小於目標大小的圖片：維持品質 0.8 與解析度")
    func smallImageKeepsQualityAndResolution() throws {
        let prepared = try #require(ImagePreparation.prepare(TestImage.png(width: 1600, height: 900)))

        #expect(prepared.jpeg.count <= Self.targetBytes)
        #expect(prepared.quality == 0.8)
        #expect(prepared.width == 1600)
        #expect(prepared.height == 900)
    }

    @Test("照片的位置、拍攝裝置與時間等中繼資料不帶到主機(#288)")
    func stripsPhotoMetadata() throws {
        let original = Self.photoWithMetadata()
        let originalProperties = try #require(Self.properties(original))
        #expect(originalProperties[kCGImagePropertyGPSDictionary] != nil, "樣本本身要帶位置")

        let prepared = try #require(ImagePreparation.prepare(original))

        let properties = try #require(Self.properties(prepared.jpeg))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    static func properties(_ data: Data) -> [CFString: Any]? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    }

    /// 帶 GPS、TIFF(拍攝裝置)與 Exif(拍攝時間)的 JPEG。
    static func photoWithMetadata() -> Data {
        let source = CGImageSourceCreateWithData(TestImage.png(width: 64, height: 48) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 25.0339, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.5645, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:20 09:30:00"],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("最難壓的內容(逐像素亂數):長邊仍不低於下限")
    func noiseImageStaysAboveMinimumSize() throws {
        let prepared = try #require(ImagePreparation.prepare(NoiseImage.png(width: 3000, height: 2000)))

        #expect(Self.longSide(prepared) >= Self.minimumLongSide)
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

#endif
