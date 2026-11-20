import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 上傳到主機(#286):圖片與一般檔案共用的上傳介面;這裡驗 SSH 實作與檔名。
@Suite("上傳到主機")
struct HostUploadTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let prefix = String(1_800_000_000_000, radix: 36) + "-"

    static func name(for original: String) -> HostUploadName {
        var random = SystemRandomNumberGenerator()
        return HostUploadName.make(original: original, date: date, random: &random)
    }

    @Test("檔名只接受 [A-Za-z0-9-]+ 加上一個英數副檔名(可省略)")
    func validatesNames() {
        #expect(HostUploadName("abc-123.log") != nil)
        #expect(HostUploadName("Makefile") != nil)
        #expect(HostUploadName("a.jpg")?.value == "a.jpg")
        #expect(HostUploadName("../x.txt") == nil)
        #expect(HostUploadName(".env") == nil)
        #expect(HostUploadName("a b.txt") == nil)
        #expect(HostUploadName("a.tar.gz") == nil)
        #expect(HostUploadName("a'b.txt") == nil)
        #expect(HostUploadName("") == nil)
    }

    @Test("圖片檔名原樣當上傳檔名")
    func imageNamesConvert() throws {
        let image = try #require(UploadFileName("mh1a2b3c-k9x2m4p7.jpg"))
        #expect(HostUploadName(image).value == "mh1a2b3c-k9x2m4p7.jpg")
    }

    @Test("一般檔案：時間 base36、8 個亂數，再接原始檔名的英數字與小寫副檔名")
    func makesNamesFromOriginal() {
        let name = Self.name(for: "build log (1).TXT")
        #expect(name.value.hasPrefix(Self.prefix))
        #expect(name.value.hasSuffix("-build-log-1.txt"))
        #expect(name.value.dropFirst(Self.prefix.count).split(separator: "-").first?.count == 8)
        #expect(HostUploadName(name.value) == name)
    }

    @Test("原始檔名沒有英數字時用 file;沒有副檔名就不加;多個點只留最後一段當副檔名")
    func makesNamesForUnusualOriginals() {
        #expect(Self.name(for: "報告.pdf").value.hasSuffix("-file.pdf"))
        #expect(Self.name(for: "Makefile").value.hasSuffix("-Makefile"))
        #expect(!Self.name(for: "Makefile").value.contains("."))
        #expect(Self.name(for: "backup.tar.gz").value.hasSuffix("-backup-tar.gz"))
        #expect(Self.name(for: ".env").value.hasSuffix("-file.env"))
        #expect(HostUploadName(Self.name(for: "報告.pdf").value) != nil)
    }

    @Test("原始檔名很長時截短，副檔名保留")
    func truncatesLongOriginals() {
        let name = Self.name(for: String(repeating: "a", count: 300) + ".csv")
        #expect(name.value.hasSuffix(".csv"))
        #expect(name.value.count <= 80)
    }

    @Test("SSH:一般檔案經 exec 的 stdin 上傳，回傳主機上的絕對路徑")
    func sshUploadsFiles() async throws {
        let name = try #require(HostUploadName("mh1a2b3c-k9x2m4p7-server.log"))
        let host = FakeHost()
        let path = "/home/me/.purrdr/uploads/\(name.value)"
        await host.expect(HostUploadCommand.posix(name: name, size: 5), reply: FakeReply(stdout: Data("\(path)\n".utf8)))

        let uploaded = try await SSHHostUploader(channel: host).upload(Data("hello".utf8), named: name)

        #expect(uploaded == path)
        #expect(await host.executions.first?.stdin == Data("hello".utf8))
    }

    @Test("SSH:超過一般檔案上限時不送任何指令，丟 tooLarge")
    func sshRejectsOversizedFiles() async throws {
        let name = try #require(HostUploadName("big.bin"))
        let host = FakeHost()

        await #expect(throws: HostUploadError.tooLarge) {
            try await SSHHostUploader(channel: host).upload(Data(count: HostUploadLimit.maximumFileSize + 1), named: name)
        }
        #expect(await host.executions.isEmpty)
    }

    @Test("一般檔案上限沿用主機服務協定的檔案上限")
    func fileLimitFollowsProtocol() {
        #expect(HostUploadLimit.maximumFileSize == HostServiceProtocol.maximumFileSize)
    }

    @Test("Demo 主機收下一般檔案，回傳上傳資料夾的路徑(離線示範)")
    func demoAcceptsFiles() async throws {
        let name = try #require(HostUploadName("mh1a2b3c-k9x2m4p7-notes.md"))
        let path = try await SSHHostUploader(channel: DemoHost()).upload(Data("# notes".utf8), named: name)
        #expect(path == "/Users/demo/.purrdr/uploads/mh1a2b3c-k9x2m4p7-notes.md")
    }
}
