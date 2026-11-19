import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 點開非圖片檔案(#228):下載到 app 的快取資料夾給 QuickLook 開。快取鍵含版本，上限 25 MiB,可取消。
@Suite("主機檔案下載到快取")
struct HostFileDownloaderTests {
    static let root = "/Users/demo/ledger"
    static let report = "/Users/demo/ledger/docs/report.pdf"
    static let scope = HostFileAccessScope(workingDirectories: [root], mentionedPaths: [])

    static func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "purrdr-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("分塊下載成快取資料夾裡的檔案，保留檔名(QuickLook 依副檔名判斷類型);進度回報到總大小")
    func downloadsIntoTheCacheFolder() async throws {
        let pdf = Self.bytes(HostFileFetchLimits.chunkSize + 100)
        let fetcher = FakeHostFileFetcher(files: [Self.report: pdf])
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: fetcher, directory: directory)
        let progress = ProgressLog()

        let result = await downloader.download(Self.report, scope: Self.scope) { received, total in progress.append(received, total) }

        guard case .downloaded(let file, _) = result else { Issue.record("沒有下載:\(result)"); return }
        #expect(file.lastPathComponent == "report.pdf")
        #expect(file.path.hasPrefix(directory.path))
        #expect(try Data(contentsOf: file) == pdf)
        #expect(progress.entries.last == ProgressLog.Entry(received: pdf.count, total: pdf.count))
        #expect(progress.entries.first == ProgressLog.Entry(received: 0, total: pdf.count))
    }

    @Test("同一版本再開只查狀態、用快取檔;Agent 覆寫後重新下載，舊版的檔案刪掉")
    func cacheKeyIncludesTheVersion() async throws {
        let fetcher = FakeHostFileFetcher(files: [Self.report: Data("v1".utf8)])
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: fetcher, directory: directory)

        guard case .downloaded(let first, _) = await downloader.download(Self.report, scope: Self.scope) else { Issue.record("沒有下載"); return }
        guard case .downloaded(let again, _) = await downloader.download(Self.report, scope: Self.scope) else { Issue.record("沒有下載"); return }
        #expect(again == first)
        #expect(await fetcher.readCount == 1, "版本沒變不重讀")

        await fetcher.put(Data("v2".utf8), at: Self.report)
        guard case .downloaded(let fresh, _) = await downloader.download(Self.report, scope: Self.scope) else { Issue.record("沒有下載"); return }
        #expect(try Data(contentsOf: fresh) == Data("v2".utf8))
        #expect(await fetcher.readCount == 2)
        #expect(fresh != first, "新版本換一個 URL,QuickLook 不會沿用舊的預覽")
        #expect(!FileManager.default.fileExists(atPath: first.path), "舊版本的檔案不留在快取")
    }

    @Test("快取跨 app 重啟:新的 downloader 指向同一個資料夾，版本沒變不重讀")
    func cacheSurvivesANewDownloader() async {
        let fetcher = FakeHostFileFetcher(files: [Self.report: Data("v1".utf8)])
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await HostFileDownloader(fetcher: fetcher, directory: directory).download(Self.report, scope: Self.scope)

        guard case .downloaded = await HostFileDownloader(fetcher: fetcher, directory: directory).download(Self.report, scope: Self.scope) else {
            Issue.record("沒有下載"); return
        }
        #expect(await fetcher.readCount == 1)
    }

    @Test("超過 25 MiB 不下載，回報大小")
    func overTheLimit() async {
        let fetcher = FakeHostFileFetcher(files: [Self.report: Self.bytes(2_000)], maximumSize: 1_000)
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: fetcher, directory: directory)

        #expect(await downloader.download(Self.report, scope: Self.scope) == .unavailable(.tooLarge(size: 2_000)))
        #expect(await fetcher.readCount == 0)
    }

    @Test("缺檔、存取規則不允許、主機不支援各自回報，不送讀取")
    func refusals() async {
        let fetcher = FakeHostFileFetcher(files: [:])
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: fetcher, directory: directory)

        #expect(await downloader.download(Self.report, scope: Self.scope) == .unavailable(.missing))
        #expect(await downloader.download("/Users/demo/.ssh/id_ed25519", scope: Self.scope) == .unavailable(.denied))
        let unsupported = HostFileDownloader(fetcher: UnsupportedHostFileFetcher(), directory: directory)
        #expect(await unsupported.download(Self.report, scope: Self.scope) == .unavailable(.unsupported))
        #expect(await fetcher.readCount == 0)
    }

    @Test("下載中取消：回報取消，不留下半個檔案;之後再開會從頭下載", .timeLimit(.minutes(1)))
    func cancellationLeavesNoPartialFile() async throws {
        let pdf = Self.bytes(HostFileFetchLimits.chunkSize * 3)
        let gate = GatedHostFileFetcher(FakeHostFileFetcher(files: [Self.report: pdf]))
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: gate, directory: directory)

        let download = Task { await downloader.download(Self.report, scope: Self.scope) }
        await gate.waitUntilReadIsHeld()
        download.cancel()
        await gate.release()

        #expect(await download.value == .unavailable(.cancelled))
        let leftovers = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        #expect(leftovers.isEmpty, "取消後不留檔案:\(leftovers)")

        await gate.stopHolding()
        guard case .downloaded(let file, _) = await downloader.download(Self.report, scope: Self.scope) else { Issue.record("沒有下載"); return }
        #expect(try Data(contentsOf: file) == pdf)
    }

    @Test("下載途中 Agent 覆寫：重新查狀態後下載新版本，不拼出兩個版本")
    func overwrittenWhileDownloading() async throws {
        let fetcher = FakeHostFileFetcher(files: [Self.report: Self.bytes(HostFileFetchLimits.chunkSize + 1)])
        await fetcher.overwriteBeforeNextRead(Self.report, with: Data("new".utf8))
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = HostFileDownloader(fetcher: fetcher, directory: directory)

        guard case .downloaded(let file, _) = await downloader.download(Self.report, scope: Self.scope) else { Issue.record("沒有下載"); return }
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }
}

/// 收進度回報(測試用)。
final class ProgressLog: @unchecked Sendable {
    struct Entry: Equatable {
        var received: Int
        var total: Int
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] { lock.withLock { storage } }

    func append(_ received: Int, _ total: Int) {
        lock.withLock { storage.append(Entry(received: received, total: total)) }
    }
}

/// 讀取前停住，直到測試放行(模擬下載進行中)。
actor GatedHostFileFetcher: HostFileFetching {
    private let base: FakeHostFileFetcher
    private var isHolding = true
    private var heldRead: CheckedContinuation<Void, Never>?
    private var readHeldWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ base: FakeHostFileFetcher) {
        self.base = base
    }

    func status(of target: HostFileTarget) async throws -> HostFileStatus {
        try await base.status(of: target)
    }

    func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        if isHolding, offset > 0 {
            await withCheckedContinuation { continuation in
                heldRead = continuation
                readHeldWaiters.forEach { $0.resume() }
                readHeldWaiters = []
            }
        }
        return try await base.read(target, version: version, offset: offset, length: length)
    }

    /// 等到第二塊的讀取停住。
    func waitUntilReadIsHeld() async {
        if heldRead != nil { return }
        await withCheckedContinuation { readHeldWaiters.append($0) }
    }

    func release() {
        heldRead?.resume()
        heldRead = nil
    }

    func stopHolding() {
        isHolding = false
        release()
    }
}
