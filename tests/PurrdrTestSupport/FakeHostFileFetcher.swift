import Foundation
import PurrdrCore

/// 測試用的主機取檔(#225):記憶體裡的檔案，每次寫入換一個版本;`requests` 記下收到的請求。
/// 存取規則只模擬主機端的結果(`deny`),app 端規則由 `HostFileLoader` 自己檢查。
public actor FakeHostFileFetcher: HostFileFetching {
    public enum Request: Sendable, Equatable {
        case status(String)
        case read(String, offset: Int, length: Int)
    }

    public private(set) var requests: [Request] = []
    private var files: [String: (data: Data, version: HostFileVersion)] = [:]
    private var denied: Set<String> = []
    private var revision = 0
    private let isSupported: Bool
    private let maximumSize: Int
    /// 下一次讀取前先把檔案換成這個內容(模擬分塊之間被覆寫)。
    private var pendingOverwrite: (path: String, data: Data)?

    public init(files: [String: Data] = [:], isSupported: Bool = true, maximumSize: Int = HostFileFetchLimits.maximumSize) {
        self.isSupported = isSupported
        self.maximumSize = maximumSize
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            revision += 1
            self.files[path] = (data, HostFileVersion(checksum: "fake-\(revision):\(data.count)"))
        }
    }

    /// 寫入(覆寫)檔案，版本跟著換。
    public func put(_ data: Data, at path: String) {
        revision += 1
        files[path] = (data, HostFileVersion(checksum: "fake-\(revision):\(data.count)"))
    }

    public func remove(_ path: String) {
        files[path] = nil
    }

    /// 主機端的存取規則拒絕這個路徑(例如 symlink 跳出工作目錄)。
    public func deny(_ path: String) {
        denied.insert(path)
    }

    /// 下一次讀取這個檔案之前覆寫它(Agent 在分塊之間改了檔)。
    public func overwriteBeforeNextRead(_ path: String, with data: Data) {
        pendingOverwrite = (path, data)
    }

    public var readCount: Int { requests.count { if case .read = $0 { true } else { false } } }

    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        requests.append(.status(target.path))
        return try currentStatus(target.path)
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        requests.append(.read(target.path, offset: offset, length: length))
        if let pending = pendingOverwrite, pending.path == target.path {
            pendingOverwrite = nil
            put(pending.data, at: pending.path)
        }
        let status = try currentStatus(target.path)
        guard case .file = status, let file = files[target.path] else { throw HostFileFetchError.unavailable(status) }
        guard file.version == version else { throw HostFileFetchError.changed }
        let start = min(offset, file.data.count)
        return file.data.subdata(in: start..<min(start + length, file.data.count))
    }

    private func currentStatus(_ path: String) throws -> HostFileStatus {
        guard isSupported else { throw HostFileFetchError.unsupported }
        if denied.contains(path) { return .denied }
        guard let file = files[path] else { return .missing }
        if file.data.count > maximumSize { return .tooLarge(size: file.data.count) }
        return .file(version: file.version, size: file.data.count)
    }
}
