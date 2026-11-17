#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 圖片前處理測試的合成樣本，測試執行時產生(repo 不放大型二進位檔)。全由程式產生、沒有版權問題;亂數種子固定，輸出可重現。
enum SyntheticImages {
    /// 相機尺寸(4032×3024)的照片：近似 1/f 頻譜的彩色雜訊加感光雜訊(統計上接近自然照片),JPEG 品質 0.85。
    static let photo: Data = {
        var random = SeededRandom(seed: 76)
        return encode(naturalImage(width: 4032, height: 3024, sensorNoise: 6.9, random: &random), as: .jpeg, quality: 0.85)
    }()

    /// iPhone 尺寸(1290×2796)的聊天截圖：上方一大塊照片，下方密集文字(PNG)。
    static let screenshot: Data = {
        var random = SeededRandom(seed: 77)
        let width = 1290, height = 2796
        let context = rgbContext(width: width, height: height)
        // CoreGraphics 的原點在左下;以下的 y 都是從上往下量，畫的時候換算。
        func fill(_ rect: CGRect, radius: CGFloat = 0, red: CGFloat, green: CGFloat, blue: CGFloat) {
            let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            context.setFillColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
            context.addPath(CGPath(roundedRect: flipped, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let color = CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes))
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - CTFontGetAscent(font))
            CTLineDraw(line, context)
        }

        fill(CGRect(x: 0, y: 0, width: width, height: height), red: 28, green: 28, blue: 30)
        let photo = naturalImage(width: 1194, height: 1500, sensorNoise: 2.8, random: &random)
        context.draw(photo, in: CGRect(x: 48, y: height - 220 - 1500, width: 1194, height: 1500))
        text("Purrdr Sample Chat", x: 48, top: 110, size: 54, red: 242, green: 242, blue: 247)
        let words = ("agent workspace pane terminal upload compress quality resolution screenshot readable "
            + "session folder photo network deadline").split(separator: " ")
        let fixedLines = [
            3: "Build failed: error PX-4821 in ImageCodec.swift line 207",
            9: "Deploy token expires at 17:45 on Thursday",
            15: "Ledger balance 3,915.62 after refund",
        ]
        var top: CGFloat = 1770
        var lineNumber = 0
        while top < CGFloat(height - 80) {
            lineNumber += 1
            if lineNumber % 6 == 1 {
                fill(CGRect(x: 40, y: top - 6, width: CGFloat(width - 80), height: 50), radius: 18, red: 44, green: 44, blue: 46)
            }
            let line = fixedLines[lineNumber]
                ?? String(format: "%02d ", lineNumber) + (0..<7).map { _ in String(words[Int(random.next() % UInt64(words.count))]) }
                .joined(separator: " ")
            if lineNumber % 4 == 0 {
                text(line, x: 64, top: top, size: 32, red: 100, green: 210, blue: 255)
            } else {
                text(line, x: 64, top: top, size: 32, red: 235, green: 235, blue: 245)
            }
            top += 50
        }
        return encode(context.makeImage()!, as: .png)
    }()

    /// 三個色版共用一個底(色版之間相關)再各加自己的變化，整體標準化後加均勻分布的感光雜訊。
    static func naturalImage(width: Int, height: Int, sensorNoise: Float, random: inout SeededRandom) -> CGImage {
        let pixelCount = width * height
        let base = pyramid(width: width, height: height, random: &random)
        var channels = [Float](repeating: 0, count: pixelCount * 3)
        for (channel, weight) in [Float(1.0), 0.9, 0.75].enumerated() {
            let own = pyramid(width: width, height: height, random: &random)
            for index in 0..<pixelCount {
                channels[index * 3 + channel] = weight * base[index] + 0.35 * own[index]
            }
        }
        var sum = 0.0
        var squares = 0.0
        for value in channels {
            sum += Double(value)
            squares += Double(value) * Double(value)
        }
        let mean = sum / Double(channels.count)
        let deviation = (squares / Double(channels.count) - mean * mean).squareRoot()
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)
        for index in 0..<pixelCount {
            for channel in 0..<3 {
                let normalized = (Double(channels[index * 3 + channel]) - mean) / deviation
                let value = 128 + 48 * normalized + Double(sensorNoise * random.nextSigned())
                pixels[index * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// 近似 1/f 頻譜的雜訊場：從粗的格點開始，每級放大一倍(雙線性)再加白雜訊。
    /// 每級振幅乘 2^-0.1:每個八度的能量差不多(振幅頻譜約 f^-1.1)。
    static func pyramid(width: Int, height: Int, random: inout SeededRandom) -> [Float] {
        let decay = Float(pow(2, -0.1))
        let levels = max(1, Int(log2(Double(min(width, height)))) - 1)
        let scale = 1 << levels
        var fieldWidth = (width - 2 + scale) / scale + 1
        var fieldHeight = (height - 2 + scale) / scale + 1
        var field = (0..<fieldWidth * fieldHeight).map { _ in random.nextSigned() }
        var amplitude: Float = 1
        for _ in 0..<levels {
            let nextWidth = fieldWidth * 2 - 1
            let nextHeight = fieldHeight * 2 - 1
            amplitude *= decay
            var next = [Float](repeating: 0, count: nextWidth * nextHeight)
            field.withUnsafeBufferPointer { source in
                next.withUnsafeMutableBufferPointer { target in
                    for row in 0..<nextHeight {
                        let upper = row / 2 * fieldWidth
                        let lower = (row + 1) / 2 * fieldWidth
                        for column in 0..<nextWidth {
                            let left = column / 2
                            let right = (column + 1) / 2
                            let interpolated = (source[upper + left] + source[upper + right] + source[lower + left] + source[lower + right]) * 0.25
                            target[row * nextWidth + column] = interpolated + amplitude * random.nextSigned()
                        }
                    }
                }
            }
            field = next
            fieldWidth = nextWidth
            fieldHeight = nextHeight
        }
        var cropped = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                cropped[row * width + column] = field[row * fieldWidth + column]
            }
        }
        return cropped
    }

    static func rgbContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// 固定種子的亂數(64 位元 LCG,取高位)。
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    /// [-1, 1) 的均勻分布。
    mutating func nextSigned() -> Float {
        Float(next() >> 29) / Float(1 << 23) - 1
    }
}
#endif
