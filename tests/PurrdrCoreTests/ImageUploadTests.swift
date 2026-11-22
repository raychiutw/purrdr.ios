import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 圖片上傳(行為規格 F7、§8.4;ADR-0003:無 SFTP,bytes 走 exec 的 stdin)。
///
/// 主機腳本在本機以真的 `/bin/sh` 跑，家目錄是暫存資料夾(`LocalShellHost`),絕不碰真正的家目錄。
@Suite("圖片上傳")
struct ImageUploadTests {
    static let name = HostUploadName("mh1a2b3c-k9x2m4p7.jpg")!

    @Test("檔名只接受 [A-Za-z0-9-]+.(jpg|png)")
    func validatesFileNames() {
        #expect(UploadFileName("abc-123.jpg") != nil)
        #expect(UploadFileName("ABC.png") != nil)
        #expect(UploadFileName("../x.jpg") == nil)
        #expect(UploadFileName(".hidden.jpg") == nil)
        #expect(UploadFileName("a b.jpg") == nil)
        #expect(UploadFileName("a.gif") == nil)
        #expect(UploadFileName("a.jpg.sh") == nil)
        #expect(UploadFileName("a'b.jpg") == nil)
    }

    @Test("產生的檔名是 <時間 base36>-<8 個 base36 亂數>.jpg")
    func generatesFileNames() {
        var random = SystemRandomNumberGenerator()
        let name = UploadFileName.make(date: Date(timeIntervalSince1970: 1_800_000_000), random: &random)
        let parts = name.value.dropLast(".jpg".count).split(separator: "-")
        #expect(name.value.hasSuffix(".jpg"))
        #expect(parts.count == 2)
        #expect(parts.first == Substring(String(1_800_000_000_000, radix: 36)))
        #expect(parts.last?.count == 8)
        #expect(UploadFileName(name.value) == name)
    }

    @Test("指令與腳本都不含反斜線(fish 會處理單引號內的反斜線)")
    func commandHasNoBackslash() {
        #expect(!HostUploadCommand.posix(name: Self.name, size: 12).contains("\\"))
    }

    #if os(macOS)
    /// 新的上傳資料夾:暫存目錄(`TMPDIR`)底下的 `purrdr-uploads-<uid>`(名稱來自協定 schema 的 `x-upload-folder`)。
    static let folderName = "\(HostServiceProtocol.uploadFolder)-\(getuid())"
    static func folder(of host: LocalShellHost) -> URL { host.temporaryDirectory.appending(path: folderName) }
    static func put(_ data: Data, in folder: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test("上傳：bytes 原樣寫進暫存目錄底下的上傳資料夾，回傳絕對路徑;資料夾與檔案僅本人可讀")
    func uploadsThroughStdinOwnerOnly() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

        let path = try await SSHHostUploader(channel: host).upload(bytes, named: Self.name)

        let temporary = host.temporaryDirectory.path(percentEncoded: false)
        #expect(path == (temporary.hasSuffix("/") ? temporary : temporary + "/") + "\(Self.folderName)/\(Self.name.value)")
        #expect(try Data(contentsOf: URL(filePath: path)) == bytes)
        #expect(try mode(of: URL(filePath: path)) == 0o600)
        #expect(try mode(of: Self.folder(of: host)) == 0o700)
        // 不再寫進家目錄。
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path(percentEncoded: false)))
        // 指令列只有檔名與大小,內容一律走 stdin(不受 sshd 單一參數 128 KiB 上限限制)。
        #expect(host.commands.count == 1)
        #expect(host.commands[0].utf8.count < 8 * 1024)
        // 沒有留下暫存檔。
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.folder(of: host).path(percentEncoded: false)) == [Self.name.value])
    }

    @Test("TMPDIR 沒設定時用 /tmp(腳本內容)")
    func fallsBackToTmp() {
        #expect(HostUploadCommand.posix(name: Self.name, size: 1).contains("${TMPDIR:-/tmp}"))
    }

    @Test("上傳資料夾已存在但權限太寬：失敗，不寫入、不改權限")
    func rejectsLooseUploadFolder() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        try FileManager.default.createDirectory(at: Self.folder(of: host), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        await #expect(throws: HostUploadError.self) {
            try await SSHHostUploader(channel: host).upload(Data("x".utf8), named: Self.name)
        }
        #expect(try mode(of: Self.folder(of: host)) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.folder(of: host).path(percentEncoded: false)) == [])
    }

    @Test("同名的 symlink 擋在上傳資料夾的位置：失敗，不寫進 symlink 的目標")
    func rejectsSymlinkedUploadFolder() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let target = host.url("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: Self.folder(of: host), withDestinationURL: target)

        await #expect(throws: HostUploadError.self) {
            try await SSHHostUploader(channel: host).upload(Data("x".utf8), named: Self.name)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)) == [])
    }

    @Test("每次上傳順手刪掉新、舊上傳資料夾裡 7 天前的舊檔;較新的與資料夾外的檔案不動;舊資料夾空了就移除")
    func removesUploadsOlderThanSevenDays() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let now = Date()
        let folder = Self.folder(of: host)
        let old = try Self.put(Data("old".utf8), in: folder, named: "old-1.jpg")
        let oldTemp = try Self.put(Data("partial".utf8), in: folder, named: ".upload.abc123")
        let recent = try Self.put(Data("recent".utf8), in: folder, named: "recent-1.jpg")
        let legacyOld = try host.write(Data("old".utf8), to: ".purrdr/uploads/old-2.jpg")
        let legacyRecent = try host.write(Data("recent".utf8), to: ".purrdr/uploads/recent-2.jpg")
        let outside = try host.write(Data("mine".utf8), to: "Pictures/old.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        for url in [old, oldTemp, legacyOld] { try setModified(url, to: now.addingTimeInterval(-8 * 86_400)) }
        try setModified(recent, to: now.addingTimeInterval(-6 * 86_400))
        try setModified(legacyRecent, to: now.addingTimeInterval(-6 * 86_400))
        try setModified(outside, to: now.addingTimeInterval(-30 * 86_400))

        _ = try await SSHHostUploader(channel: host).upload(Data("new".utf8), named: Self.name)

        let manager = FileManager.default
        func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path(percentEncoded: false)) }
        #expect(!exists(old))
        #expect(!exists(oldTemp))
        #expect(!exists(legacyOld))
        #expect(exists(recent))
        #expect(exists(legacyRecent))
        #expect(exists(outside))
        #expect(exists(folder.appending(path: Self.name.value)))
        #expect(exists(host.url(".purrdr/uploads")))

        // 舊資料夾清空後移除。
        try setModified(legacyRecent, to: now.addingTimeInterval(-8 * 86_400))
        _ = try await SSHHostUploader(channel: host).upload(Data("new".utf8), named: HostUploadName("other-1.jpg")!)
        #expect(!exists(host.url(".purrdr/uploads")))
    }

    @Test("上傳中斷(連線在 bytes 送完前斷了):丟錯，主機上不留下正式檔或暫存檔")
    func interruptedUploadLeavesNothing() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let channel = InterruptingChannel(base: host, failAfter: 100_000)

        await #expect(throws: HostUploadError.interrupted) {
            try await SSHHostUploader(channel: channel).upload(Data(count: 300_000), named: Self.name)
        }

        await host.waitUntilFinished()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder(of: host).path(percentEncoded: false))) ?? []
        #expect(left == [])
    }

    @Test("同名檔案已存在：永不覆寫，回報失敗")
    func neverOverwrites() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let existing = try Self.put(Data("keep".utf8), in: Self.folder(of: host), named: Self.name.value)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.folder(of: host).path(percentEncoded: false))

        await #expect(throws: HostUploadError.self) {
            try await SSHHostUploader(channel: host).upload(Data("new".utf8), named: Self.name)
        }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    }
    #endif

    @Test("回傳的路徑不是絕對路徑或不以 /<檔名> 結尾：主機把圖片存到意外的位置")
    func rejectsUnexpectedPath() async throws {
        let host = FakeHost()
        await host.expect(HostUploadCommand.posix(name: Self.name, size: 3), reply: FakeReply(stdout: Data("/tmp/other.jpg\n".utf8)))

        await #expect(throws: HostUploadError.unexpectedPath("/tmp/other.jpg")) {
            try await SSHHostUploader(channel: host).upload(Data("abc".utf8), named: Self.name)
        }
    }

    @Test("送完 bytes 後送 EOF;主機腳本失敗(非零 exit)丟 failed")
    func sendsEOFAndReportsFailure() async throws {
        let host = FakeHost()
        await host.expect(HostUploadCommand.posix(name: Self.name, size: 3), reply: FakeReply(stderr: Data("disk full\n".utf8), exitCode: 71))

        await #expect(throws: HostUploadError.failed(exitCode: 71, message: "disk full")) {
            try await SSHHostUploader(channel: host).upload(Data("abc".utf8), named: Self.name)
        }
        let execution = try #require(await host.executions.first)
        #expect(execution.stdin == Data("abc".utf8))
        #expect(execution.closedStdin)
    }

    @Test("被訊號結束、或沒有結束狀態就斷了，都算中斷")
    func signalCountsAsInterrupted() async throws {
        let host = FakeHost()
        await host.expect(HostUploadCommand.posix(name: Self.name, size: 3), reply: FakeReply(keepsOpen: true))
        let uploader = SSHHostUploader(channel: host)

        let result = Task { try await uploader.upload(Data("abc".utf8), named: Self.name) }
        _ = await host.waitForExecutions(1)
        await host.send(.exit(code: 0, signal: "HUP"), toExecution: 0)
        await host.finish(execution: 0)

        await #expect(throws: HostUploadError.interrupted) { try await result.value }
    }

    @Test("期限到(預設 20 秒起跳)關閉通道並丟 deadlineExceeded")
    func deadline() async throws {
        let host = FakeHost()
        await host.expect(HostUploadCommand.posix(name: Self.name, size: 3), reply: FakeReply(keepsOpen: true))
        let sleeper = RecordingSleeper(fires: { _ in true })

        await #expect(throws: HostUploadError.deadlineExceeded) {
            try await SSHHostUploader(channel: host, sleep: sleeper.sleep).upload(Data("abc".utf8), named: Self.name)
        }
        #expect(await sleeper.requested.first.map { $0 >= .seconds(20) } == true)
        #expect(await host.executions.first?.closed == true)
    }
}

/// 檔案權限(低 9 位元)。
func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
}

func setModified(_ url: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
}
