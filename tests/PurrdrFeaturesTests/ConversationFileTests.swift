import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Synchronization
import Testing

/// 聊天附加一般檔案(#286):以假的上傳到主機測輸入列的行為。
@MainActor
@Suite("對話附加檔案")
struct ConversationFileTests {
    nonisolated static let fileName = HostUploadName("mh1a2b3c-k9x2m4p7-server.log")!
    static let uploadedPath = "\(FakeHostUploader.folder)/mh1a2b3c-k9x2m4p7-server.log"

    struct Setup {
        let base: ConversationSendTests.Setup
        let uploader: FakeHostUploader
        let store: FileAttachmentStore
        var model: ConversationModel { base.model }
    }

    /// `names`:依序給每個加入的檔案的上傳檔名;沒給就都是 `fileName`。
    static func opened(uploader: FakeHostUploader = FakeHostUploader(), names: [String]? = nil) async throws -> Setup {
        let sequence = Mutex(names ?? [])
        let nextName: @Sendable (String) -> HostUploadName = { _ in
            guard names != nil else { return Self.fileName }
            return HostUploadName(sequence.withLock { $0.isEmpty ? "mh-extra" : $0.removeFirst() })!
        }
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let base = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                images: ComposerImages(uploader: uploader, store: store, makeFileName: nextName)
            )
        }
        return Setup(base: base, uploader: uploader, store: store)
    }

    @Test("附加檔案：先留在輸入列成一張附件卡，送出才上傳")
    func stagesFileAsAttachment() async throws {
        let setup = try await Self.opened()

        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }

        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.kind == .file)
        #expect(attachment.displayName == "server.log")
        #expect(attachment.byteCount == 5)
        #expect(attachment.fileName == Self.fileName)
        #expect(setup.model.draft.isEmpty)
        #expect(await setup.uploader.uploads.isEmpty)
        #expect(setup.model.loadingFileName == nil)
    }

    @Test("可多選：多個檔案各一張卡，順序照加入")
    func stagesSeveralFiles() async throws {
        let setup = try await Self.opened(names: ["mh-a-one.txt", "mh-b-two.zip"])

        await setup.model.addFile(named: "one.txt", size: 1) { Data("1".utf8) }
        await setup.model.addFile(named: "two.zip", size: 2) { Data("22".utf8) }

        #expect(setup.model.attachments.map(\.displayName) == ["one.txt", "two.zip"])
    }

    @Test("附件總數上限 10：滿了再加提示，不加入")
    func attachmentLimit() async throws {
        let names = (0..<11).map { "mh-\($0)-f.txt" }
        let setup = try await Self.opened(names: names)
        for index in 0..<10 { await setup.model.addFile(named: "f\(index).txt", size: 1) { Data("x".utf8) } }
        #expect(setup.model.remainingImageSlots == 0)

        await setup.model.addFile(named: "extra.txt", size: 1) { Data("x".utf8) }

        #expect(setup.model.attachments.count == ConversationModel.maximumAttachments)
        #expect(setup.model.notice == .attachmentLimit)
    }

    @Test("移除附件卡：留在手機上的副本也刪掉")
    func removingDeletesLocalCopy() async throws {
        let setup = try await Self.opened()
        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }
        let id = try #require(setup.model.attachments.first).id
        #expect(setup.store.url(of: id) != nil)

        setup.model.removeAttachment(id)

        #expect(setup.model.attachments.isEmpty)
        #expect(setup.store.url(of: id) == nil)
    }

    @Test("送出：檔案附件上傳到主機，prompt 帶路徑，回音記下路徑行好配對對話紀錄")
    func sendUploadsFilesAndPromptCarriesPaths() async throws {
        let setup = try await Self.opened()
        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }
        setup.model.draft = "看一下這份 log"
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(ConversationImageTests.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        let uploads = await setup.uploader.uploads
        #expect(uploads.map(\.name) == [Self.fileName])
        #expect(uploads.map(\.data) == [Data("hello".utf8)])
        let requests = await ConversationSendTests.promptRequests(setup.base)
        #expect(requests.first?.contains(#""text":"看一下這份 log\n\n\#(Self.uploadedPath)""#) == true)
        #expect(setup.model.attachments.isEmpty)
        let echo = try #require(setup.model.echoes.first)
        #expect(echo.imageCount == 0)
        #expect(echo.filePaths == [Self.uploadedPath])
        #expect(setup.store.url(of: Self.fileName.value) == nil)
    }

    @Test("挑到的是圖片檔(副檔名 png/jpg…)：走圖片附件，不當一般檔案")
    func imageFilesBecomeImageAttachments() async throws {
        let setup = try await Self.opened()

        await setup.model.addFile(named: "shot.PNG", size: nil) { TestImage.png(width: 10, height: 10) }

        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.kind == .image)
    }

    @Test("已知大小超過上限：不讀內容、不上傳，提示上限與檔案大小")
    func rejectsKnownOversizedFile() async throws {
        let setup = try await Self.opened()
        let size = HostUploadLimit.maximumFileSize + 1
        let loaded = LockedNames()

        await setup.model.addFile(named: "huge.zip", size: size) {
            loaded.append("loaded")
            return Data()
        }

        #expect(setup.model.notice == .fileTooLarge(size: size, limit: HostUploadLimit.maximumFileSize))
        #expect(loaded.names.isEmpty)
        #expect(await setup.uploader.uploads.isEmpty)
        #expect(setup.model.attachments.isEmpty)
    }

    @Test("讀出的內容超過上限(事先不知道大小)也不上傳")
    func rejectsLoadedOversizedFile() async throws {
        let setup = try await Self.opened()
        let size = HostUploadLimit.maximumFileSize + 1

        await setup.model.addFile(named: "huge.zip", size: nil) { Data(count: size) }

        #expect(setup.model.notice == .fileTooLarge(size: size, limit: HostUploadLimit.maximumFileSize))
        #expect(await setup.uploader.uploads.isEmpty)
    }

    @Test("讀不到檔案：提示，不上傳")
    func reportsUnreadableFile() async throws {
        let setup = try await Self.opened()

        await setup.model.addFile(named: "gone.txt", size: nil) { throw CocoaError(.fileReadNoSuchFile) }

        #expect(setup.model.notice == .fileUnreadable)
        #expect(await setup.uploader.uploads.isEmpty)
    }

    @Test("送出時上傳失敗：整則不送，草稿與檔案卡保留，提示上傳失敗")
    func uploadFailureKeepsFileAttachment() async throws {
        let setup = try await Self.opened(uploader: FakeHostUploader(failure: HostUploadError.interrupted))
        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }
        setup.model.draft = "草稿"

        await setup.model.send()

        #expect(await ConversationSendTests.promptRequests(setup.base).isEmpty)
        #expect(setup.model.notice == .uploadFailed)
        #expect(setup.model.draft == "草稿")
        #expect(setup.model.attachments.count == 1)
    }

    @Test("HTTPS 主機的主機服務太舊：送出時提示更新主機服務，檔案卡保留(#288)")
    func olderHostServiceAsksForUpdate() async throws {
        let failure = HostServiceError.hostServiceUpdateRequired(.fileUpload, installedVersion: "0.6.2")
        let setup = try await Self.opened(uploader: FakeHostUploader(failure: failure))
        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }
        setup.model.draft = "草稿"

        await setup.model.send()

        #expect(setup.model.notice == .hostServiceUpdateRequired(installedVersion: "0.6.2"))
        #expect(setup.model.attachments.count == 1)
    }

    @Test("更新主機服務的提示沿用主機錯誤的說明")
    func updateNoticeUsesHostErrorText() {
        #expect(SendNotice.hostServiceUpdateRequired(installedVersion: "0.6.2").text
            == HostErrorText.message(for: HostServiceError.hostServiceUpdateRequired(.fileUpload, installedVersion: "0.6.2")))
    }

    @Test("有上傳到主機的主機才能附加檔案")
    func needsUploader() async throws {
        #expect(try await Self.opened().model.canAttachFiles)
        #expect(try await ConversationSendTests.opened().model.canAttachFiles == false)
    }

    @Test("唯讀裝置：不能附加檔案，也不上傳")
    func readOnlyDeviceCannotAttachFiles() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let connection = ConversationReadOnlyTests.ReadOnlyHostConnection(base: SSHHostConnection(channel: host), reportsReadOnly: true)
        let uploader = FakeHostUploader()
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(channel: host), paneID: ConversationModelTests.paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock,
            images: ComposerImages(uploader: uploader, store: store, makeFileName: { _ in Self.fileName })
        )
        await host.bridge.expect(ConversationReadOnlyTests.bridge, reply: ConversationReadOnlyTests.snapshot(status: "done"))
        await model.poll()

        await model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }

        #expect(model.isReadOnly)
        #expect(!model.canAttachFiles)
        #expect(await uploader.uploads.isEmpty)
        #expect(model.draft.isEmpty)
    }
}

/// 從 `@Sendable` 閉包記下字串。
private final class LockedNames: Sendable {
    private let storage = Mutex<[String]>([])

    var names: [String] { storage.withLock { $0 } }

    func append(_ name: String) {
        storage.withLock { $0.append(name) }
    }
}
