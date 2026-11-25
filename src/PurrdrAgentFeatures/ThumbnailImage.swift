import CoreGraphics
import PurrdrCore

/// 主機圖片解碼後的縮圖(#482),放在 `AgentFileLoads.thumbnails` 的記憶體快取。
public struct ThumbnailImage: Sendable {
    public let image: CGImage

    public init(image: CGImage) { self.image = image }

    /// 解碼後占的記憶體(bytes,以 4 bytes/pixel 估算)。
    public var cost: Int { image.width * image.height * 4 }

    /// 縮圖的寬高(像素),比例同原圖。
    public var pixelSize: ImagePixelSize { ImagePixelSize(width: image.width, height: image.height) }
}
