import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的變更頁(#310):`HTTPSHostConnection` 以主機服務的 `git.status`／`git.diff`(0.7.0 起)實作 `GitChangesReading`。
@Suite("HTTPS 主機的 git 變更")
struct HTTPSGitChangesTests {
    static let cwd = "/Users/demo/Projects/garden-journal"

    private static func start(_ replies: [String: [String]], hostServiceVersion: String = "0.7.0") async throws -> FakeHostService {
        try await FakeHostService.start(.init(gitReplies: replies, hostServiceVersion: hostServiceVersion))
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    private static func example(_ name: String) throws -> String {
        let data = try HostServiceProtocolExampleTests.example(name)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["request_id"] = nil
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("變更清單：送 cwd,回分支與檔案")
    func statusSendsWorkingDirectory() async throws {
        let service = try await Self.start(["git.status": [try Self.example("server.git-status-result.json")]])
        defer { Task { await service.stop() } }

        let status = try await Self.connection(service).gitStatus(cwd: Self.cwd)

        #expect(status == GitWorkingTreeStatus(branch: "main", files: [
            GitChange(path: "README.md", kind: .modified),
            GitChange(path: "logo.png", kind: .modified),
            GitChange(path: "src/garden.rs", kind: .untracked),
        ]))
        let sent = try #require(service.messages(ofType: "git.status").first)
        #expect(sent["cwd"] as? String == Self.cwd)
    }

    @Test("單檔 diff:送 cwd 與路徑，二進位檔標成不顯示")
    func diffSendsPathAndMapsOmissions() async throws {
        let service = try await Self.start(["git.diff": [try Self.example("server.git-diff-result.json")]])
        defer { Task { await service.stop() } }

        let diff = try await Self.connection(service).gitDiff(cwd: Self.cwd, path: "README.md")

        #expect(diff == GitDiffSet(files: [
            GitFileDiff(path: "README.md", kind: .modified, content: .hunks("@@ -1,3 +1,3 @@\n # Garden\n \n-Water daily.\n+Water twice daily.\n")),
            GitFileDiff(path: "logo.png", kind: .modified, content: .omitted(.binary)),
        ], truncated: false))
        let sent = try #require(service.messages(ofType: "git.diff").first)
        #expect(sent["cwd"] as? String == Self.cwd)
        #expect(sent["path"] as? String == "README.md")
    }

    @Test("cwd_not_allowed 與 not_git_repository 換成專屬錯誤")
    func mapsGitErrors() async throws {
        let service = try await Self.start([
            "git.status": [
                #"{"type":"error","code":"not_git_repository","message":"not a git repository"}"#,
                #"{"type":"error","code":"cwd_not_allowed","message":"cwd is not an agent working directory"}"#,
            ],
        ])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: GitChangesError.notGitRepository) { try await connection.gitStatus(cwd: Self.cwd) }
        await #expect(throws: GitChangesError.cwdNotAllowed) { try await connection.gitStatus(cwd: Self.cwd) }
    }

    @Test("主機服務回了不是預期種類的訊息:丟 unexpectedResponse(與其他 adapter 一致)")
    func unexpectedReplyIsUnexpectedResponse() async throws {
        let service = try await Self.start([
            "git.status": [try Self.example("server.git-diff-result.json")],
            "git.diff": [try Self.example("server.git-status-result.json")],
        ])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: HostServiceError.unexpectedResponse) { try await connection.gitStatus(cwd: Self.cwd) }
        await #expect(throws: HostServiceError.unexpectedResponse) { try await connection.gitDiff(cwd: Self.cwd, path: nil) }
    }

    @Test("0.7.0 之前的主機服務：不送出，要求更新主機服務")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await Self.start([:], hostServiceVersion: "0.6.0")
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.gitChanges, installedVersion: "0.6.0")) {
            try await Self.connection(service).gitStatus(cwd: Self.cwd)
        }
        #expect(service.messages(ofType: "git.status").isEmpty)
    }
}
