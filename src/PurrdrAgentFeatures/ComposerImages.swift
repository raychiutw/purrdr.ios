import CoreGraphics
import Foundation
import ImageIO
import PurrdrCore
import UniformTypeIdentifiers

/// 輸入列上的一個附件(行為規格 F7、#352):圖片(縮圖卡)或一般檔案(圖示、檔名、大小卡)。
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case image, file }

    public var id: String { fileName.value }
    public let kind: Kind
    /// 上傳到主機與手機副本用的檔名。
    public let fileName: HostUploadName
    /// 卡片上顯示的檔名(圖片是副本檔名)。
    public let displayName: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// 已上傳到主機的絕對路徑。送出失敗(什麼都沒送出)後再送，不重傳。
    public var uploadedPath: String?
    /// 影片的長度(秒);不是影片是 `nil`(#474)。
    public let duration: TimeInterval?
    /// 影片縮圖在手機副本資料夾的檔名;沒有是 `nil`。
    public let thumbnailFileName: String?

    public init(
        kind: Kind = .image, fileName: HostUploadName, displayName: String? = nil, byteCount: Int = 0, pixelWidth: Int = 0, pixelHeight: Int = 0,
        uploadedPath: String? = nil, duration: TimeInterval? = nil, thumbnailFileName: String? = nil
    ) {
        self.duration = duration
        self.thumbnailFileName = thumbnailFileName
        self.kind = kind
        self.fileName = fileName
        self.displayName = displayName ?? fileName.value
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.uploadedPath = uploadedPath
    }
}

/// 送出前在手機上處理圖片：長邊縮到 ≤ 2048px、重新編碼成 JPEG(行為規格 F7)。
/// 超過目標大小時先依序降品質，仍超過再縮小長邊，到下限為止(#78)。
public enum ImagePreparation {
    /// 目標大小(bytes)。
    public static let targetSize = 500 * 1024
    /// 依序嘗試的長邊：第一個是上限，最後一個是下限。
    public static let pixelSizeSteps = [2048, 1792, 1536, 1280]
    /// 每個長邊依序嘗試的 JPEG 品質;最後一個是下限(截圖文字仍可讀)。
    public static let qualitySteps = [0.8, 0.7, 0.6, 0.5, 0.4]

    public struct Prepared: Sendable {
        public let jpeg: Data
        public let width: Int
        public let height: Int
        /// 編碼用的 JPEG 品質。
        public let quality: Double
    }

    /// 讀不出圖片時回傳 `nil`。方向(EXIF orientation)會套用到像素上。
    /// 長邊與品質都到下限仍超過目標時，回傳下限的結果。
    public static func prepare(_ data: Data) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var lowestAttempt: Prepared?
        for pixelSize in pixelSizeSteps {
            guard let image = thumbnail(of: source, maximumPixelSize: pixelSize) else { return nil }
            for quality in qualitySteps {
                guard let jpeg = encode(image, quality: quality) else { return nil }
                let prepared = Prepared(jpeg: jpeg, width: image.width, height: image.height, quality: quality)
                if jpeg.count <= targetSize { return prepared }
                lowestAttempt = prepared
            }
        }
        return lowestAttempt
    }

    private static func thumbnail(of source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
