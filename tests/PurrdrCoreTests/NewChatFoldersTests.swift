#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 新增對話的資料夾瀏覽(行為規格 F3.3)與開始前的資料夾解析(F3.2 第 1 步)。
/// 在本機用真的 `/bin/sh` 跑主機腳本，家目錄是暫存資料夾。
@Suite("新增對話的資料夾")
struct NewChatFoldersTests {
    let host: LocalShellHost
    let folders: SSHNewChatFolders

    init() throws {
        host = try LocalShellHost.temporary()
        folders = SSHNewChatFolders(channel: host)
    }

    func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: host.url(path), withIntermediateDirectories: true)
    }

    @Test("家目錄：只列子資料夾(排除隱藏資料夾與檔案)、跟隨指向資料夾的 symlink、壞掉的 symlink 不影響，不分大小寫排序")
    func listsVisibleSubfoldersOfHome() async throws {
        try makeFolder("beta")
        try makeFolder("Alpha")
        try makeFolder(".hidden")
        try makeFolder("with space")
        try host.write(Data("x".utf8), to: "notes.txt")
        try FileManager.default.createSymbolicLink(atPath: host.url("linked").path, withDestinationPath: host.url("beta").path)
        try FileManager.default.createSymbolicLink(atPath: host.url("broken").path, withDestinationPath: host.url("gone").path)

        let listing = try await folders.list(nil)

        #expect(listing.path == host.home.path(percentEncoded: false).trimmingSuffix("/"))
        #expect(listing.folders == ["Alpha", "beta", "linked", "with space"])
    }

    @Test("`~/…` 展開成家目錄;空資料夾回空清單(不是錯誤)")
    func expandsTildeAndReportsEmptyFolder() async throws {
        try makeFolder("projects/empty")
        try host.write(Data("x".utf8), to: "projects/empty/file.txt")

        let listing = try await folders.list("~/projects/empty")

        #expect(listing.path == host.url("projects/empty").path(percentEncoded: false))
        #expect(listing.folders.isEmpty)
    }

    @Test("單引號與「 -> 」之類的名稱原樣列出")
    func listsUnusualNames() async throws {
        try makeFolder("it's here")
        try makeFolder("a -> b")

        let listing = try await folders.list("~")

        #expect(listing.folders == ["a -> b", "it's here"])
    }

    @Test("不存在的資料夾丟 notFound,不是空清單")
    func missingFolderIsAnError() async throws {
        await #expect(throws: NewChatFolderError.notFound("~/nope")) {
            try await folders.list("~/nope")
        }
    }

    @Test("檔案不是資料夾:notFound")
    func fileIsNotAFolder() async throws {
        try host.write(Data("x".utf8), to: "notes.txt")
        await #expect(throws: NewChatFolderError.notFound(host.url("notes.txt").path(percentEncoded: false))) {
            try await folders.list(host.url("notes.txt").path(percentEncoded: false))
        }
    }

    @Test("第一行不是絕對路徑(登入設定印了東西)→ unexpectedResponse;指令不含反斜線，可由 Demo 認回路徑")
    func rejectsNonListingAndRoundTrips() async throws {
        let fake = FakeHost()
        let command = SSHNewChatFolders.command(for: "~/it's")
        await fake.expect(command, reply: FakeReply(stdout: Data("Welcome!\n/Users/demo\n".utf8)))

        await #expect(throws: NewChatFolderError.unexpectedResponse) {
            try await SSHNewChatFolders(channel: fake).list("~/it's")
        }
        #expect(!command.contains("\\"))
        #expect(SSHNewChatFolders.requestedPath(in: command) == "~/it's")
        #expect(SSHNewChatFolders.requestedPath(in: "ls -la") == nil)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}
#endif
