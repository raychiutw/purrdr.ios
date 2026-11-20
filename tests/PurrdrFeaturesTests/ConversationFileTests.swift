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
    static let fileName = HostUploadName("mh1a2b3c-k9x2m4p7-server.log")!
    static let uploadedPath = "\(FakeHostUploader.folder)/mh1a2b3c-k9x2m4p7-server.log"

    struct Setup {
        let base: ConversationSendTests.Setup
        let uploader: FakeHostUploader
        var model: ConversationModel { base.model }
    }

    static func opened(uploader: FakeHostUploader = FakeHostUploader()) async throws -> Setup {
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let base = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                images: ComposerImages(uploader: uploader, store: store, makeFileName: { _ in Self.fileName })
            )
        }
        return Setup(base: base, uploader: uploader)
    }

    @Test("附加檔案：上傳到主機，主機上的路徑插入輸入框")
    func uploadsAndInsertsPath() async throws {
        let setup = try await Self.opened()

        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }

        #expect(setup.model.draft == Self.uploadedPath)
        let uploads = await setup.uploader.uploads
        #expect(uploads.map(\.name) == [Self.fileName])
        #expect(uploads.map(\.data) == [Data("hello".utf8)])
        #expect(setup.model.uploadingFileName == nil)
    }

    @Test("已有文字時路徑空一行接在後面，不蓋掉打的字")
    func appendsPathAfterTypedText() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "看一下這份 log"

        await setup.model.addFile(named: "server.log", size: nil) { Data("hello".utf8) }

        #expect(setup.model.draft == "看一下這份 log\n\n\(Self.uploadedPath)")
    }

    @Test("檔名交給檔名產生器的是原始檔名")
    func passesOriginalNameToNameMaker() async throws {
        let uploader = FakeHostUploader()
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let received = LockedNames()
        let base = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                images: ComposerImages(uploader: uploader, store: store, makeFileName: { original in
                    received.append(original)
                    return Self.fileName
                })
            )
        }

        await base.model.addFile(named: "build log (1).txt", size: 1) { Data("x".utf8) }

        #expect(received.names == ["build log (1).txt"])
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
        #expect(setup.model.draft.isEmpty)
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

    @Test("上傳失敗：提示，輸入框不變")
    func reportsUploadFailure() async throws {
        let setup = try await Self.opened(uploader: FakeHostUploader(failure: HostUploadError.interrupted))
        setup.model.draft = "草稿"

        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }

        #expect(setup.model.notice == .fileUploadFailed)
        #expect(setup.model.draft == "草稿")
    }

    @Test("HTTPS 主機的主機服務太舊：提示更新主機服務，輸入框不變(#288)")
    func olderHostServiceAsksForUpdate() async throws {
        let failure = HostServiceError.hostServiceUpdateRequired(.fileUpload, installedVersion: "0.6.2")
        let setup = try await Self.opened(uploader: FakeHostUploader(failure: failure))
        setup.model.draft = "草稿"

        await setup.model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }

        #expect(setup.model.notice == .hostServiceUpdateRequired(installedVersion: "0.6.2"))
        #expect(setup.model.draft == "草稿")
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
