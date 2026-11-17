import Foundation
@testable import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機腳本的自我時限(#92):一次性腳本超過時限就結束自己與子程序，不在主機上留下程序。
@Suite("主機腳本時限")
struct HostScriptTimeLimitTests {
    @Test("一次性的 POSIX 主機指令都帶時限;長時間串流(bridge、Pane 終端機)不帶")
    func oneShotPosixCommandsCarryTimeLimit() throws {
        let uploadName = try #require(UploadFileName("a-1.jpg"))
        let oneShot = [
            TranscriptCommand.locate(sessionID: "s", projectFolder: "p"),
            TranscriptCommand.window(path: "/t.jsonl", end: 10, lines: 5),
            ClaudeSlashCommand.discover(cwd: "/w", transcriptPath: nil),
            HostFileScript.command(HostFileScript.read, arguments: ["a"]),
            HostFolderCommand.list(nil),
            HostFolderCommand.upload(folder: "/f", name: "n", size: 3),
            NewChatFolders.command(for: "~"),
            ImageUploadCommand.posix(name: uploadName, size: 3),
        ]
        for command in oneShot {
            #expect(command.contains(HostScriptTimeLimit.posixMarker), "\(command.prefix(120))")
        }
        let streams = [HerdrCommand.bridge(), HerdrCommand.terminalSessionControl(target: "p", columns: 80, rows: 24)]
        for command in streams {
            #expect(!command.contains(HostScriptTimeLimit.posixMarker))
        }
    }

    #if os(macOS)
    @Test("卡住的 POSIX 腳本在時限內以 exit 124 結束，背景程序、子 shell 與讀 stdin 的程序都不留下")
    func stuckPosixScriptEndsWithinLimit() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let stuck = """
            sleep 12 &
            echo "$!"
            sh -c 'echo "$$"; exec sleep 12' &
            sh -c 'echo "$$"; exec cat'
            """
        let started = ContinuousClock.now

        let session = try await host.execute(Self.posixCommand(HostScriptTimeLimit.posix(stuck, seconds: "2")))
        let stdinCloser = Task {
            try await Task.sleep(for: .seconds(12))
            await session.closeStdin()
        }
        defer { stdinCloser.cancel() }
        let output = try await session.collectOutput()

        #expect(ContinuousClock.now - started < .seconds(8))
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
        #expect(ContinuousClock.now - started < .seconds(3))
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
