import AVFoundation
import Foundation
import PurrdrAgentFeatures
@testable import PurrdrFeatures
import Testing

/// 影片壓縮(#474):以程式產生的小型測試影片，跑真的 AVFoundation。
@Suite("影片壓縮")
struct AVVideoCompressorTests {
    @Test("每一階都輸出可播放的 mp4,長度與來源相同，進度走到 1")
    func compressesToPlayableMP4() async throws {
        let source = try await GeneratedVideo.make(seconds: 2, size: CGSize(width: 720, height: 1280))
        defer { try? FileManager.default.removeItem(at: source) }
        let compressor = AVVideoCompressor()
        let sourceDuration = try await compressor.duration(of: source)
        #expect(abs(sourceDuration - 2) < 0.2)

        for quality in VideoQuality.allCases {
            let output = FileManager.default.temporaryDirectory.appending(path: "compressed-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let progress = ProgressRecorder()

            try await compressor.compress(source, quality: quality, to: output) { progress.record($0) }

            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            #expect(!tracks.isEmpty, "\(quality) 沒有影像軌")
            let size = try await tracks[0].load(.naturalSize)
            #expect(max(size.width, size.height) <= 1280, "\(quality) 輸出尺寸 \(size)")
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - sourceDuration) < 0.3)
            #expect(progress.last == 1)
        }
    }

    @Test("低畫質比高畫質小:階梯真的在省空間")
    func lowerQualityIsSmaller() async throws {
        let source = try await GeneratedVideo.make(seconds: 3, size: CGSize(width: 1080, height: 1920), framesPerSecond: 15)
        defer { try? FileManager.default.removeItem(at: source) }
        var sizes: [VideoQuality: Int] = [:]
        for quality in [VideoQuality.high, .low] {
            let output = FileManager.default.temporaryDirectory.appending(path: "compressed-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            try await AVVideoCompressor().compress(source, quality: quality, to: output) { _ in }
            sizes[quality] = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        let low = try #require(sizes[.low])
        let high = try #require(sizes[.high])
        #expect(low < high)
    }

    @Test("取消:丟錯,不留輸出檔")
    func cancelLeavesNoOutput() async throws {
        let source = try await GeneratedVideo.make(seconds: 4, size: CGSize(width: 1080, height: 1920), framesPerSecond: 20)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory.appending(path: "compressed-\(UUID().uuidString).mp4")
        let task = Task { try await AVVideoCompressor().compress(source, quality: .high, to: output) { _ in } }
        task.cancel()

        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test("讀不出的檔案:丟錯")
    func unreadableSource() async throws {
        let bogus = FileManager.default.temporaryDirectory.appending(path: "bogus-\(UUID().uuidString).mov")
        try Data("not a video".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        await #expect(throws: (any Error).self) { try await AVVideoCompressor().duration(of: bogus) }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
}
