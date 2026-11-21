import Foundation
import SwiftUI
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 「＋附加」面板上方最近照片的來源(#352)。
///
/// 正式用系統相簿(PhotoKit,要相簿權限,支援系統的有限存取);UI 測試用替身:不碰相簿、不跳權限對話框。
public enum RecentPhotoSource: Sendable, Equatable {
    case system
    /// UI 測試:`count` 張純色圖。
    case simulated(count: Int)
    /// UI 測試:沒有相簿權限，面板只顯示按鈕。
    case simulatedDenied
}

extension EnvironmentValues {
    @Entry public var recentPhotoSource: RecentPhotoSource = .system
}

/// 面板上的一張最近照片:縮圖是 JPEG bytes(不依賴 UIKit)。
struct RecentPhoto: Identifiable, Equatable, Sendable {
    let id: String
    let thumbnail: Data
}

extension RecentPhotoSource {
    /// 最近的照片(新的在前);沒有權限(或相簿空的)回空陣列，面板只顯示四顆按鈕。
    func recent(limit: Int) async -> [RecentPhoto] {
        switch self {
        case .simulatedDenied:
            return []
        case .simulated(let count):
            return (0..<min(count, limit)).compactMap { index in
                Self.simulatedImage(index, size: 120).map { RecentPhoto(id: "sim-\(index)", thumbnail: $0) }
            }
        case .system:
            return await Self.systemRecent(limit: limit)
        }
    }

    /// 選取的照片原圖 bytes(交給 `ConversationModel.addImages`)。
    func imageData(for ids: [String]) async -> [Data] {
        switch self {
        case .simulatedDenied:
            return []
        case .simulated:
            return ids.compactMap { id in Int(id.dropFirst("sim-".count)).flatMap { Self.simulatedImage($0, size: 400) } }
        case .system:
            return await Self.systemImageData(ids)
        }
    }

    private static func simulatedImage(_ index: Int, size: CGFloat) -> Data? {
        #if canImport(UIKit)
        let colors = [0.52, 0.08, 0.92, 0.7, 0.35, 0.15].map { UIColor(hue: $0, saturation: 0.6, brightness: 0.85, alpha: 1) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            colors[index % colors.count].setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        #else
        return nil
        #endif
    }

    #if canImport(Photos) && canImport(UIKit)
    private static func systemRecent(limit: Int) async -> [RecentPhoto] {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [RecentPhoto] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            if let data = await thumbnail(of: asset) { photos.append(RecentPhoto(id: asset.localIdentifier, thumbnail: data)) }
        }
        return photos
    }

    private static func thumbnail(of asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.7))
            }
        }
    }

    private static func systemImageData(_ ids: [String]) async -> [Data] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        var result: [Data] = []
        for id in ids {
            guard let asset = byID[id] else { continue }
            let data: Data? = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.version = .current
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { result.append(data) }
        }
        return result
    }
    #else
    private static func systemRecent(limit: Int) async -> [RecentPhoto] { [] }
    private static func systemImageData(_ ids: [String]) async -> [Data] { [] }
    #endif
}
