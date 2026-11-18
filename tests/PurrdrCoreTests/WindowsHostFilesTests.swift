import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// Windows 主機的主機檔案讀寫(#68,行為規格 §11.2「主題/YSK/用量的 CAS 寫入」)。
///
/// PowerShell 腳本本身只能在真的 Windows 上執行(`WindowsRealHostIntegrationTests`);這裡守通道層的約定
/// (指令走固定的 stub、腳本與參數經 stdin、不送 POSIX 腳本)與 client 對 Windows 輸出的解析。
@Suite("Windows 主機的主機檔案")
struct WindowsHostFilesTests {
    static let stub = WindowsHostScriptsTests.stub

    @Test("讀檔：命令列只有固定的 stub,PowerShell 腳本與參數經 stdin 送出;輸出的 home 行讓 client 知道家目錄")
    func readOverStdin() async throws {
        let host = FakeHost()
        let output = "purrdr-files 1\nuser demo\nhome C:/Users/demo\nfile 0 ab12:3 3\n{}\n\nmissing 1\n"
        await host.expect(Self.stub, reply: FakeReply(stdout: Data(output.utf8)))

        let read = try await HostFiles(channel: WindowsHostChannel(host)).read([".claude/settings.json", ".purrdr/x/journal.json"])

        #expect(read.user == "demo")
        #expect(read.home == "C:/Users/demo")
        #expect(read[".claude/settings.json"] == .file(Data("{}\n".utf8), version: HostFileVersion(checksum: "ab12:3")))
        #expect(read[".purrdr/x/journal.json"] == .missing)
        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(stdin.contains("\n$a=@('.claude/settings.json','.purrdr/x/journal.json')\n"))
        #expect(stdin.hasSuffix("\n#purrdr-end-of-script\n"))
        #expect(!stdin.contains("cksum"), "POSIX 腳本不能送到 Windows")
    }

    /// Windows 讀檔的輸出(格式同 `HostFileScript.read`,多一行 home)。
    static func readOutput(_ files: [HostFileState]) -> Data {
        var output = HostFileRequest.readOutput(user: "demo", files: files)
        let header = Data("purrdr-files 1\nuser demo\n".utf8)
        output.replaceSubrange(0..<header.count, with: header + Data("home C:/Users/demo\n".utf8))
        return output
    }

    /// stdin 腳本裡 `$a=@('…','…')` 的參數(PowerShell 單引號規則)。
    static func arguments(inScript stdin: String) throws -> [String] {
        let line = try #require(stdin.split(separator: "\n").first { $0.hasPrefix("$a=@(") })
        var values: [String] = []
        var rest = line.dropFirst("$a=@(".count)
        while rest.first == "'" {
            rest = rest.dropFirst()
            var value = ""
            while let character = rest.first {
                rest = rest.dropFirst()
                if character == "'" {
                    if rest.first == "'" { value.append("'"); rest = rest.dropFirst() } else { break }
                } else {
                    value.append(character)
                }
            }
            values.append(value)
            if rest.first == "," { rest = rest.dropFirst() }
        }
        return values
    }

    /// 寫入指令裡每個 `put` 的路徑與內容。
    static func puts(inScript stdin: String) throws -> [String: Data] {
        let values = try arguments(inScript: stdin)
        var result: [String: Data] = [:]
        for start in stride(from: 0, to: values.count - 4, by: 5) where values[start] == "put" {
            result[values[start + 1]] = Data(base64Encoded: values[start + 3])
        }
        return result
    }

    static let windowsWrapper = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:/Users/demo/.purrdr/claude-usage/statusline.ps1'"

    @Test("Claude 用量(Windows):status line 換成以 PowerShell 執行的包裝腳本(Claude Code 經 Git Bash 或 PowerShell 都能跑),原本的指令另存")
    func claudeUsageInstallOnWindows() async throws {
        let host = FakeHost()
        let settings = Data(#"{"model":"opus","statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh","padding":1}}"#.utf8)
        await host.expect(Self.stub, reply: FakeReply(stdout: Self.readOutput([.file(settings, version: HostFileVersion(checksum: "aa:1")), .missing])))
        await host.expect(Self.stub, reply: FakeReply())

        try await ClaudePlanUsageHost(channel: WindowsHostChannel(host)).install()

        let stdin = try #require(await host.executions.last?.stdinText)
        let puts = try Self.puts(inScript: stdin)
        let written = try #require(puts[".claude/settings.json"])
        let statusLine = try #require((try JSONSerialization.jsonObject(with: written) as? [String: Any])?["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == Self.windowsWrapper)
        #expect(statusLine["padding"] as? Int == 1)
        #expect(puts[".purrdr/claude-usage/original-command"] == Data("bash ~/.claude/statusline.sh".utf8))
        let wrapperBytes = try #require(puts[".purrdr/claude-usage/statusline.ps1"])
        let wrapper = String(decoding: wrapperBytes, as: UTF8.self)
        #expect(wrapper.contains("rate_limits"))
        #expect(wrapperBytes.allSatisfy { $0 < 0x80 }, "PowerShell 5.1 把沒有 BOM 的 .ps1 當系統碼頁讀，要全部 ASCII")
        #expect(puts[".purrdr/claude-usage/statusline.sh"] == nil, "Windows 不放 sh 包裝")
    }

    @Test("主機主題(Windows):讀 herdr 在 Windows 的設定 %APPDATA%\\herdr\\config.toml,不是 ~/.config/herdr")
    func themeOnWindows() async throws {
        let host = FakeHost()
        await host.expect(Self.stub, reply: FakeReply(stdout: Self.readOutput([
            .file(Data("[theme]\nname = \"nord\"\n".utf8), version: HostFileVersion(checksum: "aa:1")),
            .file(Data("[theme]\nname = \"dracula\"\n".utf8), version: HostFileVersion(checksum: "bb:2")),
        ])))

        let theme = try await HostThemeHost(channel: WindowsHostChannel(host)).readTheme()

        #expect(theme.name == "dracula")
        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(try Self.arguments(inScript: stdin) == [".config/herdr/config.toml", "AppData/Roaming/herdr/config.toml"])
    }

    @Test("主機主題(macOS／Linux):一樣一次讀完，用 ~/.config/herdr/config.toml")
    func themeOnPosix() async throws {
        let host = FakeHost()
        await host.expect(
            HostFileScript.command(HostFileScript.read, arguments: [".config/herdr/config.toml", "AppData/Roaming/herdr/config.toml"]),
            reply: FakeReply(stdout: HostFileRequest.readOutput(user: "demo", files: [
                .file(Data("[theme]\nname = \"nord\"\n".utf8), version: HostFileVersion(checksum: "1:2")), .missingDirectory,
            ])))

        #expect(try await HostThemeHost(channel: host).readTheme().name == "nord")
    }

    @Test("Codex 啟動器(Windows 做不到):檢查與安裝都丟 unsupported,不把 sh 啟動器寫到 Windows")
    func codexLauncherUnsupportedOnWindows() async throws {
        let host = FakeHost()
        for _ in 0..<2 {
            await host.expect(Self.stub, reply: FakeReply(stdout: Self.readOutput([.missingDirectory, .missing, .missing, .missingDirectory])))
        }
        let launcher = CodexLauncherHost(channel: WindowsHostChannel(host))

        await #expect(throws: WindowsCommandError.self) { _ = try await launcher.inspect() }
        await #expect(throws: WindowsCommandError.self) { try await launcher.install() }

        #expect(await host.executions.count == 2, "只讀不寫")
    }

    @Test("Claude 用量(Windows):還原時認得 Windows 的包裝指令，換回原本的 status line(使用者另外改的設定保留)")
    func claudeUsageRestoreOnWindows() async throws {
        let host = FakeHost()
        let original = Data(#"{"statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh"}}"#.utf8)
        let installed = Data(#"{"statusLine":{"command":"\#(Self.windowsWrapper)","type":"command"}}"#.utf8)
        let current = Data(#"{"model":"sonnet","statusLine":{"command":"\#(Self.windowsWrapper)","type":"command"}}"#.utf8)
        let journal = try JSONEncoder().encode(HostWriteJournal(entries: [.init(path: ".claude/settings.json", original: original, installed: installed)]))
        await host.expect(Self.stub, reply: FakeReply(stdout: Self.readOutput([
            .file(current, version: HostFileVersion(checksum: "bb:2")), .file(journal, version: HostFileVersion(checksum: "cc:3")),
        ])))
        await host.expect(Self.stub, reply: FakeReply())

        try await ClaudePlanUsageHost(channel: WindowsHostChannel(host)).restore()

        let stdin = try #require(await host.executions.last?.stdinText)
        let written = try #require(try Self.puts(inScript: stdin)[".claude/settings.json"])
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect((object["statusLine"] as? [String: Any])?["command"] as? String == "bash ~/.claude/statusline.sh")
        #expect(object["model"] as? String == "sonnet")
    }
}

/// Windows 主機的 Claude Code slash 清單探索(#68)。
@Suite("Windows 主機的 slash 清單探索")
struct WindowsSlashDiscoveryTests {
    static let stub = WindowsHostScriptsTests.stub
    static let plugin = #"C:\Users\demo\.claude\plugins\cache\demo-market\demo-kit\1.0.0"#

    @Test("三步都經 stdin 的 PowerShell 腳本;installPath 是 C:\\…(Windows 的 installed_plugins.json)也照樣掃 plugin")
    func discoversPluginOnWindows() async throws {
        let host = FakeHost()
        let installed = #"{"version":2,"plugins":{"demo-kit@demo-market":[{"scope":"user","installPath":"C:\\Users\\demo\\.claude\\plugins\\cache\\demo-market\\demo-kit\\1.0.0"}]}}"#
        let first = """
            @F\tinstalled\tC:\\Users\\demo\\.claude/plugins/installed_plugins.json
            |\(installed)

            @S\tuser\tC:\\Users\\demo\\.claude/skills\tC:\\Users\\demo\\.claude/skills/notes/SKILL.md
            |name: notes
            |description: Keep notes

            """
        let second = """
            @F\t\(Self.plugin)\t\(Self.plugin)/.claude-plugin/plugin.json
            |{"name":"demo-kit","skills":"./skills/core"}

            """
        let third = """
            @S\tdemo-kit\t\(Self.plugin)/skills/core\t\(Self.plugin)/skills/core/review/SKILL.md
            |description: Review the diff

            """
        await host.expect(Self.stub, reply: FakeReply(stdout: Data(first.utf8)))
        await host.expect(Self.stub, reply: FakeReply(stdout: Data(second.utf8)))
        await host.expect(Self.stub, reply: FakeReply(stdout: Data(third.utf8)))

        let catalog = await ClaudeSlashDiscovery(channel: WindowsHostChannel(host)).catalog(cwd: #"C:\work"#, transcriptPath: nil)

        let names = catalog.sections.flatMap(\.commands).map(\.name)
        #expect(names.contains("notes"))
        #expect(names.contains("demo-kit:review"))
        #expect(catalog.isComplete)
        let scripts = await host.executions.map(\.stdinText)
        #expect(scripts.count == 3)
        if scripts.count == 3 {
            #expect(try WindowsHostFilesTests.arguments(inScript: scripts[1]) == [Self.plugin])
            #expect(try WindowsHostFilesTests.arguments(inScript: scripts[2]) == ["s", "demo-kit", Self.plugin + "/skills/core", "c", "demo-kit", Self.plugin + "/commands"])
        }
        #expect(scripts.allSatisfy { !$0.contains("awk") && $0.hasSuffix("#purrdr-end-of-script\n") })
    }
}
