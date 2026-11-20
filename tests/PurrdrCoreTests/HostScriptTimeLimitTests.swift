import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 主機腳本的自我時限(#92):一次性腳本超過時限就結束自己與子程序，不在主機上留下程序。
@Suite("主機腳本時限")
struct HostScriptTimeLimitTests {
    @Test("一次性的 POSIX 主機指令都帶時限;長時間串流(bridge、Pane 終端機)不帶")
    func oneShotPosixCommandsCarryTimeLimit() throws {
        let uploadName = try #require(HostUploadName("a-1.jpg"))
        let oneShot = [
            TranscriptCommand.locate(sessionID: "s", projectFolder: "p"),
            TranscriptCommand.window(path: "/t.jsonl", end: 10, lines: 5),
            ClaudeSlashCommand.discover(cwd: "/w", transcriptPath: nil),
            HostFileScript.command(HostFileScript.read, arguments: ["a"]),
            HostFolderCommand.list(nil),
            HostFolderCommand.upload(folder: "/f", name: "n", size: 3),
            NewChatFolders.command(for: "~"),
            HostUploadCommand.posix(name: uploadName, size: 3),
        ]
        for command in oneShot {
            #expect(command.contains(HostScriptTimeLimit.posixMarker), "\(command.prefix(120))")
        }
        let streams = [HerdrCommand.bridge(), HerdrCommand.terminalSessionControl(target: "p", columns: 80, rows: 24)]
        for command in streams {
            #expect(!command.contains(HostScriptTimeLimit.posixMarker))
        }
    }

    @Test("長駐但自帶時限的腳本(對話紀錄追蹤，#166／#167):POSIX 與 Windows 都帶時限，閒置與總長由參數帶入")
    func longLivedScriptsCarryTimeLimit() throws {
        let follow = TranscriptCommand.follow(idleSeconds: 7, totalSeconds: 90)
        // 追蹤腳本本身也呼叫 `purrdr_limit`(閒置時限),所以要看到函式的定義(總長時限由 `HostScriptTimeLimit.posix` 包上)。
        #expect(follow.contains(HostScriptTimeLimit.posixMarker + "() {"), "追蹤腳本沒有包上 HostScriptTimeLimit.posix")
        #expect(follow.hasPrefix(TranscriptCommand.followInvocation))
        #expect(PosixShell.unquote(String(follow.dropFirst(TranscriptCommand.followInvocation.count)))?.suffix(2) == ["7", "90"])

        let windows = try WindowsCommand.translate(follow)
        #expect(windows.keepsStdinOpen)
        let script = String(decoding: try #require(windows.stdinScript), as: UTF8.self)
        #expect(script.contains("$purrdrLimit.At"), "Windows 追蹤腳本要自己延長／收緊時限")
        #expect(try #require(PowerShell.script(inEncodedCommand: windows.command)).contains("$purrdrLimit"))
    }

    @Test("主機檔案的長駐讀取(#203):POSIX 與 Windows 都帶時限，閒置與總長由參數帶入")
    func longLivedHostFileReadCarriesTimeLimit() throws {
        let follow = HostFileScript.follow(idleSeconds: 7, totalSeconds: 90)
        #expect(follow.contains(HostScriptTimeLimit.posixMarker + "() {"), "長駐讀取沒有包上 HostScriptTimeLimit.posix")
        #expect(follow.hasPrefix(HostFileScript.followInvocation))
        #expect(PosixShell.unquote(String(follow.dropFirst(HostFileScript.followInvocation.count))) == ["7", "90"])

        let windows = try WindowsCommand.translate(follow)
        #expect(windows.keepsStdinOpen)
        let script = String(decoding: try #require(windows.stdinScript), as: UTF8.self)
        #expect(script.contains("$a=@('7','90')"))
        #expect(script.contains("$purrdrLimit.At"), "Windows 長駐讀取要自己延長／收緊時限")
    }

    @Test("主機取檔的長駐腳本(#225／#226):POSIX 與 Windows 都帶時限，閒置、總長與大小上限由參數帶入")
    func longLivedHostFileFetchCarriesTimeLimit() throws {
        let follow = HostFileFetchScript.follow(maximumSize: 1_000, idleSeconds: 7, totalSeconds: 90)
        #expect(follow.contains(HostScriptTimeLimit.posixMarker + "() {"), "取檔腳本沒有包上 HostScriptTimeLimit.posix")
        #expect(follow.hasPrefix(HostFileFetchScript.followInvocation))
        #expect(PosixShell.unquote(String(follow.dropFirst(HostFileFetchScript.followInvocation.count))) == ["7", "90", "1000"])

        let windows = try WindowsCommand.translate(follow)
        #expect(windows.keepsStdinOpen)
        let script = String(decoding: try #require(windows.stdinScript), as: UTF8.self)
        #expect(script.contains("$a=@('7','90','1000')"))
        #expect(script.contains("$purrdrLimit.At"), "Windows 取檔腳本要自己延長／收緊時限")
    }

    @Test("Windows 的 stdin stub 與上傳腳本都帶時限且仍在 cmd 命令列上限內;herdr bridge 不帶(實跑見 scripts/windows-upload-repro.py --kind limit)")
    func windowsOneShotScriptsCarryTimeLimit() throws {
        let uploadName = try #require(HostUploadName("a-1.jpg"))
        let folder = "C:\\Users\\someone\\Documents\\" + String(repeating: "folder name ", count: 8)
        let commands = [
            try WindowsCommand.translate(TranscriptCommand.window(path: "C:/t.jsonl", end: 10, lines: 5)).command,
            try WindowsCommand.translate(HostUploadCommand.posix(name: uploadName, size: 25_000_000)).command,
            try WindowsCommand.translate(HostFolderCommand.upload(
                folder: folder, name: "a long file name.bin", size: 25_000_000, encoding: .gzip, transferSize: 24_000_000)).command,
        ]
        for command in commands {
            let script = try #require(PowerShell.script(inEncodedCommand: command))
            #expect(script.contains("$purrdrLimit"))
            #expect(command.count <= WindowsCommand.commandLimit)
        }
        let bridge = try #require(PowerShell.script(inEncodedCommand: try WindowsCommand.translate(HerdrCommand.bridge()).command))
        #expect(!bridge.contains("$purrdrLimit"))
    }

    #if os(macOS)
    @Test("卡住的 POSIX 腳本在時限內以 exit 124 結束，背景程序、子 shell 與讀 stdin 的程序都不留下")
    func stuckPosixScriptEndsWithinLimit() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let stuck = """
            sleep 30 &
            echo "$!"
            sh -c 'echo "$$"; exec sleep 30' &
            sh -c 'echo "$$"; exec cat'
            """
        let started = ContinuousClock.now

        let session = try await host.execute(Self.posixCommand(HostScriptTimeLimit.posix(stuck, seconds: "2")))
        let stdinCloser = Task {
            try await Task.sleep(for: .seconds(30))
            await session.closeStdin()
        }
        defer { stdinCloser.cancel() }
        let output = try await session.collectOutput()

        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(output.exitCode == 124)
        let children = output.stdoutText.split(separator: "\n").compactMap { Int32($0) }
        #expect(children.count == 3)
        for child in children {
            #expect(await Self.hasEnded(child), "程序 \(child) 還在")
        }
    }

    @Test("沒卡住的 POSIX 腳本：輸出與 exit code 不變，不等時限")
    func normalPosixScriptKeepsOutputAndExitCode() async throws {
        let host = try LocalShellHost.temporary()
        let started = ContinuousClock.now

        let output = try await host.execute(Self.posixCommand(HostScriptTimeLimit.posix("printf 'a b'; exit 3", seconds: "30")))
            .collectOutput()

        #expect(output.stdoutText == "a b")
        #expect(output.exitCode == 3)
        // 時限 30 秒;CI 負載重時啟動 shell 就要幾秒，只確認沒有等到時限。
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    static func posixCommand(_ script: String) -> String {
        "/bin/sh -c " + PosixShell.quote(script) + " purrdr"
    }

    /// 程序已經不在(被收走)。
    static func hasEnded(_ pid: Int32) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    #endif
}
