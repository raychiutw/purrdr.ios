import Foundation
import Synchronization

/// 圖片的像素寬高(列高由資料決定,#482)。
public struct ImagePixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// 寬高都是正數才算已知。
    public var isKnown: Bool { width > 0 && height > 0 }

    /// 依比例縮到長邊 `longEdge`(四捨五入);尺寸未知回 `nil`。
    public func fitted(longEdge: Double) -> (width: Double, height: Double)? {
        guard isKnown else { return nil }
        let scale = longEdge / Double(max(width, height))
        return ((Double(width) * scale).rounded(), (Double(height) * scale).rounded())
    }
}

/// 縮圖快取的 key:主機路徑 + 版本 + 縮圖長邊(圖片卡片與使用者泡泡共用同一個長邊,檔案縮圖另一個)。
public struct HostImageKey: Hashable, Sendable {
    public var path: String
    public var version: HostFileVersion
    public var maxPixels: Int

    public init(path: String, version: HostFileVersion, maxPixels: Int) {
        self.path = path
        self.version = version
        self.maxPixels = maxPixels
    }
}

/// 主機圖片的縮圖與尺寸快取(#482):縮圖有記憶體上限、超過淘汰最久沒用的;尺寸記下來讓列一出現就有最終高度。
public final class HostImageCache<Thumbnail: Sendable>: Sendable {
    private struct SizeKey: Hashable {
        var path: String
        var version: HostFileVersion
    }

    private struct State {
        var thumbnails: [HostImageKey: Thumbnail] = [:]
        /// 最近用過的在後面;超過上限從前面丟。
        var recentlyUsed: [HostImageKey] = []
        var totalCost = 0
        var decodedSizes: [SizeKey: ImagePixelSize] = [:]
        var transcriptSizes: [String: ImagePixelSize] = [:]
    }

    private let byteLimit: Int
    private let cost: @Sendable (Thumbnail) -> Int
    private let state = Mutex(State())

    /// - Parameters:
    ///   - byteLimit: 縮圖總成本上限(預設 48 MiB)。
    ///   - cost: 一張縮圖占的 bytes。
    public init(byteLimit: Int = 48 * 1024 * 1024, cost: @escaping @Sendable (Thumbnail) -> Int) {
        self.byteLimit = byteLimit
        self.cost = cost
    }

    /// 已解碼的縮圖(算「用過」);沒有時 `nil`。
    public func cachedThumbnail(for key: HostImageKey) -> Thumbnail? {
        state.withLock { state in
            guard let thumbnail = state.thumbnails[key] else { return nil }
            Self.touch(key, in: &state)
            return thumbnail
        }
    }

    /// 有快取就直接回;沒有才呼叫 `decode`,結果放進快取並記下尺寸。解碼失敗回 `nil`、不快取。
    public func thumbnail(
        for key: HostImageKey, decode: @Sendable () async -> (thumbnail: Thumbnail, size: ImagePixelSize)?
    ) async -> Thumbnail? {
        if let cached = cachedThumbnail(for: key) { return cached }
        guard let decoded = await decode() else { return nil }
        store(decoded.thumbnail, size: decoded.size, for: key)
        return decoded.thumbnail
    }

    /// 這個路徑的尺寸:先看解碼後記下的(要帶 `version`),再看對話紀錄帶的;都沒有時 `nil`。
    public func size(forPath path: String, version: HostFileVersion? = nil) -> ImagePixelSize? {
        state.withLock { state in
            if let version, let decoded = state.decodedSizes[SizeKey(path: path, version: version)] { return decoded }
            return state.transcriptSizes[path]
        }
    }

    /// 記下對話紀錄帶的尺寸(還不知道版本)。
    public func recordTranscriptSize(_ size: ImagePixelSize, forPath path: String) {
        guard size.isKnown else { return }
        state.withLock { $0.transcriptSizes[path] = size }
    }

    /// 目前縮圖總成本(bytes)。
    public var totalCost: Int { state.withLock { $0.totalCost } }

    private func store(_ thumbnail: Thumbnail, size: ImagePixelSize, for key: HostImageKey) {
        let thumbnailCost = cost(thumbnail)
        state.withLock { state in
            if size.isKnown { state.decodedSizes[SizeKey(path: key.path, version: key.version)] = size }
            guard thumbnailCost <= byteLimit else { return }
            if state.thumbnails[key] != nil { Self.remove(key, from: &state, cost: cost) }
            state.thumbnails[key] = thumbnail
            state.recentlyUsed.append(key)
            state.totalCost += thumbnailCost
            while state.totalCost > byteLimit, let oldest = state.recentlyUsed.first {
                Self.remove(oldest, from: &state, cost: cost)
            }
        }
    }

    private static func touch(_ key: HostImageKey, in state: inout State) {
        guard let index = state.recentlyUsed.firstIndex(of: key) else { return }
        state.recentlyUsed.remove(at: index)
        state.recentlyUsed.append(key)
    }

    private static func remove(_ key: HostImageKey, from state: inout State, cost: @Sendable (Thumbnail) -> Int) {
        if let removed = state.thumbnails.removeValue(forKey: key) { state.totalCost -= cost(removed) }
        state.recentlyUsed.removeAll { $0 == key }
    }
}
