import Foundation
import PurrdrAgentFeatures

/// 待處理閃退標記檔(`pending-crash.json`):中止前的處理器直接同步寫,不經佇列(下次啟動即刪除)。
public final class FileCrashMarkerStore: CrashMarkerStoring, @unchecked Sendable {
    public static let fileName = "pending-crash.json"
    /// 安裝時先建好資料夾與路徑字串,處理器裡只做一次寫檔。
    private let path: String

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent(Self.fileName).path
    }

    public static func applicationSupport() -> FileCrashMarkerStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileCrashMarkerStore(directory: base)
    }

    public func write(_ data: Data) {
        _ = FileManager.default.createFile(atPath: path, contents: data)
    }

    public func read() -> Data? { FileManager.default.contents(atPath: path) }

    public func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// 診斷記錄檔(`hitch-log.jsonl`,JSON Lines;卡頓與閃退共用):所有檔案 I/O 都在一條背景序列佇列上,呼叫端(含主執行緒與畫面回呼)不會被擋住。
/// 超過大小上限就丟最舊的行;排除備份,隨 app 刪除;不上傳任何地方。
public final class HitchLogFile: HitchLogStoring, @unchecked Sendable {
    public static let fileName = "hitch-log.jsonl"

    private let queue = DispatchQueue(label: "com.raychiu.purrdr.hitch-log", qos: .utility)
    private let directory: URL
    private let maxBytes: Int
    /// 只在 `queue` 上讀寫。
    private var knownSize: Int?

    public init(directory: URL, maxBytes: Int = HitchLogTrimmer.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// 正式位置:Application Support 下的 `hitch-log.jsonl`。
    public static func applicationSupport() -> HitchLogFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return HitchLogFile(directory: base)
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: - HitchLogStoring

    public func append(_ entries: [HitchEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in write(entries.map(HitchLogEncoder.line)) }
    }

    public func exportFile(meta: HitchEntry?) async -> URL? {
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
        let kept = HitchLogTrimmer.trim(lines, maxBytes: maxBytes)
        let data = Data((kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n").utf8)
        try? data.write(to: url, options: .atomic)
        knownSize = data.count
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(excluded)
    }

    private func makeExport(meta: HitchEntry?) -> URL? {
        guard let body = try? Data(contentsOf: url), !body.isEmpty else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("purrdr-hitch-log.jsonl")
        var data = Data()
        if let meta { data.append(Data((HitchLogEncoder.line(meta) + "\n").utf8)) }
        data.append(body)
        do {
            try data.write(to: temporary, options: .atomic)
            return temporary
        } catch {
            return nil
        }
    }
}
