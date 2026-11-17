#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing
import UniformTypeIdentifiers

/// 在對話畫面附加圖片並送出(行為規格 F6.5、F7;#16)。herdr 走假主機;上傳腳本在本機暫存家目錄以真的 `/bin/sh` 跑。
@MainActor
@Suite("對話附加圖片")
struct ConversationImageTests {
    static let bridge = HerdrCommand.bridge()

    struct Setup {
        let base: ConversationSendTests.Setup
        let uploads: LocalShellHost
        let store: FileAttachmentStore
        var model: ConversationModel { base.model }
    }

    /// 開啟並讀完一次。`uploadChannel` 預設是另一個暫存家目錄(上傳走 stdin)。
    static func opened(
        sleeper: RecordingSleeper = RecordingSleeper(), interruptAfter: Int? = nil
    ) async throws -> Setup {
        let uploads = try LocalShellHost.temporary(feedsStdin: true)
        let channel: any HostChannel = interruptAfter.map { InterruptingChannel(base: uploads, failAfter: $0) } ?? uploads
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let names = NameSequence()
        let base = try await ConversationSendTests.opened(sleeper: sleeper) { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                images: ComposerImages(uploader: ImageUploader(channel: channel), store: store, makeName: { names.next() }),
                sleep: sleeper.sleep
            )
        }
        return Setup(base: base, uploads: uploads, store: store)
    }

    static func uploadedFiles(_ setup: Setup) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: setup.uploads.url(".purrdr/uploads").path(percentEncoded: false))) ?? []).sorted()
    }

    static func uploadPath(_ setup: Setup, _ name: String) -> String {
        let home = setup.uploads.home.path(percentEncoded: false)
        return (home.hasSuffix("/") ? home : home + "/") + ".purrdr/uploads/" + name
    }

    // MARK: - 加入

    @Test("加入圖片：長邊縮到 2048px 以內、重新編碼成 JPEG,手機上留一份副本")
    func addingResizesToJPEG() async throws {
        let setup = try await Self.opened()

        await setup.model.addImages([TestImage.png(width: 4000, height: 1000)])

        let attachment = try #require(setup.model.attachments.first)
        #expect(attachment.fileName.value == "img-1.jpg")
        #expect(attachment.pixelWidth == 2048)
        #expect(attachment.pixelHeight == 512)
        let copy = try #require(setup.store.url(of: attachment.fileName.value))
        let source = try #require(CGImageSourceCreateWithURL(copy as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @Test("一則最多 4 張：滿了再加會提示，不加入")
    func atMostFourImages() async throws {
        let setup = try await Self.opened()
        let image = TestImage.png(width: 10, height: 10)

        await setup.model.addImages([image, image, image])
        #expect(setup.model.remainingImageSlots == 1)
        await setup.model.addImages([image, image])

        #expect(setup.model.attachments.count == 4)
        #expect(setup.model.remainingImageSlots == 0)
        #expect(setup.model.notice == .imageLimit)
    }

    @Test("讀不出圖片的資料不加入，並提示")
    func unreadableImage() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([Data("not an image".utf8)])
        #expect(setup.model.attachments.isEmpty)
        #expect(setup.model.notice == .imageUnreadable)
    }

    @Test("單張上限以原始圖片判斷：剛好 20 MB 加入，超過 1 byte 就不加入並提示(縮小後再小也一樣)")
    func originalImageSizeLimit() async throws {
        let setup = try await Self.opened()
        let limit = 20 * 1024 * 1024
        let image = TestImage.png(width: 10, height: 10)
        // PNG 讀到 IEND 為止，後面補的 bytes 不影響解碼。
        let atLimit = image + Data(count: limit - image.count)
        let overLimit = image + Data(count: limit + 1 - image.count)

        await setup.model.addImages([atLimit])
        #expect(setup.model.attachments.count == 1)
        #expect(setup.model.notice == nil)
        await setup.model.addImages([overLimit])

        #expect(setup.model.attachments.count == 1)
        #expect(setup.model.notice == .imageTooLarge)
    }

    // MARK: - 送出

    @Test("只有圖片也可送：先上傳，prompt 是每張一行絕對路徑;送出被接受後附件清空，回音帶圖片")
    func sendsImageOnlyPrompt() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10)])
        #expect(setup.model.canSend)
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        #expect(Self.uploadedFiles(setup) == ["img-1.jpg"])
        let path = Self.uploadPath(setup, "img-1.jpg")
        let requests = await ConversationSendTests.promptRequests(setup.base)
        #expect(requests.count == 1)
        #expect(requests.first?.contains(#""text":"\#(path)""#) == true)
        #expect(setup.model.attachments.isEmpty)
        let echo = try #require(setup.model.echoes.first)
        #expect(echo.imageCount == 1)
        #expect(echo.imageFiles == ["img-1.jpg"])
        #expect(echo.imagePaths == [path])
    }

    @Test("文字 + 圖片：prompt = 打的字 + 空一行 + 每張一行絕對路徑")
    func sendsTextAndImages() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10), TestImage.png(width: 20, height: 10)])
        setup.model.draft = "這兩張哪裡不同?"
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        let first = Self.uploadPath(setup, "img-1.jpg")
        let second = Self.uploadPath(setup, "img-2.jpg")
        let requests = await ConversationSendTests.promptRequests(setup.base)
        #expect(requests.first?.contains(#""text":"這兩張哪裡不同?\n\n\#(first)\n\#(second)""#) == true)
    }

    @Test("上傳中斷：不送出 prompt,草稿與圖片都保留，提示上傳失敗")
    func interruptedUploadSendsNothing() async throws {
        let setup = try await Self.opened(interruptAfter: 100)
        await setup.model.addImages([TestImage.png(width: 64, height: 64)])
        setup.model.draft = "看這張"
        // 主機準備好收 prompt:若 app 照樣送出，這裡會被用掉。
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.delivered)

        await setup.model.send()

        #expect(await ConversationSendTests.promptRequests(setup.base).isEmpty)
        #expect(await setup.base.host.bridge.executions.count == 1)  // 只有開啟時的那次 snapshot
        #expect(await setup.base.host.bridge.unmetExpectations.count == 2)
        #expect(setup.model.draft == "看這張")
        #expect(setup.model.attachments.count == 1)
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.notice == .uploadFailed)
        #expect(!setup.model.isSending)
        await setup.uploads.waitUntilFinished()
        #expect(Self.uploadedFiles(setup).isEmpty)
    }

    @Test("什麼都沒送出(agent 在等回答):草稿與圖片保留;再送一次不重傳已上傳的圖片")
    func keepsUploadedImagesWhenNothingSent() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10)])
        setup.model.draft = "這是什麼"
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: PromptReplies.error("agent_blocked", "agent is blocked"))

        await setup.model.send()

        #expect(setup.model.draft == "這是什麼")
        #expect(setup.model.attachments.count == 1)
        #expect(setup.model.attachments.first?.uploadedPath == Self.uploadPath(setup, "img-1.jpg"))
        let uploadsBefore = setup.uploads.commands.count

        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.delivered)
        await setup.model.send()

        #expect(setup.uploads.commands.count == uploadsBefore)
        #expect(setup.model.attachments.isEmpty)
    }

    @Test("重試送同樣文字與已上傳的路徑，不重傳")
    func retrySendsUploadedPaths() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10)])
        setup.model.draft = "hi"
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        await setup.model.send()
        let echo = try #require(setup.model.echoes.first)
        #expect(echo.state == .failed(.noResponse))

        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.snapshot())
        await setup.base.host.bridge.expect(Self.bridge, reply: ConversationSendTests.delivered)
        await setup.model.retry(echoID: echo.id)

        let path = Self.uploadPath(setup, "img-1.jpg")
        let requests = await ConversationSendTests.promptRequests(setup.base)
        #expect(requests.count == 2)
        #expect(requests.last?.contains(#""text":"hi\n\n\#(path)""#) == true)
        #expect(setup.uploads.commands.count == 1)
    }

    @Test("移除附件;送出中不能移除")
    func removesAttachment() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10), TestImage.png(width: 10, height: 10)])
        let first = try #require(setup.model.attachments.first)

        setup.model.removeAttachment(first.id)

        #expect(setup.model.attachments.map(\.fileName.value) == ["img-2.jpg"])
    }

    @Test("離開聊天再回來：圖片附件與草稿一起保留")
    func attachmentsSurviveLeavingChat() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10)])

        let reopened = ConversationModel(
            client: HerdrClient(channel: setup.base.host), transcripts: TranscriptReader(channel: setup.base.host),
            paneID: ConversationSendTests.paneID, knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
            drafts: setup.base.drafts, images: ComposerImages(uploader: ImageUploader(channel: setup.uploads), store: setup.store)
        )

        #expect(reopened.attachments.map(\.fileName.value) == ["img-1.jpg"])
    }

    @Test("沒有圖片功能(nil)時不能附加")
    func noImagesWithoutUploader() async throws {
        let setup = try await ConversationSendTests.opened()
        #expect(!setup.model.canAttachImages)
    }

    @Test("泡泡的圖片依主機路徑的檔名找手機上的副本")
    func localCopyForHostPath() async throws {
        let setup = try await Self.opened()
        await setup.model.addImages([TestImage.png(width: 10, height: 10)])

        #expect(setup.model.localImage(forHostPath: "/home/me/.purrdr/uploads/img-1.jpg") == setup.store.url(of: "img-1.jpg"))
        #expect(setup.model.localImage(forHostPath: "/home/me/.purrdr/uploads/other-1.jpg") == nil)
        #expect(setup.model.localImage(forHostPath: "/home/me/.purrdr/uploads/../x.jpg") == nil)
    }
}

/// 依序產生 `img-1.jpg`、`img-2.jpg`…
final class NameSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> UploadFileName {
        lock.withLock {
            count += 1
            return UploadFileName("img-\(count).jpg")!
        }
    }
}

enum TestImage {
    /// 指定大小的單色 PNG(重新編碼成 JPEG 後仍有數百 bytes,超過上傳中斷點)。
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.85, green: 0.12, blue: 0.21, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
#endif
