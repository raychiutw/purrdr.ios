import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機取檔(#227):`HTTPSHostConnection` 以主機服務的 `file.stat`／`file.read` 實作 `HostFileFetching`,
/// 工作目錄由主機服務自己從 herdr snapshot 取，app 只送路徑。
@Suite("HTTPS 主機取檔")
struct HTTPSHostFileFetchTests {
    static let path = "/Users/demo/Projects/garden-journal/docs/plants.png"
    static let target = HostFileTarget(path: path, root: "/Users/demo/Projects/garden-journal")
    static let version = HostFileVersion(checksum: "9f86d081")

    private static func start(_ replies: [String: [String]], hostServiceVersion: String = "0.4.0") async throws -> FakeHostService {
        try await FakeHostService.start(.init(fileReplies: replies, hostServiceVersion: hostServiceVersion))
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    @Test("查狀態只送路徑，不送 app 端的工作目錄;回報版本與大小")
    func statusSendsOnlyThePath() async throws {
        let service = try await Self.start([
            "file.stat": [#"{"type":"file.stat.result","status":"file","version":"9f86d081","size":5}"#],
        ])
        defer { Task { await service.stop() } }

        let status = try await Self.connection(service).status(of: Self.target)

        #expect(status == .file(version: Self.version, size: 5))
        let sent = try #require(service.messages(ofType: "file.stat").first)
        #expect(sent["path"] as? String == Self.path)
        #expect(sent["root"] == nil)
    }

    @Test("非一般檔案的狀態對應到 HostFileStatus")
    func statusMapsEveryUnavailableStatus() async throws {
        let service = try await Self.start([
            "file.stat": [
                #"{"type":"file.stat.result","status":"missing"}"#,
                #"{"type":"file.stat.result","status":"not_regular_file"}"#,
                #"{"type":"file.stat.result","status":"unreadable"}"#,
                #"{"type":"file.stat.result","status":"denied"}"#,
                #"{"type":"file.stat.result","status":"too_large","size":31457280}"#,
            ],
        ])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        var statuses: [HostFileStatus] = []
        for _ in 0..<5 { statuses.append(try await connection.status(of: Self.target)) }

        #expect(statuses == [.missing, .notRegularFile, .unreadable, .denied, .tooLarge(size: 31_457_280)])
    }

    @Test("依版本讀一塊：送路徑、版本、offset、length,回傳解開 base64 的 bytes")
    func readReturnsDecodedChunk() async throws {
        let service = try await Self.start([
            "file.read": [#"{"type":"file.read.result","status":"file","offset":3,"bytes":"bG8="}"#],
        ])
        defer { Task { await service.stop() } }

        let data = try await Self.connection(service).read(Self.target, version: Self.version, offset: 3, length: 196_608)

        #expect(data == Data("lo".utf8))
        let sent = try #require(service.messages(ofType: "file.read").first)
        #expect(sent["path"] as? String == Self.path)
        #expect(sent["version"] as? String == "9f86d081")
        #expect(sent["offset"] as? Int == 3)
        #expect(sent["length"] as? Int == 196_608)
    }

    @Test("主機上的檔案已不是這個版本：changed")
    func readOfChangedFileThrowsChanged() async throws {
        let service = try await Self.start([
            "file.read": [#"{"type":"error","code":"file_changed","message":"file changed since its status was read"}"#],
        ])
        defer { Task { await service.stop() } }

        await #expect(throws: HostFileFetchError.changed) {
            try await Self.connection(service).read(Self.target, version: Self.version, offset: 0, length: 5)
        }
    }

    @Test("讀取時主機端拒絕：unavailable(denied)")
    func readDeniedByHostThrowsUnavailable() async throws {
        let service = try await Self.start(["file.read": [#"{"type":"file.read.result","status":"denied"}"#]])
        defer { Task { await service.stop() } }

        await #expect(throws: HostFileFetchError.unavailable(.denied)) {
            try await Self.connection(service).read(Self.target, version: Self.version, offset: 0, length: 5)
        }
    }

    @Test("回應的 offset 與請求不同時失敗，不拼錯位置")
    func chunkAtAnotherOffsetFails() async throws {
        let service = try await Self.start([
            "file.read": [#"{"type":"file.read.result","status":"file","offset":0,"bytes":"aGVs"}"#],
        ])
        defer { Task { await service.stop() } }

        await #expect(throws: HostFileFetchError.failed("chunk at an unexpected offset")) {
            try await Self.connection(service).read(Self.target, version: Self.version, offset: 3, length: 5)
        }
    }

    @Test("0.4.0 之前的主機服務沒有取檔訊息：unsupported,不送出")
    func olderHostServiceIsUnsupported() async throws {
        let service = try await Self.start([:], hostServiceVersion: "0.3.0")
        defer { Task { await service.stop() } }

        await #expect(throws: HostFileFetchError.unsupported) {
            try await Self.connection(service).status(of: Self.target)
        }
        #expect(service.messages(ofType: "file.stat").isEmpty)
    }

    @Test("HostFileLoader 經 HTTPS 載入圖片")
    func loaderLoadsThroughHTTPS() async throws {
        let service = try await Self.start([
            "file.stat": [#"{"type":"file.stat.result","status":"file","version":"9f86d081","size":5}"#],
            "file.read": [#"{"type":"file.read.result","status":"file","offset":0,"bytes":"aGVsbG8="}"#],
        ])
        defer { Task { await service.stop() } }
        let loader = HostFileLoader(fetcher: Self.connection(service))
        let scope = HostFileAccessScope(workingDirectories: ["/Users/demo/Projects/garden-journal"], mentionedPaths: [])

        let result = await loader.load(Self.path, scope: scope)

        #expect(result == .loaded(Data("hello".utf8), version: Self.version))
    }
}
