import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// SSH 的主機取檔 adapter(#225):每台主機一條長駐通道，請求一行、回應以 `end` 結束;路徑以 base64 送(可含空白、換行以外任何字元)。
/// 腳本本身的行為見 `HostFileFetchScriptTests`(實跑)。
@Suite("SSH 主機取檔")
struct SSHHostFileFetcherTests {
    static let target = HostFileTarget(path: "/Users/demo/ledger/shot 1.png", root: "/Users/demo/ledger")

    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static func followingHost() async -> FakeHost {
        let host = FakeHost()
        await host.expect(HostFileFetchScript.follow(), reply: FakeReply(keepsOpen: true))
        return host
    }

    @Test("查狀態：送一行 stat、收 file 版本 大小;讀取：送 read 帶版本與範圍、收 chunk 與 base64;同一條通道")
    func statusThenRead() async throws {
        let host = await Self.followingHost()
        let fetcher = SSHHostFileFetcher(channel: host)

        let status = Task { try await fetcher.status(of: Self.target) }
        let statusLine = "stat \(Self.base64(Self.target.path)) \(Self.base64("/Users/demo/ledger"))\n"
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText == statusLine })
        await host.send(stdout: Data("file 123:6 6\nend\n".utf8), toExecution: 0)
        #expect(try await status.value == .file(version: HostFileVersion(checksum: "123:6"), size: 6))

        let read = Task { try await fetcher.read(Self.target, version: HostFileVersion(checksum: "123:6"), offset: 2, length: 4) }
        let readLine = "read \(Self.base64(Self.target.path)) \(Self.base64("/Users/demo/ledger")) 123:6 2 4\n"
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText == statusLine + readLine })
        let encoded = Data("llo!".utf8).base64EncodedString()
        await host.send(stdout: Data("chunk 2 4 \(encoded.count)\n\(encoded)\nend\n".utf8), toExecution: 0)

        #expect(try await read.value == Data("llo!".utf8))
        #expect(await host.executions.count == 1)
        #expect(await host.executions.first?.closedStdin == false)
    }

    @Test("對話紀錄出現過的路徑不帶工作目錄(送 `-`);讀取時主機回 changed 丟 changed")
    func mentionedPathAndChangedVersion() async throws {
        let host = await Self.followingHost()
        let fetcher = SSHHostFileFetcher(channel: host)
        let target = HostFileTarget(path: "/tmp/shot.png", root: nil)

        let read = Task { try await fetcher.read(target, version: HostFileVersion(checksum: "1:1"), offset: 0, length: 10) }
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText == "read \(Self.base64("/tmp/shot.png")) - 1:1 0 10\n" })
        await host.send(stdout: Data("changed\nend\n".utf8), toExecution: 0)

        await #expect(throws: HostFileFetchError.changed) { _ = try await read.value }
    }

    @Test("主機跑不了腳本(還沒回應就 exit 127,例如 Demo 主機):unsupported")
    func unsupportedHost() async throws {
        let host = FakeHost()
        await host.expect(HostFileFetchScript.follow(), reply: FakeReply(stderr: Data("sh: not found\n".utf8), exitCode: 127))
        let fetcher = SSHHostFileFetcher(channel: host)

        await #expect(throws: HostFileFetchError.unsupported) { _ = try await fetcher.status(of: Self.target) }
    }

    @Test("Windows 主機(#226):命令列只有 stub,PowerShell 取檔腳本經 stdin 送一次、不送 EOF;請求行接在同一個 stdin,回應同 POSIX")
    func windowsHostUsesPowerShellScript() async throws {
        let host = FakeHost()
        await host.expect(WindowsHostScriptsTests.stub, reply: FakeReply(keepsOpen: true))
        let fetcher = SSHHostFileFetcher(channel: WindowsHostChannel(host))
        let root = #"C:\Users\demo\ledger"#
        let target = HostFileTarget(path: root + #"\shot 1.png"#, root: root)

        let status = Task { try await fetcher.status(of: target) }
        let statusLine = "stat \(Self.base64(target.path)) \(Self.base64(root))\n"
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix(statusLine) })
        await host.send(stdout: Data("file ab12:6 6\nend\n".utf8), toExecution: 0)

        #expect(try await status.value == .file(version: HostFileVersion(checksum: "ab12:6"), size: 6))
        let execution = try #require(await host.executions.first)
        #expect(execution.closedStdin == false)
        let script = String(execution.stdinText.dropLast(statusLine.count))
        #expect(script.hasSuffix("\n#purrdr-end-of-script\n"))
        #expect(script.contains("$a=@('60','600','26214400')"), "閒置、總長、上限照 POSIX 的參數")
        #expect(script.contains("GetFinalPathNameByHandle"), "以實際路徑(junction／symlink 解析後)比對存取規則")
        #expect(!script.contains("cd -P"), "POSIX 腳本不能送到 Windows")
    }
}
