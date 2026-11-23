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
        let path = "/tmp/purrdr-uploads-1000/\(name.value)"
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
        #expect(path == "/var/folders/zz/demo/T/purrdr-uploads-501/mh1a2b3c-k9x2m4p7-notes.md")
    }

    /// 記下每次讀了哪個範圍的來源(證明分塊讀、不是整份先讀進記憶體)。
    final class RecordingSource: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Range<Int>] = []
        let content: Data
        init(_ content: Data) { self.content = content }
        var ranges: [Range<Int>] { lock.withLock { recorded } }
        var source: HostUploadSource {
            HostUploadSource(size: content.count) { range in
                self.lock.withLock { self.recorded.append(range) }
                return self.content.subdata(in: range)
            }
        }
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ value: Double) { lock.withLock { values.append(value) } }
        var all: [Double] { lock.withLock { values } }
    }

    @Test("SSH:分塊讀來源(每塊不超過 64 KiB,不整份讀),進度遞增到 1,送出的內容與來源相同")
    func sshStreamsSourceInChunks() async throws {
        let name = try #require(HostUploadName("mh1a2b3c-k9x2m4p7-video.mp4"))
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let recording = RecordingSource(content)
        let host = FakeHost()
        let path = "/tmp/purrdr-uploads-1000/\(name.value)"
        await host.expect(HostUploadCommand.posix(name: name, size: content.count), reply: FakeReply(stdout: Data("\(path)\n".utf8)))
        let log = ProgressLog()

        let uploaded = try await SSHHostUploader(channel: host).upload(recording.source, named: name, progress: { log.add($0) })

        #expect(uploaded == path)
        #expect(await host.executions.first?.stdin == content)
        #expect(recording.ranges.allSatisfy { $0.count <= SSHHostUploader.chunkSize })
        #expect(recording.ranges.count == 4, "200,000 bytes 分成 4 塊")
        #expect(log.all == log.all.sorted() && log.all.last == 1)
    }

    @Test("本機檔案來源:依範圍讀出對應位元組")
    func fileSourceReadsRanges() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "upload-source-\(UUID().uuidString)")
        let content = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0) })
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try HostUploadSource.file(at: url)

        #expect(source.size == 1_000)
        #expect(try source.read(100..<150) == content.subdata(in: 100..<150))
        #expect(try source.read(990..<1_000) == content.subdata(in: 990..<1_000))
    }

    @Test("預設實作(測試替身、小檔案):整份讀出後走原本的上傳,進度 1")
    func defaultImplementationUsesDataUpload() async throws {
        let name = try #require(HostUploadName("a.mp4"))
        let uploader = FakeHostUploader()
        let log = ProgressLog()

        _ = try await uploader.upload(.data(Data("abc".utf8)), named: name, progress: { log.add($0) })

        #expect(await uploader.uploads.map(\.data) == [Data("abc".utf8)])
        #expect(log.all.last == 1)
    }
}
