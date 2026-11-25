import Foundation
import PurrdrAgentFeatures

/// 診斷記錄檔(`hitch-log.jsonl`,JSON Lines;卡頓與閃退共用):所有檔案 I/O 都在一條背景序列佇列上,呼叫端(含主執行緒與畫面回呼)不會被擋住。
/// 超過大小上限就丟最舊的行;排除備份,隨 app 刪除;不上傳任何地方。
/// `@unchecked`:可變的 `knownSize` 只在序列佇列 `queue` 上讀寫,其餘是 `let`。
public final class DiagnosticLogFile: DiagnosticLogStoring, @unchecked Sendable {
    public static let fileName = "hitch-log.jsonl"

    private let queue = DispatchQueue(label: "com.raychiu.purrdr.hitch-log", qos: .utility)
    private let directory: URL
    private let maxBytes: Int
    /// 只在 `queue` 上讀寫。
    private var knownSize: Int?

    public init(directory: URL, maxBytes: Int = DiagnosticLogTrimmer.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// 正式位置:Application Support 下的 `hitch-log.jsonl`。
    public static func applicationSupport() -> DiagnosticLogFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DiagnosticLogFile(directory: base)
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: - DiagnosticLogStoring

    public func append(_ entries: [DiagnosticEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in write(entries.map(DiagnosticLogEncoder.line)) }
    }

    public func exportFile(meta: DiagnosticEntry?) async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: makeExport(meta: meta)) }
        }
    }

    public func clear() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? FileManager.default.removeItem(at: url)
                knownSize = 0
                continuation.resume()
            }
        }
    }

    /// 等佇列上已排的寫入都做完(測試用)。
    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: - 佇列上的工作

    private func write(_ lines: [String]) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let isNew = !fileManager.fileExists(atPath: url.path)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if isNew {
            guard fileManager.createFile(atPath: url.path, contents: data) else { return }
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(excluded)
            knownSize = data.count
        } else {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            knownSize = (knownSize ?? currentSize()) + data.count
        }
        if (knownSize ?? 0) > maxBytes { trimFile() }
    }

    private func currentSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func trimFile() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let kept = DiagnosticLogTrimmer.trim(lines, maxBytes: maxBytes)
        let data = Data((kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n").utf8)
        try? data.write(to: url, options: .atomic)
        knownSize = data.count
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(excluded)
    }

    private func makeExport(meta: DiagnosticEntry?) -> URL? {
        guard let body = try? Data(contentsOf: url), !body.isEmpty else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("purrdr-hitch-log.jsonl")
        var data = Data()
        if let meta { data.append(Data((DiagnosticLogEncoder.line(meta) + "\n").utf8)) }
        data.append(body)
        do {
            try data.write(to: temporary, options: .atomic)
            return temporary
        } catch {
            return nil
        }
    }
}
