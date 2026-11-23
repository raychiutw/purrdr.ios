import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Synchronization
import Testing

/// 假的壓縮器:每一階輸出事先設定的大小，記下被要求的階。
final class FakeVideoCompressor: VideoCompressing {
    private let state = Mutex(State())
    struct State {
        var duration: TimeInterval = 30
        var sizes: [VideoQuality: Int] = [:]
        var requested: [VideoQuality] = []
        var failure: (any Error)?
        var holds = false
    }

    init(duration: TimeInterval = 30, sizes: [VideoQuality: Int] = [:]) {
        state.withLock { $0.duration = duration; $0.sizes = sizes }
    }

    var requested: [VideoQuality] { state.withLock { $0.requested } }
    func hold() { state.withLock { $0.holds = true } }

    func duration(of source: URL) async throws -> TimeInterval {
        try state.withLock { if let failure = $0.failure { throw failure }; return $0.duration }
    }

    func thumbnail(of source: URL) async -> Data? { Data("thumb".utf8) }

    func compress(_ source: URL, quality: VideoQuality, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (size, holds) = state.withLock { s -> (Int, Bool) in
            s.requested.append(quality)
            return (s.sizes[quality] ?? 1, s.holds)
        }
        progress(0.5)
        if holds {
            // 等到被取消。
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        try Data(count: size).write(to: destination)
    }
}

/// 聊天附加影片(#474):壓縮階梯、上限、進度與取消，以假壓縮器與假上傳測輸入列的行為。
@MainActor
@Suite("對話附加影片")
struct ConversationVideoTests {
    nonisolated static let limit = HostUploadLimit.maximumFileSize
    nonisolated static let fileName = HostUploadName("mh1a2b3c-k9x2m4p7-Demo.mp4")!

    struct Setup {
        let base: ConversationSendTests.Setup
        let uploader: FakeHostUploader
        let store: any AttachmentStore
        let compressor: FakeVideoCompressor?
        var model: ConversationModel { base.model }
    }

    static func opened(compressor: FakeVideoCompressor?, onCellular: Bool = false, wrappingStore: ((FileAttachmentStore) -> any AttachmentStore)? = nil) async throws -> Setup {
        let uploader = FakeHostUploader()
        let fileStore = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let store: any AttachmentStore = wrappingStore?(fileStore) ?? fileStore
        let base = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                images: ComposerImages(
                    uploader: uploader, store: store, makeFileName: { _ in Self.fileName }, videoCompressor: compressor, isOnCellular: { onCellular })
            )
        }
        return Setup(base: base, uploader: uploader, store: store, compressor: compressor)
    }

    /// 暫時的來源影片檔(內容是 `size` 個 0)。
    nonisolated static func source(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString).mov")
        try Data(count: size).write(to: url)
        return url
    }

    /// 記錄 `save(movingFile:)` 在哪個執行緒被呼叫(影片最多 25 MiB,不能在主執行緒搬)。
    final class ThreadRecordingStore: AttachmentStore {
        let base: FileAttachmentStore
        let savedOnMain = Mutex<[Bool]>([])
        init(_ base: FileAttachmentStore) { self.base = base }
        func save(_ data: Data, as name: String) throws {
            savedOnMain.withLock { $0.append(Thread.isMainThread) }
            try base.save(data, as: name)
        }
        func save(movingFile source: URL, as name: String) throws {
            savedOnMain.withLock { $0.append(Thread.isMainThread) }
            try base.save(movingFile: source, as: name)
        }
        func url(of name: String) -> URL? { base.url(of: name) }
        func remove(_ name: String) { base.remove(name) }
    }

    /// 暫存資料夾裡的來源影片(像挑選器那樣放在 `purrdr-picked-<UUID>/` 底下)。
    nonisolated static func pickedSource(size: Int, name: String = "IMG_0001.mov") throws -> (file: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "purrdr-picked-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data(count: size).write(to: file)
        return (file, folder)
    }

    @Test("取消後挑選器才回傳影片:不加入、暫存資料夾整個刪掉,取消當下輸入列就恢復")
    func lateLoadAfterCancelIsDiscarded() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        let picked = try Self.pickedSource(size: 1_000)
        let release = Mutex(false)

        let adding = Task {
            await setup.model.addPickedVideo(displayName: "Demo.mov") {
                // 挑選器不回應取消:一直等到放行才回傳。
                while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
                return VideoSourceFile(picked.file, discarding: picked.folder)
            }
        }
        for _ in 0..<400 where setup.model.videoPreparation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(setup.model.videoPreparation?.phase == .loading)

        setup.model.cancelVideoPreparation()
        #expect(setup.model.videoPreparation == nil, "取消要立刻恢復輸入列,不等挑選器")
        release.withLock { $0 = true }
        await adding.value

        #expect(setup.model.attachments.isEmpty)
        #expect(setup.model.notice == nil)
        #expect(!FileManager.default.fileExists(atPath: picked.folder.path(percentEncoded: false)))
    }

    @Test("加入後連挑選器的暫存資料夾一起刪掉,副檔名依實際格式")
    func removesPickedFolderAndKeepsActualExtension() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        let picked = try Self.pickedSource(size: 1_000, name: "IMG_0002.mp4")

        await setup.model.addPickedVideo(displayName: "Video.mov") { VideoSourceFile(picked.file, discarding: picked.folder) }

        #expect(!FileManager.default.fileExists(atPath: picked.folder.path(percentEncoded: false)))
        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.displayName == "Video.mp4", "實際是 mp4 就不能叫 .mov")
    }

    @Test("搬進手機副本不在主執行緒做")
    func storingDoesNotBlockMainThread() async throws {
        var recorder: ThreadRecordingStore?
        let setup = try await Self.opened(compressor: FakeVideoCompressor()) { base in
            let store = ThreadRecordingStore(base)
            recorder = store
            return store
        }
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 1_000) }
        let saves = recorder?.savedOnMain.withLock { $0 } ?? []
        #expect(!saves.isEmpty && saves.allSatisfy { !$0 }, "影片與縮圖都不在主執行緒存")
    }

    @Test("階梯:依長度略過放不下的階;太長時一階都沒有")
    func candidatesFollowDuration() {
        #expect(VideoQuality.candidates(forDuration: 20, limit: Self.limit) == [.high, .medium, .low])
        #expect(VideoQuality.candidates(forDuration: 40, limit: Self.limit) == [.medium, .low])
        #expect(VideoQuality.candidates(forDuration: 70, limit: Self.limit) == [.low])
        #expect(VideoQuality.candidates(forDuration: 120, limit: Self.limit).isEmpty)
    }

    @Test("沒超過上限的影片:原樣加成附件卡，不壓縮")
    func smallVideoIsAttachedAsIs() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        let source = try Self.source(size: 1_000)

        await setup.model.addVideo(displayName: "Demo.mov") { source }

        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.kind == .file)
        #expect(attachment.byteCount == 1_000)
        #expect(setup.compressor?.requested.isEmpty == true)
        #expect(setup.model.videoPreparation == nil)
        #expect(setup.model.notice == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)), "挑選器的暫存副本要刪掉")
    }

    @Test("超過上限:由高到低壓,第一個放得下的階就是結果")
    func largeVideoIsShrunkToFirstFittingQuality() async throws {
        let compressor = FakeVideoCompressor(duration: 20, sizes: [.high: Self.limit + 1, .medium: 5_000])
        let setup = try await Self.opened(compressor: compressor)

        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: Self.limit + 10) }

        #expect(compressor.requested == [.high, .medium])
        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.byteCount == 5_000)
        #expect(attachment.displayName == "Demo.mp4")
        #expect(setup.model.notice == nil)
        #expect(setup.store.url(of: attachment.id) != nil)
    }

    @Test("每一階壓完都超過上限:提示，不加入")
    func stillTooLargeAfterAllQualities() async throws {
        let compressor = FakeVideoCompressor(duration: 70, sizes: [.low: Self.limit + 1])
        let setup = try await Self.opened(compressor: compressor)

        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: Self.limit * 4) }

        #expect(compressor.requested == [.low])
        #expect(setup.model.notice == .videoTooLong)
        #expect(setup.model.attachments.isEmpty)
    }

    @Test("太長(估計最低畫質也放不下):不壓縮就提示")
    func tooLongSkipsCompression() async throws {
        let compressor = FakeVideoCompressor(duration: 900)
        let setup = try await Self.opened(compressor: compressor)

        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: Self.limit * 10) }

        #expect(compressor.requested.isEmpty)
        #expect(setup.model.notice == .videoTooLong)
        #expect(setup.model.attachments.isEmpty)
    }

    @Test("取不出影片:提示讀不到")
    func unreadableVideo() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())

        await setup.model.addVideo(displayName: "Demo.mov") { throw CocoaError(.fileReadNoSuchFile) }

        #expect(setup.model.notice == .videoUnreadable)
        #expect(setup.model.videoPreparation == nil)
    }

    @Test("壓縮中:顯示進度;取消後不加入、不提示、不留暫存檔")
    func cancelWhileShrinking() async throws {
        let compressor = FakeVideoCompressor(duration: 20, sizes: [:])
        compressor.hold()
        let setup = try await Self.opened(compressor: compressor)
        let source = try Self.source(size: Self.limit + 10)

        let adding = Task { await setup.model.addVideo(displayName: "Demo.mov") { source } }
        for _ in 0..<400 where setup.model.videoPreparation?.phase != .shrinking { try await Task.sleep(for: .milliseconds(5)) }
        #expect(setup.model.videoPreparation?.phase == .shrinking)
        for _ in 0..<400 where setup.model.videoPreparation?.fraction != 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(setup.model.videoPreparation?.fraction == 0.5)

        setup.model.cancelVideoPreparation()
        await adding.value

        #expect(setup.model.videoPreparation == nil)
        #expect(setup.model.attachments.isEmpty)
        #expect(setup.model.notice == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("附件滿了:提示上限，不開始壓縮")
    func respectsAttachmentLimit() async throws {
        let compressor = FakeVideoCompressor()
        let setup = try await Self.opened(compressor: compressor)
        for _ in 0..<ConversationModel.maximumAttachments {
            await setup.model.addFile(named: "f.txt", size: 1) { Data("x".utf8) }
        }
        // 檔名固定，所以 id 相同:改以已滿的槽數判斷。
        let before = setup.model.attachments.count

        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 10) }

        #expect(setup.model.attachments.count == before)
    }

    @Test("沒有壓縮器:不能附加影片，addVideo 什麼都不做")
    func noCompressorMeansNoVideo() async throws {
        let withCompressor = try await Self.opened(compressor: FakeVideoCompressor())
        #expect(withCompressor.model.canAttachVideos)
        let setup = try await Self.opened(compressor: nil)
        #expect(!setup.model.canAttachVideos)

        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 10) }

        #expect(setup.model.attachments.isEmpty)
    }

    @Test("送出:影片附件與檔案一樣上傳到主機")
    func sendUploadsVideo() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 2_000) }
        setup.model.draft = "看這段錄影"
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        let uploads = await setup.uploader.uploads
        #expect(uploads.map(\.name) == [Self.fileName])
        #expect(uploads.first?.data.count == 2_000)
    }

    @Test("送出時上傳影片:顯示進度;取消後草稿與附件留著、不提示、不送出")
    func cancelWhileUploading() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 2_000) }
        await setup.uploader.hold()
        setup.model.draft = "看這段錄影"

        let sending = Task { await setup.model.send() }
        for _ in 0..<400 where setup.model.uploadProgress?.fraction != 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(setup.model.uploadProgress?.fraction == 0.5)
        #expect(setup.model.uploadProgress?.displayName == "Demo.mp4" || setup.model.uploadProgress?.displayName == "Demo.mov")

        setup.model.cancelUpload()
        await sending.value

        #expect(setup.model.uploadProgress == nil)
        #expect(setup.model.notice == nil, "使用者自己取消不提示")
        #expect(setup.model.draft == "看這段錄影")
        #expect(setup.model.attachments.count == 1, "附件留著可以再送")
        #expect(await setup.uploader.uploads.isEmpty)
    }

    @Test("影片卡:有長度與縮圖;移除附件連縮圖一起刪")
    func videoCardHasDurationAndThumbnail() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor(duration: 42))
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 1_000) }

        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.duration == 42)
        let thumbnail = try #require(attachment.thumbnailFileName)
        #expect(setup.store.url(of: thumbnail) != nil)

        setup.model.removeAttachment(attachment.id)

        #expect(setup.store.url(of: thumbnail) == nil)
        #expect(setup.store.url(of: attachment.id) == nil)
    }

    @Test("送出成功後影片與縮圖的手機副本都刪掉")
    func sendingRemovesThumbnail() async throws {
        let setup = try await Self.opened(compressor: FakeVideoCompressor())
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 1_000) }
        let thumbnail = try #require(setup.model.attachments.first?.thumbnailFileName)
        setup.model.draft = "看"
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        #expect(setup.model.attachments.isEmpty)
        #expect(setup.store.url(of: thumbnail) == nil)
    }

    @Test("行動網路:大影片送出前先提醒,確認才上傳;取消提醒什麼都不動")
    func largeVideoOnCellularAsksFirst() async throws {
        let size = ConversationModel.cellularWarningBytes + 1
        let setup = try await Self.opened(compressor: FakeVideoCompressor(), onCellular: true)
        await setup.model.addVideo(displayName: "Demo.mov") { try Self.source(size: size) }
        setup.model.draft = "看這段"

        await setup.model.send()

        #expect(setup.model.cellularUploadWarning == size, "要提醒這次會用掉多少流量")
        #expect(await setup.uploader.uploads.isEmpty)
        #expect(setup.model.draft == "看這段", "提醒時草稿留著")
        #expect(setup.model.attachments.count == 1)

        setup.model.dismissCellularWarning()
        #expect(setup.model.cellularUploadWarning == nil)
        #expect(await setup.uploader.uploads.isEmpty)

        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)
        await setup.model.send()
        await setup.model.confirmCellularUpload()

        #expect(await setup.uploader.uploads.count == 1)
        #expect(setup.model.cellularUploadWarning == nil)
    }

    @Test("Wi-Fi 或小影片:不提醒")
    func noWarningOnWiFiOrSmallVideo() async throws {
        let wifi = try await Self.opened(compressor: FakeVideoCompressor(), onCellular: false)
        await wifi.model.addVideo(displayName: "Demo.mov") { try Self.source(size: ConversationModel.cellularWarningBytes + 1) }
        wifi.model.draft = "x"
        await wifi.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await wifi.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)
        await wifi.model.send()
        #expect(wifi.model.cellularUploadWarning == nil)
        #expect(await wifi.uploader.uploads.count == 1)

        let small = try await Self.opened(compressor: FakeVideoCompressor(), onCellular: true)
        await small.model.addVideo(displayName: "Demo.mov") { try Self.source(size: 1_000) }
        small.model.draft = "x"
        await small.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await small.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)
        await small.model.send()
        #expect(small.model.cellularUploadWarning == nil)
        #expect(await small.uploader.uploads.count == 1)
    }
}
