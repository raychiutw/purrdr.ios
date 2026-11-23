import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機上傳圖片與檔案(#288):`HTTPSHostConnection` 以主機服務的 `file.upload.start`／`file.upload.chunk` 實作 `HostUploading`。
@Suite("HTTPS 主機上傳")
struct HTTPSHostUploadTests {
    static let name = HostUploadName("mh1a2b3c-k9x2m4p7-report.pdf")!

    private static func start(
        hostServiceVersion: String = "0.7.0", readOnly: Bool = false, uploadedPath: String? = nil
    ) async throws -> FakeHostService {
        var settings = FakeHostService.Settings(hostServiceVersion: hostServiceVersion, uploadedPath: uploadedPath)
        if readOnly { settings.readOnlyTokens = ["token-ok"] }
        return try await FakeHostService.start(settings)
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    /// 1 MiB 加 13 bytes:要分兩塊。
    static let twoChunks = Data((0..<(1_048_576 + 13)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    @Test("超過一塊的檔案依序分塊送出，每塊不超過 1 MiB;回傳主機產生的絕對路徑")
    func uploadsInOrderedChunks() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let path = try await Self.connection(service).upload(Self.twoChunks, named: Self.name)

        #expect(path == "/Users/demo/.purrdr/uploads/mh1a2b3c-k9x2m4p7.pdf")
        #expect(service.log.storedUploads == [Self.twoChunks])
        let started = try #require(service.messages(ofType: "file.upload.start").first)
        #expect(started["size"] as? Int == 1_048_589)
        #expect(started["extension"] as? String == "pdf")
        let chunks = service.messages(ofType: "file.upload.chunk")
        #expect(chunks.map { $0["offset"] as? Int } == [0, 1_048_576])
        #expect(chunks.map { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) }?.count } == [1_048_576, 13])
        #expect(chunks.allSatisfy { $0["upload_id"] as? String == started["request_id"] as? String })
    }

    @Test("分塊讀來源:每塊不超過 1 MiB、不整份讀,進度遞增到 1,主機收到的內容相同")
    func streamsSourceInChunks() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let recording = HostUploadTests.RecordingSource(Self.twoChunks)
        let log = HostUploadTests.ProgressLog()

        _ = try await Self.connection(service).upload(recording.source, named: Self.name, progress: { log.add($0) })

        #expect(service.log.storedUploads == [Self.twoChunks])
        #expect(recording.ranges == [0..<1_048_576, 1_048_576..<1_048_589])
        #expect(log.all.last == 1 && log.all == log.all.sorted())
    }

    @Test("沒有副檔名的檔名不帶 extension")
    func nameWithoutExtensionSendsNoExtension() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let path = try await Self.connection(service).upload(Data("hello".utf8), named: HostUploadName("mh1a2b3c-k9x2m4p7-Makefile")!)

        #expect(path == "/Users/demo/.purrdr/uploads/mh1a2b3c-k9x2m4p7")
        let started = try #require(service.messages(ofType: "file.upload.start").first)
        #expect(started["extension"] == nil)
    }

    @Test("空檔案送一塊空的內容，主機收滿後存檔")
    func emptyFileSendsOneEmptyChunk() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        _ = try await Self.connection(service).upload(Data(), named: Self.name)

        #expect(service.log.storedUploads == [Data()])
        #expect(service.messages(ofType: "file.upload.chunk").count == 1)
    }

    @Test("超過 25 MiB:不送出，錯誤種類是 tooLarge")
    func overLimitIsNotSent() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        await #expect(throws: HostUploadError.tooLarge) {
            try await Self.connection(service).upload(Data(count: 26_214_401), named: Self.name)
        }
        #expect(service.messages(ofType: "file.upload.start").isEmpty)
    }

    @Test("主機服務回 upload_too_large:錯誤種類是 tooLarge")
    func hostRejectsTooLarge() async throws {
        // 主機端的上限比 app 小(例如之後調整):以主機的回應為準。
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0", uploadStartError: "upload_too_large"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostUploadError.tooLarge) {
            try await Self.connection(service).upload(Data("hello".utf8), named: Self.name)
        }
    }

    @Test("主機服務 0.7.0 之前沒有上傳：不送出，錯誤是 hostServiceUpdateRequired(更新提示)")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await Self.start(hostServiceVersion: "0.6.2")
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.fileUpload, installedVersion: "0.6.2")) {
            try await Self.connection(service).upload(Data("hello".utf8), named: Self.name)
        }
        #expect(service.messages(ofType: "file.upload.start").isEmpty)
    }

    @Test("唯讀裝置：主機服務拒絕，錯誤種類是 readOnlyDevice")
    func readOnlyDeviceIsRejected() async throws {
        let service = try await Self.start(readOnly: true)
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.readOnlyDevice) {
            try await Self.connection(service).upload(Data("hello".utf8), named: Self.name)
        }
        #expect(service.log.storedUploads.isEmpty)
    }

    @Test("主機回報的路徑不是絕對路徑：unexpectedPath")
    func relativePathIsRejected() async throws {
        let service = try await Self.start(uploadedPath: ".purrdr/uploads/a.pdf")
        defer { Task { await service.stop() } }

        await #expect(throws: HostUploadError.unexpectedPath(".purrdr/uploads/a.pdf")) {
            try await Self.connection(service).upload(Data("hello".utf8), named: Self.name)
        }
    }
}
