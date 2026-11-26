import Foundation
import PurrdrAgentFeatures
import Testing

/// 附件副本只留 7 天、資料夾排除備份(#576)。時鐘以注入的假時間推進;「排除備份」只在 Apple 平台驗證。
@Suite("附件副本保留期限")
struct AttachmentRetentionTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_794_614_400)
        var now: Date {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
        func advance(days: Double) { now = now.addingTimeInterval(days * 24 * 60 * 60) }
    }

    static func makeStore(clock: Clock) -> FileAttachmentStore {
        FileAttachmentStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-retention-\(UUID().uuidString)", directoryHint: .isDirectory),
            now: { clock.now })
    }

    static func names(in store: FileAttachmentStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test("保留期限是 7 天")
    func retentionIsSevenDays() {
        #expect(FileAttachmentStore.retention == 7 * 24 * 60 * 60)
    }

    @Test("超過 7 天的副本清掉，沒超過的留著")
    func purgesOnlyExpiredCopies() throws {
        let clock = Clock()
        let store = Self.makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Data("old".utf8), as: "old.jpg")
        clock.advance(days: 3)
        try store.save(Data("middle".utf8), as: "middle.jpg")
        clock.advance(days: 4.5)

        store.purgeExpired()

        #expect(Self.names(in: store) == ["middle.jpg"])
    }

    @Test("剛好 7 天內的副本留著")
    func keepsCopiesWithinTheLimit() throws {
        let clock = Clock()
        let store = Self.makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Data("x".utf8), as: "x.jpg")
        clock.advance(days: 6.9)

        store.purgeExpired()

        #expect(Self.names(in: store) == ["x.jpg"])
    }

    @Test("影片搬進來的副本與縮圖也依存入時間計算，不看來源檔的舊時間")
    func movedFilesAreStampedWithTheSaveTime() throws {
        let clock = Clock()
        let store = Self.makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = FileManager.default.temporaryDirectory.appending(path: "purrdr-source-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now.addingTimeInterval(-30 * 24 * 60 * 60)], ofItemAtPath: source.path(percentEncoded: false))

        try store.save(movingFile: source, as: "clip.mov")
        clock.advance(days: 1)
        store.purgeExpired()

        #expect(Self.names(in: store) == ["clip.mov"])
    }

    @Test("寫入新附件時順便清掉過期的(每個 store 第一次寫入)")
    func firstSavePurgesExpiredCopies() throws {
        let clock = Clock()
        let store = Self.makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Data("old".utf8), as: "old.jpg")
        clock.advance(days: 8)
        let relaunched = FileAttachmentStore(directory: store.directory, now: { clock.now })

        try relaunched.save(Data("new".utf8), as: "new.jpg")

        #expect(Self.names(in: store) == ["new.jpg"])
    }

    @Test("資料夾還不存在時清理什麼都不做")
    func purgingAMissingDirectoryIsHarmless() {
        let store = Self.makeStore(clock: Clock())

        store.purgeExpired()

        #expect(Self.names(in: store).isEmpty)
    }

    @Test("清理不動資料夾本身，之後仍可存新的")
    func directorySurvivesPurge() throws {
        let clock = Clock()
        let store = Self.makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Data("old".utf8), as: "old.jpg")
        clock.advance(days: 30)
        store.purgeExpired()

        try store.save(Data("new".utf8), as: "new.jpg")

        #expect(Self.names(in: store) == ["new.jpg"])
    }

    #if canImport(Darwin)
    @Test("資料夾排除備份(只在 Apple 平台驗證)")
    func directoryIsExcludedFromBackup() throws {
        let store = Self.makeStore(clock: Clock())
        defer { try? FileManager.default.removeItem(at: store.directory) }

        try store.save(Data("x".utf8), as: "x.jpg")

        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("搬進來的影片存入後資料夾仍排除備份(只在 Apple 平台驗證)")
    func directoryStaysExcludedAfterMovingAFile() throws {
        let store = Self.makeStore(clock: Clock())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = FileManager.default.temporaryDirectory.appending(path: "purrdr-source-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: source)

        try store.save(movingFile: source, as: "clip.mov")

        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    #endif
}
