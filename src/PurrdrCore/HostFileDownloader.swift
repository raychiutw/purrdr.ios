import Crypto
import Foundation

/// 點開非圖片檔案(#228):經主機取檔下載到 app 的快取資料夾，給 QuickLook 與分享用。
/// 快取鍵是「路徑 + 版本」(資料夾 `<路徑雜湊>/<版本雜湊>/<檔名>`),版本沒變只查狀態;Agent 覆寫後換新資料夾、刪掉舊版本。
public actor HostFileDownloader {
    public enum Outcome: Sendable, Equatable {
        case downloaded(URL, version: HostFileVersion)
        /// 超過點擊開啟的上限(`HostFileFetchLimits.maximumSize`)是 `.tooLarge`。
        case unavailable(HostFileProblem)
    }

    private let fetcher: any HostFileFetching
    private let directory: URL

    /// - Parameter directory: 這台主機的快取資料夾(app 用 Caches 底下，系統可清除、不進備份)。
    public init(fetcher: any HostFileFetching, directory: URL) {
        self.fetcher = fetcher
        self.directory = directory
    }

    /// - Parameter progress: 已收到與總共的 bytes;開始讀之前先回報一次 0。
    public func download(
        _ path: String, scope: HostFileAccessScope, progress: @Sendable (_ received: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> Outcome {
        let attempt = await HostFileFetchAttempt.run(path, scope: scope, fetcher: fetcher) { target, version, size -> Outcome in
            guard size <= HostFileFetchLimits.maximumSize else { throw HostFileProblem.tooLarge(size: size) }
            let file = location(of: path, version: version)
            if FileManager.default.fileExists(atPath: file.path) { return .downloaded(file, version: version) }
            try await write(target, version: version, size: size, to: file, progress: progress)
            removeOtherVersions(of: path, keeping: file.deletingLastPathComponent())
            return .downloaded(file, version: version)
        }
        switch attempt {
        case .success(let outcome): return outcome
        case .failure(let problem): return .unavailable(problem)
        }
    }

    /// 先寫到暫存檔，讀完才改名;取消或失敗時刪掉，不留半個檔案。
    private func write(
        _ target: HostFileTarget, version: HostFileVersion, size: Int, to file: URL, progress: @Sendable (Int, Int) -> Void
    ) async throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw HostFileFetchError.failed("can't create cache file") }
        var isComplete = false
        defer {
            if !isComplete {
                try? FileManager.default.removeItem(at: partial)
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var received = 0
        progress(0, size)
        while received < size {
            try Task.checkCancellation()
            let chunk = try await fetcher.read(target, version: version, offset: received, length: min(HostFileFetchLimits.chunkSize, size - received))
            try Task.checkCancellation()
            guard !chunk.isEmpty else { throw HostFileProblem.failed("host file ended early") }
            try handle.write(contentsOf: chunk)
            received += chunk.count
            progress(received, size)
        }
        try handle.close()
        try FileManager.default.moveItem(at: partial, to: file)
        isComplete = true
    }

    private func location(of path: String, version: HostFileVersion) -> URL {
        directory
            .appending(path: Self.digest(path), directoryHint: .isDirectory)
            .appending(path: Self.digest(version.checksum), directoryHint: .isDirectory)
            .appending(path: Self.fileName(of: path), directoryHint: .notDirectory)
    }

    private func removeOtherVersions(of path: String, keeping current: URL) {
        let pathFolder = directory.appending(path: Self.digest(path), directoryHint: .isDirectory)
        let versions = (try? FileManager.default.contentsOfDirectory(at: pathFolder, includingPropertiesForKeys: nil)) ?? []
        for version in versions where version.standardizedFileURL.lastPathComponent != current.standardizedFileURL.lastPathComponent {
            try? FileManager.default.removeItem(at: version)
        }
    }

    /// 快取資料夾名稱：SHA-256 前 16 bytes 的十六進位(路徑可能很長或含不能當檔名的字元)。
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 保留主機上的檔名，QuickLook 依副檔名判斷類型、標題也是檔名。
    static func fileName(of path: String) -> String {
        let name = HostPathSyntax.components(path).last.map(String.init) ?? ""
        return name.isEmpty || name == "." || name == ".." ? "file" : name
    }
}
