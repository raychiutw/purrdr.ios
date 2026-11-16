import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 主機通道(#26):app 照常送 POSIX 指令，`WindowsHostChannel` 在通道層換成
/// `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`(行為規格 §3.9、§11.2「指令外殼」)。
/// 不要求 Git Bash:預設 shell 是 cmd、PowerShell 或 Git Bash 都送同一行。
@Suite("Windows 主機通道")
struct WindowsHostChannelTests {
    /// herdr 指令的 PowerShell 腳本(手寫的預期值，與實作分開):找不到 `herdr` 時試安裝程式的相容別名，
    /// 都沒有就 exit 127(與 POSIX 的「找不到指令」相同)。
    static func herdrScript(_ arguments: String, path: String = "$h='herdr'", fallback: Bool = true) -> String {
        let missing = #"[Console]::Error.Write("herdr: command not found`n");exit 127"#
        let lookup = fallback
            ? #"if(-not(Get-Command $h -CommandType Application -ErrorAction SilentlyContinue)){$h=Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe';if(-not(Test-Path -LiteralPath $h)){"# + missing + "}}"
            : #"if(-not(Get-Command $h -CommandType Application -ErrorAction SilentlyContinue)){"# + missing + "}"
        return """
            $ProgressPreference='SilentlyContinue'
            \(path)
            \(lookup)
            & $h \(arguments)
            exit $LASTEXITCODE
            """
    }

    static func encoded(_ script: String) -> String { PowerShell.encodedCommand(script) }

    @Test("-EncodedCommand 是腳本的 UTF-16LE base64(對照 Python 算出的值),外層固定 NoLogo／NoProfile／NonInteractive")
    func encodedCommandFormat() {
        #expect(PowerShell.encodedCommand("exit 0") == "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ZQB4AGkAdAAgADAA")
        #expect(PowerShell.encodedCommand("Write-Output '中'")
            == "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand VwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAC1OJwA=")
        #expect(PowerShell.script(inEncodedCommand: PowerShell.encodedCommand("exit 0")) == "exit 0")
    }

    @Test("PowerShell 的引號：單引號包住，內部單引號寫成兩個")
    func quoting() {
        #expect(PowerShell.quote("w1:p1") == "'w1:p1'")
        #expect(PowerShell.quote("it's") == "'it''s'")
        #expect(PowerShell.quote("$env:X `n") == "'$env:X `n'")
        // PowerShell 把彎引號也當單引號。
        #expect(PowerShell.quote("a\u{2019}b") == "'a\u{2019}\u{2019}b'")
    }

    @Test("bridge:包成 -EncodedCommand 呼叫 herdr,stdin 原樣轉給 herdr、不送 EOF")
    func bridgeOverPowerShell() async throws {
        let host = FakeHost()
        await host.expect(Self.encoded(Self.herdrScript("'remote-api-bridge'")), reply: .recorded("windows/ping.powershell.ndjson"))

        #expect(try await HerdrClient(channel: WindowsHostChannel(host)).ping() == "0.9.5")
        #expect(await host.executions.first?.stdinText == #"{"id":"purrdr:ping","method":"ping","params":{}}"# + "\n")
        #expect(await host.executions.first?.closedStdin == false)
    }

    @Test("具名 session 照樣放在子指令前;terminal session control 的參數逐一引號")
    func namedSessionAndTerminal() async throws {
        let herdr = HerdrInstallation(session: "work")
        let host = FakeHost()
        await host.expect(
            Self.encoded(Self.herdrScript("'--session' 'work' 'terminal' 'session' 'control' 'w1:p1' '--cols' '80' '--rows' '24' '--takeover'")),
            reply: FakeReply(keepsOpen: true))

        _ = try await PaneTerminalClient(channel: WindowsHostChannel(host), herdr: herdr)
            .control(target: "w1:p1", columns: 80, rows: 24, takeover: true)

        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("自訂的 herdr 路徑：不試相容別名;~/ 開頭接在 %USERPROFILE% 後面")
    func customHerdrPath() async throws {
        let host = FakeHost()
        await host.expect(
            Self.encoded(Self.herdrScript("'--version'", path: #"$h='C:\tools\it''s\herdr.exe'"#, fallback: false)),
            reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))
        await host.expect(
            Self.encoded(Self.herdrScript("'--version'", path: "$h=Join-Path $env:USERPROFILE '.herdr/bin/herdr.exe'", fallback: false)),
            reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))
        let channel = WindowsHostChannel(host)

        _ = try await channel.execute(HerdrCommand.version(HerdrInstallation(path: #"C:\tools\it's\herdr.exe"#)))
        _ = try await channel.execute(HerdrCommand.version(HerdrInstallation(path: "~/.herdr/bin/herdr.exe")))

        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("更新 herdr:Windows 沒有 live handoff,只跑 update(行為規格 §11.1)")
    func updateWithoutHandoff() async throws {
        let host = FakeHost()
        await host.expect(Self.encoded(Self.herdrScript("'update'")), reply: FakeReply())

        _ = try await WindowsHostChannel(host).execute(HerdrCommand.update(HerdrInstallation()))

        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("還沒有 PowerShell 版本的指令：丟 unsupported,不把 POSIX 腳本送到 Windows")
    func unsupportedCommand() async {
        let host = FakeHost()
        let command = HerdrCommand.operatingSystem

        await #expect(throws: WindowsCommandError.unsupported(command)) {
            _ = try await WindowsHostChannel(host).execute(command)
        }
        #expect(await host.executions.isEmpty)
    }

    @Test("喚醒探測的 `true` 原樣送出：不付 PowerShell 的啟動成本(期限 3 秒)")
    func wakeProbePassesThrough() async {
        let host = FakeHost()
        await host.expect("true", reply: FakeReply(exitCode: 1))

        #expect(await WakeProbe(channel: WindowsHostChannel(host)).run())
    }

    @Test("登入 Shell:不帶指令的 PTY 原樣交給 sshd,開使用者的預設 shell(Git Bash、cmd 或 PowerShell)")
    func loginShellPassesThrough() async throws {
        let host = FakeHost()
        let request = PTYRequest(columns: 80, rows: 24)
        await host.expectPTY(request, output: Data("PS C:\\Users\\demo> ".utf8))

        let pty = try await WindowsHostChannel(host).openPTY(request)

        #expect(await host.ptys.first?.request == request)
        await pty.close()
    }
}
