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

    public init(
        kind: Kind = .image, fileName: HostUploadName, displayName: String? = nil, byteCount: Int = 0, pixelWidth: Int = 0, pixelHeight: Int = 0,
        uploadedPath: String? = nil
    ) {
        self.kind = kind
        self.fileName = fileName
        self.displayName = displayName ?? fileName.value
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.uploadedPath = uploadedPath
    }
}

/// 手機上保存圖片副本的地方(泡泡依檔名找它顯示;行為規格 F7)。
public protocol AttachmentStore: Sendable {
    func save(_ data: Data, as name: String) throws
    /// 副本的位置;沒有這個檔案時是 `nil`。
    func url(of name: String) -> URL?
    /// 刪掉副本(檔案附件移除或送出後;沒有這個檔案時什麼都不做)。
    func remove(_ name: String)
}

extension AttachmentStore {
    public func remove(_ name: String) {}
}

/// 存在一個資料夾裡的圖片副本。只接受 `HostUploadName` 允許的檔名。
public struct FileAttachmentStore: AttachmentStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// App 的副本資料夾(Application Support,不出現在「檔案」app;只在清除資料時刪)。
    public static func app() -> FileAttachmentStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return FileAttachmentStore(directory: base.appending(path: "Attachments", directoryHint: .isDirectory))
    }

    public func save(_ data: Data, as name: String) throws {
        guard HostUploadName(name) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func url(of name: String) -> URL? {
        guard HostUploadName(name) != nil else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func remove(_ name: String) {
        guard HostUploadName(name) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}

/// 對話畫面的附加功能：上傳到主機、圖片的手機副本、檔名產生器。沒有它(`nil`)時輸入列不能附加圖片或檔案。
public struct ComposerImages: Sendable {
    public let uploader: any HostUploading
    public let store: any AttachmentStore
    public let makeName: @Sendable () -> UploadFileName
    /// 一般檔案(#286):原始檔名 → 上傳檔名。
    public let makeFileName: @Sendable (String) -> HostUploadName

    public init(
        uploader: any HostUploading, store: any AttachmentStore, makeName: @escaping @Sendable () -> UploadFileName = ComposerImages.randomName,
        makeFileName: @escaping @Sendable (String) -> HostUploadName = ComposerImages.randomFileName
    ) {
        self.uploader = uploader
        self.store = store
        self.makeName = makeName
        self.makeFileName = makeFileName
    }

    public static let randomName: @Sendable () -> UploadFileName = {
        var random = SystemRandomNumberGenerator()
        return UploadFileName.make(date: Date(), random: &random)
    }

    public static let randomFileName: @Sendable (String) -> HostUploadName = { original in
        var random = SystemRandomNumberGenerator()
        return HostUploadName.make(original: original, date: Date(), random: &random)
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
