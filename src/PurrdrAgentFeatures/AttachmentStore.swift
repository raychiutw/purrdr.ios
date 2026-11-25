import Foundation
import PurrdrCore

/// 手機上保存圖片副本的地方(泡泡依檔名找它顯示;行為規格 F7)。
public protocol AttachmentStore: Sendable {
    func save(_ data: Data, as name: String) throws
    /// 副本的位置;沒有這個檔案時是 `nil`。
    func url(of name: String) -> URL?
    /// 把 `source` 檔案搬進來存成副本(不經記憶體;影片最多 25 MiB,在背景呼叫)。
    func save(movingFile source: URL, as name: String) throws
    /// 刪掉副本(檔案附件移除或送出後;沒有這個檔案時什麼都不做)。
    func remove(_ name: String)
}

extension AttachmentStore {
    public func remove(_ name: String) {}

    public func save(movingFile source: URL, as name: String) throws {
        try save(Data(contentsOf: source, options: .mappedIfSafe), as: name)
        try? FileManager.default.removeItem(at: source)
    }
}

/// 存在一個資料夾裡的圖片副本。只接受 `HostUploadName` 允許的檔名。
public struct FileAttachmentStore: AttachmentStore {
    /// 副本最多留幾天(#576)。
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// 每個 store 只在第一次寫入時順便清理一次。
    private final class FirstSave: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { let first = !done; done = true; return first } }
    }

    public let directory: URL
    private let now: @Sendable () -> Date
    private let firstSave = FirstSave()

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// App 的副本資料夾(Application Support,不出現在「檔案」app;排除備份,超過保留天數的副本在背景清掉)。
    public static func app() -> FileAttachmentStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let store = FileAttachmentStore(directory: base.appending(path: "Attachments", directoryHint: .isDirectory))
        Task.detached(priority: .utility) { store.purgeExpired() }
        return store
    }

    /// 刪掉超過保留天數的副本(含影片縮圖)。
    public func purgeExpired() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 建資料夾、排除備份;第一次寫入時順便清掉過期副本。
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        if firstSave.claim() { purgeExpired() }
    }

    private func stamp(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path(percentEncoded: false))
    }

    public func save(_ data: Data, as name: String) throws {
        guard HostUploadName(name) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepareDirectory()
        let destination = directory.appending(path: name)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        stamp(destination)
    }

    public func save(movingFile source: URL, as name: String) throws {
        guard HostUploadName(name) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepareDirectory()
        let destination = directory.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path(percentEncoded: false))
        stamp(destination)
    }

    public func url(of name: String) -> URL? {
        guard HostUploadName(name) != nil else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func remove(_ name: String) {
        guard HostUploadName(name) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}
