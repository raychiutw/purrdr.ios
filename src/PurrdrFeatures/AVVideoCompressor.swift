import AVFoundation
import ImageIO
import CoreTransferable
import Foundation
import PurrdrAgentFeatures
import SwiftUI
import UniformTypeIdentifiers

/// 以 `AVAssetExportSession` 壓縮影片(#474):依畫質階梯選系統預設,輸出 mp4(H.264)。
/// 進度用 `states(updateInterval:)`,取消靠 Task 取消(系統會停掉轉檔)。
public struct AVVideoCompressor: VideoCompressing {
    public init() {}

    public func duration(of source: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: source).load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw VideoCompressionError.unreadable }
        return duration.seconds
    }

    public func thumbnail(of source: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public func compress(
        _ source: URL, quality: VideoQuality, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: quality.presetName) else {
            throw VideoCompressionError.unreadable
        }
        let states = session.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1)
    }
}

enum VideoCompressionError: Error { case unreadable }

extension VideoQuality {
    /// 系統的轉檔預設。
    var presetName: String {
        switch self {
        case .high: AVAssetExportPreset1280x720
        case .medium: AVAssetExportPreset960x540
        case .low: AVAssetExportPreset640x480
        }
    }
}

/// 相簿挑選器給的影片:搬到我們自己的暫存資料夾(系統給的檔案在回呼結束後會被刪)。
struct PickedVideo: Transferable {
    let url: URL
    /// 放它的暫存資料夾(用完連資料夾一起刪)。
    let folder: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = FileManager.default.temporaryDirectory.appending(path: "purrdr-picked-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy, folder: folder)
        }
    }
}

/// 「＋附加」面板的影片來源。正式用系統相簿挑選器;UI 測試用替身(相簿挑選器在另一個行程，XCUITest 操作不了)。
public enum VideoSource: Sendable, Equatable {
    case system
    /// UI 測試:不開挑選器,直接給一支約 1 秒的小影片。
    case simulated
}

extension EnvironmentValues {
    @Entry public var videoSource: VideoSource = .system
}

/// 產生一支很小的測試影片(UI 測試的 `VideoSource.simulated`、壓縮的單元測試共用):`seconds` 秒、`size`、純色漸變。
public enum GeneratedVideo {
    public static func make(seconds: Int = 1, size: CGSize = CGSize(width: 320, height: 568), framesPerSecond: Int = 10) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "purrdr-generated-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoCompressionError.unreadable }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * framesPerSecond) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw VideoCompressionError.unreadable }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw VideoCompressionError.unreadable }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(truncatingIfNeeded: 40 + frame * 7 % 200), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoCompressionError.unreadable }
        return url
    }
}
