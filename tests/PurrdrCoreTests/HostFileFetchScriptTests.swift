import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// 主機取檔的 POSIX 腳本(#225)以真的 `/bin/sh` 跑(`LocalShellHost`,經 `SSHHostFileFetcher` 的長駐通道):
/// 分塊與 base64、版本、缺檔、上限，以及主機端的存取規則(解析 symlink 後比對工作目錄、排除清單)。
@Suite("主機取檔腳本(實跑)")
struct HostFileFetchScriptTests {
    /// 含換行、NUL、`end` 行與非 ASCII 的 bytes:base64 分塊後要完整還原。
    static let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0A]) + Data("end\n中文\n".utf8) + Data((0..<2_500).map { UInt8($0 % 251) })

    struct Setup {
        let shell: LocalShellHost
        let fetcher: SSHHostFileFetcher
        /// 家目錄的絕對路徑(暫存資料夾)。
        let home: String

        func path(_ relative: String) -> String { home + "/" + relative }
    }

    static func setup(maximumSize: Int = HostFileFetchLimits.maximumSize) throws -> Setup {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        let home = shell.home.path(percentEncoded: false).trimmingSuffix("/")
        return Setup(shell: shell, fetcher: SSHHostFileFetcher(channel: shell, maximumSize: maximumSize), home: home)
    }

    @Test("閒置到時限：腳本以 exit 124 結束、不留程序;下一個請求重開通道")
    func idleLimitEndsTheScript() async throws {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        let home = shell.home.path(percentEncoded: false).trimmingSuffix("/")
        try shell.write(Data("x".utf8), to: "ledger/a.png")
        let channel = IdleLimitedChannel(base: shell)
        let fetcher = SSHHostFileFetcher(channel: channel)
        let target = HostFileTarget(path: home + "/ledger/a.png", root: home + "/ledger")

        guard case .file = try await fetcher.status(of: target) else { Issue.record("沒有狀態"); return }
        // 以第一個請求回應後的指令數為基準:負載高時 1 秒時限可能在第一個請求回應前就到,adapter 會先重開;
        // 要證明的是「閒置結束之後,下一個請求剛好重開一條」,與開頭花了幾條無關。
        let opened = shell.commands.count
        await shell.waitUntilFinished(timeout: .seconds(10))
        guard case .file = try await fetcher.status(of: target) else { Issue.record("重開後沒有狀態"); return }

        #expect(shell.commands.count == opened + 1, "閒置結束後重開一條")
    }

    /// 把取檔腳本的閒置時限改成 1 秒。
    struct IdleLimitedChannel: HostChannel {
        let base: LocalShellHost

        func execute(_ command: String) async throws -> any ExecSession {
            try await base.execute(command == HostFileFetchScript.follow() ? HostFileFetchScript.follow(idleSeconds: 1) : command)
        }

        func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
    }

    static func symlink(_ link: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)
    }

    /// 依狀態的版本分塊讀完整個檔案。
    static func readAll(_ fetcher: SSHHostFileFetcher, _ target: HostFileTarget, chunk: Int) async throws -> Data {
        guard case .file(let version, let size) = try await fetcher.status(of: target) else { throw HostFileFetchError.failed("not a file") }
        var data = Data()
        while data.count < size {
            data += try await fetcher.read(target, version: version, offset: data.count, length: chunk)
        }
        return data
    }

    @Test("工作目錄之下的二進位檔：狀態帶大小與版本，分塊讀回的 bytes 完全相同;同一條通道")
    func readsBinaryInChunks() async throws {
        let setup = try Self.setup()
        try setup.shell.write(Self.binary, to: "ledger/docs/空白 與中文.png")
        let target = HostFileTarget(path: setup.path("ledger/docs/空白 與中文.png"), root: setup.path("ledger"))

        let status = try await setup.fetcher.status(of: target)
        guard case .file(_, let size) = status else { Issue.record("狀態不對：\(status)"); return }
        #expect(size == Self.binary.count)
        #expect(try await Self.readAll(setup.fetcher, target, chunk: 1_000) == Self.binary)
        #expect(setup.shell.commands.count == 1, "所有請求走同一條長駐通道")
    }

    @Test("覆寫後版本改變：拿舊版本讀丟 changed,重新查狀態得到新版本")
    func overwrittenFileChangesVersion() async throws {
        let setup = try Self.setup()
        try setup.shell.write(Data("first".utf8), to: "ledger/shot.png")
        let target = HostFileTarget(path: setup.path("ledger/shot.png"), root: setup.path("ledger"))
        guard case .file(let old, _) = try await setup.fetcher.status(of: target) else { Issue.record("沒有狀態"); return }
        #expect(try await setup.fetcher.read(target, version: old, offset: 0, length: 100) == Data("first".utf8))

        try setup.shell.write(Data("second!".utf8), to: "ledger/shot.png")

        await #expect(throws: HostFileFetchError.changed) {
            _ = try await setup.fetcher.read(target, version: old, offset: 0, length: 100)
        }
        guard case .file(let new, 7) = try await setup.fetcher.status(of: target) else { Issue.record("新狀態不對"); return }
        #expect(new != old)
        #expect(try await setup.fetcher.read(target, version: new, offset: 0, length: 100) == Data("second!".utf8))
    }

    @Test("缺檔、資料夾不存在、資料夾不是一般檔案")
    func missingAndNotRegular() async throws {
        let setup = try Self.setup()
        try FileManager.default.createDirectory(atPath: setup.path("ledger/docs"), withIntermediateDirectories: true)
        let root = setup.path("ledger")

        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("ledger/gone.png"), root: root)) == .missing)
        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("ledger/no/such/dir.png"), root: root)) == .missing)
        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("ledger/docs"), root: root)) == .notRegularFile)
    }

    @Test("超過取檔上限：狀態回報大小，讀取也被拒")
    func overTheLimit() async throws {
        let setup = try Self.setup(maximumSize: 1_000)
        try setup.shell.write(Data(count: 1_001), to: "ledger/big.png")
        let target = HostFileTarget(path: setup.path("ledger/big.png"), root: setup.path("ledger"))

        #expect(try await setup.fetcher.status(of: target) == .tooLarge(size: 1_001))
        await #expect(throws: HostFileFetchError.unavailable(.tooLarge(size: 1_001))) {
            _ = try await setup.fetcher.read(target, version: HostFileVersion(checksum: "1:1"), offset: 0, length: 100)
        }
    }

    @Test("symlink 解析後跳出工作目錄：拒絕;指向工作目錄之內的 symlink 照常讀")
    func symlinkEscapingTheWorkingDirectory() async throws {
        let setup = try Self.setup()
        try setup.shell.write(Data("secret".utf8), to: "private/notes.png")
        try setup.shell.write(Data("inside".utf8), to: "ledger/real.png")
        try FileManager.default.createDirectory(atPath: setup.path("ledger/links"), withIntermediateDirectories: true)
        try Self.symlink(setup.path("ledger/links/out.png"), to: "../../private/notes.png")
        try Self.symlink(setup.path("ledger/links/in.png"), to: "../real.png")
        try Self.symlink(setup.path("ledger/outdir"), to: setup.path("private"))
        let root = setup.path("ledger")

        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("ledger/links/out.png"), root: root)) == .denied)
        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("ledger/outdir/notes.png"), root: root)) == .denied)
        #expect(try await Self.readAll(setup.fetcher, HostFileTarget(path: setup.path("ledger/links/in.png"), root: root), chunk: 100)
            == Data("inside".utf8))
    }

    @Test("排除清單：直接指定或經 symlink 指到 ~/.ssh、Purrdr 主機服務資料夾都拒絕(對話紀錄出現過也一樣)")
    func excludedLocations() async throws {
        let setup = try Self.setup()
        try setup.shell.write(Data("key".utf8), to: ".ssh/id_ed25519")
        try setup.shell.write(Data("{}".utf8), to: ".purrdr/host-service/devices.json")
        try setup.shell.write(Data("ok".utf8), to: "tmp/shot.png")
        try Self.symlink(setup.path("tmp/innocent.png"), to: setup.path(".ssh/id_ed25519"))

        for path in [".ssh/id_ed25519", ".purrdr/host-service/devices.json", "tmp/innocent.png"] {
            #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path(path), root: nil)) == .denied, "\(path)")
        }
        #expect(try await Self.readAll(setup.fetcher, HostFileTarget(path: setup.path("tmp/shot.png"), root: nil), chunk: 100) == Data("ok".utf8))
    }

    @Test("排除清單：case folding 後等於排除段落的 Unicode 名稱也拒絕(APFS 上 `.ſsh` 開到 `.ssh`,#577)")
    func excludedAfterUnicodeCaseFolding() async throws {
        let setup = try Self.setup()
        let root = setup.path("ledger")
        let lookalikes = [
            "ledger/.\u{17F}sh/id_ed25519", "ledger/.\u{17F}SH/config", "ledger/.git-credential\u{17F}",
            "ledger/.purrdr/host-\u{17F}ervice/devices.json", "ledger/.\u{212A}ube/config", "ledger/.password-\u{FB05}ore/a.gpg",
        ]
        for path in lookalikes { try setup.shell.write(Data("secret".utf8), to: path) }

        for path in lookalikes {
            #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path(path), root: root)) == .denied, "\(path)")
        }
    }

    @Test("工作目錄本身不存在：拒絕")
    func missingWorkingDirectory() async throws {
        let setup = try Self.setup()
        try setup.shell.write(Data("x".utf8), to: "elsewhere/a.png")

        #expect(try await setup.fetcher.status(of: HostFileTarget(path: setup.path("elsewhere/a.png"), root: setup.path("gone"))) == .denied)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

#endif
