import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 附件 module(#562)的測試:圖片、檔案、影片、行動網路確認、逐檔上傳與草稿保存都直接對它,不經聊天 model。
@MainActor
@Suite("附件 module")
struct ComposerAttachmentsTests {
    struct Setup {
        let attachments: ComposerAttachments
        let uploader: FakeHostUploader
        let store: FileAttachmentStore
        let drafts: DraftStore
    }

    static func make(
        compressor: (any VideoCompressing)? = nil, onCellular: Bool = false, drafts: DraftStore = DraftStore(), uploader: FakeHostUploader = FakeHostUploader()
    ) -> Setup {
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let counter = NameCounter()
        let attachments = ComposerAttachments(
            dependencies: ComposerAttachments.Dependencies(
                uploader: uploader, store: store, makeName: { counter.nextImage() }, makeFileName: { _ in counter.nextFile() },
                videoCompressor: compressor, isOnCellular: { onCellular }),
            drafts: drafts, chatKey: "pane-1")
        return Setup(attachments: attachments, uploader: uploader, store: store, drafts: drafts)
    }

    final class NameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var images = 0
        private var files = 0
        func nextImage() -> UploadFileName { lock.withLock { images += 1; return UploadFileName("img-\(images).jpg")! } }
        func nextFile() -> HostUploadName { lock.withLock { files += 1; return HostUploadName("mh1a2b3c-k9x2m4p\(files)-Demo.mp4")! } }
    }

    nonisolated static func videoSource(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString).mov")
        try Data(count: size).write(to: url)
        return url
    }

    // MARK: 圖片

    @Test("圖片:縮成 JPEG 存手機副本、加進清單並寫進草稿")
    func addsImage() async {
        let setup = Self.make()
        await setup.attachments.addImages([TestImage.png(width: 64, height: 48)])

        let item = setup.attachments.items.first
        #expect(setup.attachments.items.count == 1)
        #expect(item?.kind == .image)
        #expect(item.flatMap { setup.store.url(of: $0.fileName.value) } != nil)
        #expect(setup.drafts.attachments(chatKey: "pane-1") == setup.attachments.items)
    }

    @Test("圖片:讀不出來提示、不加入")
    func unreadableImage() async {
        let setup = Self.make()
        await setup.attachments.addImages([Data("not an image".utf8)])
        #expect(setup.attachments.items.isEmpty)
        #expect(setup.attachments.takeNotice() == .imageUnreadable)
    }

    @Test("圖片:超過張數上限的不加入並提示")
    func imageLimit() async {
        let setup = Self.make()
        let png = TestImage.png(width: 16, height: 16)
        await setup.attachments.addImages(Array(repeating: png, count: ComposerAttachments.maximumCount + 2))
        #expect(setup.attachments.items.count == ComposerAttachments.maximumCount)
        #expect(setup.attachments.remainingSlots == 0)
        #expect(setup.attachments.takeNotice() == .attachmentLimit)
    }

    @Test("沒有上傳器:不能附加,也不加入")
    func unavailableWithoutDependencies() async {
        let attachments = ComposerAttachments(dependencies: nil, drafts: DraftStore(), chatKey: "pane-1")
        await attachments.addImages([TestImage.png(width: 16, height: 16)])
        #expect(!attachments.isAvailable)
        #expect(attachments.items.isEmpty)
    }

    // MARK: 檔案

    @Test("檔案:存副本、成一張卡;超過上限不讀內容")
    func addsFile() async {
        let setup = Self.make()
        await setup.attachments.addFile(named: "notes.txt", size: 5, isReadOnly: false) { Data("hello".utf8) }
        #expect(setup.attachments.items.first?.kind == .file)
        #expect(setup.attachments.items.first?.displayName == "notes.txt")

        let limit = HostUploadLimit.maximumFileSize
        await setup.attachments.addFile(named: "big.bin", size: limit + 1, isReadOnly: false) { Issue.record("不該讀內容"); return Data() }
        #expect(setup.attachments.items.count == 1)
        #expect(setup.attachments.takeNotice() == .fileTooLarge(size: limit + 1, limit: limit))
    }

    @Test("檔案:唯讀裝置不能附加")
    func readOnlyBlocksFiles() async {
        let setup = Self.make()
        await setup.attachments.addFile(named: "notes.txt", size: 5, isReadOnly: true) { Data("hello".utf8) }
        #expect(setup.attachments.items.isEmpty)
    }

    @Test("檔案:圖片副檔名走圖片附件")
    func imageExtensionBecomesImage() async {
        let setup = Self.make()
        await setup.attachments.addFile(named: "shot.png", size: nil, isReadOnly: false) { TestImage.png(width: 16, height: 16) }
        #expect(setup.attachments.items.first?.kind == .image)
    }

    @Test("移除檔案附件:刪掉手機副本、草稿同步")
    func removal() async throws {
        let setup = Self.make()
        await setup.attachments.addFile(named: "notes.txt", size: 5, isReadOnly: false) { Data("hello".utf8) }
        let item = try #require(setup.attachments.items.first)
        setup.attachments.remove(item.id)
        #expect(setup.attachments.items.isEmpty)
        #expect(setup.store.url(of: item.fileName.value) == nil)
        #expect(setup.drafts.attachments(chatKey: "pane-1").isEmpty)
    }

    // MARK: 影片

    @Test("影片:小於上限原樣加入,帶長度與縮圖")
    func smallVideoStaysAsIs() async throws {
        let compressor = FakeVideoCompressor(duration: 12)
        let setup = Self.make(compressor: compressor)
        await setup.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: 1_000)) }
        let item = try #require(setup.attachments.items.first)
        #expect(item.duration == 12)
        #expect(item.thumbnailFileName != nil)
        #expect(compressor.requested.isEmpty)
        #expect(setup.attachments.videoPreparation == nil)
    }

    @Test("影片:超過上限由高到低壓,第一個放得下的就用")
    func compressesLadder() async throws {
        let limit = HostUploadLimit.maximumFileSize
        let compressor = FakeVideoCompressor(duration: 10, sizes: [.high: limit + 1, .medium: 1_000])
        let setup = Self.make(compressor: compressor)
        await setup.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: limit + 1)) }
        #expect(compressor.requested == [.high, .medium])
        #expect(setup.attachments.items.first?.displayName == "Demo.mp4")
    }

    @Test("影片:太長提示、不加入")
    func tooLongVideo() async throws {
        let limit = HostUploadLimit.maximumFileSize
        let setup = Self.make(compressor: FakeVideoCompressor(duration: 100_000))
        await setup.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: limit + 1)) }
        #expect(setup.attachments.items.isEmpty)
        #expect(setup.attachments.takeNotice() == .videoTooLong)
    }

    @Test("影片:取消準備不加入、不提示")
    func cancelVideo() async throws {
        let limit = HostUploadLimit.maximumFileSize
        let compressor = FakeVideoCompressor(duration: 10, sizes: [.high: 1_000])
        compressor.hold()
        let setup = Self.make(compressor: compressor)
        let task = Task { @MainActor in
            await setup.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: limit + 1)) }
        }
        while setup.attachments.videoPreparation?.phase != .shrinking { try await Task.sleep(for: .milliseconds(5)) }
        setup.attachments.cancelVideoPreparation()
        await task.value
        #expect(setup.attachments.items.isEmpty)
        #expect(setup.attachments.videoPreparation == nil)
        #expect(setup.attachments.takeNotice() == nil)
    }

    @Test("沒有壓縮器或唯讀:不能附加影片")
    func noCompressor() {
        #expect(!Self.make().attachments.canAttachVideos(isReadOnly: false))
        #expect(Self.make(compressor: FakeVideoCompressor()).attachments.canAttachVideos(isReadOnly: false))
        #expect(!Self.make(compressor: FakeVideoCompressor()).attachments.canAttachVideos(isReadOnly: true))
    }

    // MARK: 行動網路確認

    @Test("行動網路:大影片要先確認;Wi-Fi、小影片不用")
    func cellularConfirmation() async throws {
        let big = ComposerAttachments.cellularWarningBytes + 1
        let cellular = Self.make(compressor: FakeVideoCompressor(), onCellular: true)
        await cellular.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: big)) }

        #expect(cellular.attachments.requestCellularConfirmation())
        #expect(cellular.attachments.cellularUploadWarning == big)
        cellular.attachments.dismissCellularWarning()
        #expect(cellular.attachments.cellularUploadWarning == nil)

        cellular.attachments.beginConfirmedUpload()
        #expect(!cellular.attachments.requestCellularConfirmation(), "確認後這一次不再問")
        cellular.attachments.endConfirmedUpload()
        #expect(cellular.attachments.requestCellularConfirmation(), "下一次又要問")

        let wifi = Self.make(compressor: FakeVideoCompressor(), onCellular: false)
        await wifi.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: big)) }
        #expect(!wifi.attachments.requestCellularConfirmation())

        let small = Self.make(compressor: FakeVideoCompressor(), onCellular: true)
        await small.attachments.addPickedVideo(displayName: "Demo.mov", isReadOnly: false) { VideoSourceFile(try Self.videoSource(size: 1_000)) }
        #expect(!small.attachments.requestCellularConfirmation())
    }

    // MARK: 逐檔上傳

    @Test("上傳:依序上傳,已上傳的沿用路徑不重傳")
    func uploadsInOrderAndReusesPaths() async throws {
        let setup = Self.make()
        await setup.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        await setup.attachments.addFile(named: "b.txt", size: 1, isReadOnly: false) { Data("b".utf8) }

        let first = try await setup.attachments.upload()
        #expect(first.count == 2)
        #expect(await setup.uploader.uploads.count == 2)
        #expect(setup.attachments.items.allSatisfy { $0.uploadedPath != nil })

        let second = try await setup.attachments.upload()
        #expect(second == first)
        #expect(await setup.uploader.uploads.count == 2, "已上傳的不重傳")
        #expect(setup.attachments.uploadProgress == nil)
    }

    @Test("上傳失敗:丟出錯誤、附件留著;錯誤對應提示")
    func uploadFailure() async throws {
        let uploader = FakeHostUploader(failure: HostServiceError.unsupported("upload"))
        let setup = Self.make(uploader: uploader)
        await setup.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        await #expect(throws: (any Error).self) { try await setup.attachments.upload() }
        #expect(setup.attachments.items.count == 1)

        #expect(ComposerAttachments.notice(forUploadError: CocoaError(.fileReadNoSuchFile)) == .uploadFailed)
        #expect(
            ComposerAttachments.notice(forUploadError: HostServiceError.hostServiceUpdateRequired(.directoryBrowsing, installedVersion: "0.1.0"))
                == .hostServiceUpdateRequired(installedVersion: "0.1.0"))
    }

    @Test("取消上傳:丟 CancellationError、附件留著")
    func cancelUpload() async throws {
        let uploader = FakeHostUploader()
        await uploader.hold()
        let setup = Self.make(uploader: uploader)
        await setup.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        let task = Task { @MainActor in try await setup.attachments.upload() }
        while setup.attachments.uploadProgress == nil { try await Task.sleep(for: .milliseconds(5)) }
        setup.attachments.cancelUpload()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(setup.attachments.items.count == 1)
    }

    // MARK: 與安全送出的契約

    nonisolated static let results: [SafeSend.Result] = [
        .delivered, .submittedCommand, .noResponse, .unconfirmed(.connectionLost),
        .notSent(.agentGone), .notSent(.conversationChanged), .notSent(.rejected("x")), .notSent(.readOnlyDevice),
    ]

    @Test("契約:沒送出就保留附件(含手機副本與已上傳路徑),送出或可能送出就收尾", arguments: results)
    func settleFollowsSafeSend(result: SafeSend.Result) async throws {
        let setup = Self.make()
        await setup.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        let sent = setup.attachments.items
        _ = try await setup.attachments.upload()
        let uploaded = setup.attachments.items

        setup.attachments.settle(sent: sent, after: result)

        if result.sentNothing {
            #expect(setup.attachments.items == uploaded, "附件與已上傳的路徑都留著,重送不重傳")
            #expect(setup.store.url(of: sent[0].fileName.value) != nil)
            #expect(setup.drafts.attachments(chatKey: "pane-1") == uploaded)
        } else {
            #expect(setup.attachments.items.isEmpty)
            #expect(setup.store.url(of: sent[0].fileName.value) == nil)
            #expect(setup.drafts.attachments(chatKey: "pane-1").isEmpty)
        }
    }

    @Test("契約:送出期間新加的附件不被收尾帶走")
    func settleKeepsLateAdditions() async throws {
        let setup = Self.make()
        await setup.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        let sent = setup.attachments.items
        await setup.attachments.addFile(named: "b.txt", size: 1, isReadOnly: false) { Data("b".utf8) }
        setup.attachments.settle(sent: sent, after: .delivered)
        #expect(setup.attachments.items.map(\.displayName) == ["b.txt"])
    }

    // MARK: 草稿

    @Test("草稿:同一個聊天重開時還原附件")
    func restoresFromDrafts() async {
        let drafts = DraftStore()
        let first = Self.make(drafts: drafts)
        await first.attachments.addFile(named: "a.txt", size: 1, isReadOnly: false) { Data("a".utf8) }
        let again = ComposerAttachments(
            dependencies: ComposerAttachments.Dependencies(uploader: first.uploader, store: first.store), drafts: drafts, chatKey: "pane-1")
        #expect(again.items == first.attachments.items)
    }
}
