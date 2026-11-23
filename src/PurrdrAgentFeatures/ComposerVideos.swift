import Foundation
import PurrdrCore

/// 影片壓縮的畫質階梯(#474):由高到低。壓不到上限就換下一階。
public enum VideoQuality: Sendable, Equatable, CaseIterable {
    /// 約 720p(系統預設 `AVAssetExportPreset1280x720`)。
    case high
    /// 約 540p。
    case medium
    /// 640×480 以內,最小的一階。
    case low

    /// 每秒輸出的位元組估計(保守值，只用來略過明顯放不下的階;最後仍以實際大小為準)。
    /// 實測:41 秒的 iPhone 17 螢幕錄影(1206×2622)輸出 720p 約 0.81 MB/s、540p 約 0.50 MB/s、640×480 約 0.26 MB/s。
    var estimatedBytesPerSecond: Double {
        switch self {
        case .high: 900_000
        case .medium: 560_000
        case .low: 330_000
        }
    }

    /// 這支影片(`duration` 秒)依估計放得進 `limit` bytes 的階，由高到低;一階都放不進(太長)時是空陣列。
    public static func candidates(forDuration duration: TimeInterval, limit: Int) -> [VideoQuality] {
        allCases.filter { $0.estimatedBytesPerSecond * max(duration, 0) <= Double(limit) }
    }
}

/// 把相簿影片壓小(平台實作在 Features 的 `AVVideoCompressor`;可攜核心與這一層不 import AVFoundation)。
public protocol VideoCompressing: Sendable {
    /// 影片長度(秒);讀不出來丟錯。
    func duration(of source: URL) async throws -> TimeInterval
    /// 把 `source` 以 `quality` 壓成 mp4 寫到 `destination`。`progress` 是 0…1。
    /// 被取消時丟 `CancellationError`、不留 `destination`。
    func compress(
        _ source: URL, quality: VideoQuality, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// 第一格的縮圖(JPEG);取不到是 `nil`。
    func thumbnail(of source: URL) async -> Data?
}

extension VideoCompressing {
    public func thumbnail(of source: URL) async -> Data? { nil }
}

/// 輸入列上影片準備中的狀態(顯示進度與取消)。
public struct VideoPreparation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 從相簿取出影片(可能在 iCloud 下載)、量長度。
        case loading
        /// 壓縮中。
        case shrinking
    }

    public var displayName: String
    public var phase: Phase
    /// 0…1;`loading` 時沒有進度。
    public var fraction: Double?
}

/// 挑選器取出的影片檔(#474):`discard` 是用完要刪掉的東西(通常是放它的暫存資料夾;預設是檔案本身)。
public struct VideoSourceFile: Sendable {
    public let url: URL
    public let discard: URL

    public init(_ url: URL, discarding discard: URL? = nil) {
        self.url = url
        self.discard = discard ?? url
    }
}

/// 送出時附件上傳中的進度(顯示百分比與取消)。
public struct UploadProgress: Equatable, Sendable {
    /// 正在上傳的那個附件的顯示名稱。
    public var displayName: String
    /// 0…1。
    public var fraction: Double
}
