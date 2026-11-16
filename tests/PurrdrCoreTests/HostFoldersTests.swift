import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機資料夾：清單與上傳(行為規格 F13)。腳本以 `LocalShellHost` 在暫存家目錄跑真的 `/bin/sh`;
/// 不經主機的規則(大小、檔名)以假主機斷言「完全沒送出指令」。
@Suite("主機資料夾")
struct HostFoldersTests {
    @Test("主機回應的第一行不是絕對路徑：不是資料夾清單")
    func rejectsNonListingReply() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data("Welcome to fish!\n/Users/demo\n".utf8)))

        await #expect(throws: HostFolderError.notAFolderListing) {
            _ = try await HostFolders(channel: host).list()
        }
    }

    @Test("超過 25 MB 拒絕上傳，什麼指令都不送")
    func rejectsUploadOverLimit() async throws {
        let host = FakeHost()
        let folders = HostFolders(channel: host)

        await #expect(throws: HostFolderError.tooLarge) {
            _ = try await folders.upload(Data(count: HostFolders.maximumUploadSize + 1), named: "big.bin", to: "/Users/demo")
        }
        #expect(await host.executions.isEmpty)
    }

    @Test("檔名不可為空、`.`、`..`,不可含 `/`、NUL、換行;什麼指令都不送")
    func rejectsInvalidNames() async throws {
        let host = FakeHost()
        let folders = HostFolders(channel: host)

        for name in ["", ".", "..", "a/b", "/", "a\u{0}b", "a\nb"] {
            await #expect(throws: HostFolderError.invalidName, "\(name)") {
                _ = try await folders.upload(Data("x".utf8), named: name, to: "/Users/demo")
            }
        }
        #expect(await host.executions.isEmpty)
    }

    @Test("上傳的資料夾必須是絕對路徑")
    func rejectsRelativeFolder() async throws {
        let host = FakeHost()
        await #expect(throws: HostFolderError.cannotOpen("Documents")) {
            _ = try await HostFolders(channel: host).upload(Data("x".utf8), named: "a.txt", to: "Documents")
        }
        #expect(await host.executions.isEmpty)
    }
}

#if os(macOS)
/// 真的跑主機腳本(暫存家目錄,不碰真正的家目錄)。
@Suite("主機資料夾腳本")
struct HostFolderScriptTests {
    let host: LocalShellHost
    let folders: HostFolders
    var home: String { host.home.path(percentEncoded: false).replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }

    init() throws {
        host = try LocalShellHost.temporary(feedsStdin: true)
        folders = HostFolders(channel: host)
    }

    @Test("清單：沒指定資料夾時是家目錄;含隱藏檔;資料夾在前")
    func listsHomeWithHiddenFiles() async throws {
        try host.write(Data("#".utf8), to: ".zshrc")
        try host.write(Data("hello".utf8), to: "notes/read me.txt")

        let listing = try await folders.list()

        #expect(listing.path == home)
        #expect(listing.entries.map(\.name) == ["notes", ".zshrc"])
        #expect(listing.entries.first?.kind == .folder)
    }

    @Test("清單：指定的資料夾;打不開時附上主機的錯誤")
    func listsGivenFolder() async throws {
        try host.write(Data("hello".utf8), to: "notes/read me.txt")

        let listing = try await folders.list(home + "/notes")
        #expect(listing.path == home + "/notes")
        #expect(listing.entries == [
            FolderEntry(name: "read me.txt", kind: .file, size: 5, modified: listing.entries.first?.modified),
        ])

        await #expect {
            _ = try await folders.list(home + "/missing")
        } throws: { error in
            guard case HostFolderError.cannotOpen(let message) = error else { return false }
            return message.contains("missing")
        }
    }

    @Test("上傳：bytes 經 stdin 寫進資料夾，回傳絕對路徑;檔名可以是 - 開頭、含空白與引號")
    func uploadsThroughStdin() async throws {
        try FileManager.default.createDirectory(at: host.url("inbox"), withIntermediateDirectories: true)
        let data = Data((0..<200_000).map { UInt8($0 % 251) })

        let path = try await folders.upload(data, named: "-it's a file.bin", to: home + "/inbox")

        #expect(path == home + "/inbox/-it's a file.bin")
        #expect(try Data(contentsOf: host.url("inbox/-it's a file.bin")) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.url("inbox").path) == ["-it's a file.bin"])
    }

    @Test("上傳：已有同名項目則拒絕，永不覆寫，不留下暫存檔")
    func neverOverwrites() async throws {
        try host.write(Data("original".utf8), to: "inbox/a.txt")

        await #expect(throws: HostFolderError.alreadyExists) {
            _ = try await folders.upload(Data("new".utf8), named: "a.txt", to: home + "/inbox")
        }
        #expect(try String(contentsOf: host.url("inbox/a.txt"), encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.url("inbox").path) == ["a.txt"])
    }

    @Test("上傳：資料夾不存在")
    func uploadToMissingFolder() async throws {
        await #expect {
            _ = try await folders.upload(Data("x".utf8), named: "a.txt", to: home + "/missing")
        } throws: { error in
            if case HostFolderError.cannotOpen = error { return true }
            return false
        }
    }

    @Test("腳本：收到的大小與宣告的不同(上傳中斷)時失敗，不留下任何檔案")
    func scriptRejectsShortUpload() async throws {
        try FileManager.default.createDirectory(at: host.url("inbox"), withIntermediateDirectories: true)

        let session = try await host.execute(HostFolderCommand.upload(folder: home + "/inbox", name: "a.txt", size: 10))
        try await session.write(Data("12345".utf8))
        await session.closeStdin()
        var code: Int32?
        for try await event in session.output {
            if case .exit(let exit, _) = event { code = exit }
        }

        #expect(code != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.url("inbox").path).isEmpty)
    }

    @Test("腳本不含反斜線(fish 在單引號內仍處理 `\\`)")
    func scriptsHaveNoBackslash() {
        #expect(!HostFolderCommand.list("/a b").contains("\\"))
        #expect(!HostFolderCommand.upload(folder: "/a", name: "b", size: 1).contains("\\"))
    }
}
#endif
