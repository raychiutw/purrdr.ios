#if os(iOS)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import PurrdrFeatures

/// 貼上圖片取原始資料(#687):剪貼簿與貼上鈕交給圖片準備流程的是原圖 bytes,
/// 不在主執行緒解碼成 UIImage、也不轉成 PNG(PNG 會比原圖大很多,上限以原圖大小判斷才不會誤判)。
@Suite
@MainActor
struct PastedImageRawDataTests {
    private func jpegSample() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }

    private func provider(for data: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @Test("貼上鈕交來的項目:原始資料原封不動交出,沒有轉成 PNG")
    func providersKeepOriginalBytes() async {
        let jpeg = jpegSample()
        let images = await ImageSources.rawImageData(from: [provider(for: jpeg, type: .jpeg)])
        #expect(images == [jpeg])
        #expect(images.first.flatMap { UIImage(data: $0) } != nil, "仍是可讀的圖片")
    }

    @Test("多個項目依序交出,各自保持原格式(JPEG 仍是 JPEG)")
    func multipleProvidersInOrder() async {
        let jpeg = jpegSample()
        let png = UIImage(data: jpeg)?.pngData() ?? Data()
        let images = await ImageSources.rawImageData(from: [provider(for: jpeg, type: .jpeg), provider(for: png, type: .png)])
        #expect(images == [jpeg, png])
    }
}
#endif
