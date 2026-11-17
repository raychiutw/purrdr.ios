import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 主機的主機腳本(#26,行為規格 §11.2):對話紀錄、上傳、資料夾。
///
/// 腳本本身(PowerShell)只能在真的 Windows 上執行，行為由 `WindowsRealHostIntegrationTests` 驗證;這裡守的是
/// 通道層的約定：命令列長度、參數怎麼帶、stdin 怎麼用(不靠 EOF),以及 client 對 Windows 輸出的解析。
@Suite("Windows 主機的主機腳本")
struct WindowsHostScriptsTests {
    /// 唯讀腳本的 stub(手寫的預期值):從 stdin 一行一行讀到結束標記才執行，不等 EOF。
    /// stdin 以原始 handle 建 `FileStream` 讀(#77:經 sshd 時 console stream 讀超過約 128 KiB 會卡住);取不到 handle 時退回 console stream。
    /// 自我時限(#92):30 秒內沒讀到結束標記就 exit 124,讀到後腳本本體另有 120 秒。
    static let stub = PowerShell.encodedCommand(
        #"$ProgressPreference='SilentlyContinue';$purrdrSeconds=30;$purrdrLimit=[hashtable]::Synchronized(@{At=[DateTime]::UtcNow.AddSeconds($purrdrSeconds);Files=@()});$purrdrState=[Management.Automation.Runspaces.InitialSessionState]::Create();$purrdrState.LanguageMode='FullLanguage';$purrdrSpace=[runspacefactory]::CreateRunspace($purrdrState);$purrdrSpace.Open();$purrdrSpace.SessionStateProxy.SetVariable('limit',$purrdrLimit);$purrdrWatch=[PowerShell]::Create();$purrdrWatch.Runspace=$purrdrSpace;[void]$purrdrWatch.AddScript('while([DateTime]::UtcNow -lt $limit.At){[Threading.Thread]::Sleep(200)};foreach($file in $limit.Files){try{[IO.File]::Delete($file)}catch{}};[Environment]::Exit(124)').BeginInvoke();$stdin=[Console]::OpenStandardInput();try{$stdin=New-Object IO.FileStream($stdin.GetType().GetField('_handle',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($stdin),[IO.FileAccess]::Read,1,$false)}catch{};$s=New-Object IO.StreamReader($stdin,(New-Object Text.UTF8Encoding $false));$b=New-Object Text.StringBuilder;while(($l=$s.ReadLine()) -ne $null -and $l -ne '#purrdr-end-of-script'){[void]$b.AppendLine($l)};$purrdrLimit.At=[DateTime]::UtcNow.AddSeconds(120);iex $b.ToString()"#)

    static let path = #"C:\Users\demo\.claude\projects\C--work\abc.jsonl"#

    @Test("對話紀錄：命令列只有固定的 stub,腳本與參數經 stdin 送出、以結束標記收尾(Git Bash 下 EOF 可能傳不到)")
    func transcriptScriptOverStdin() async throws {
        let host = FakeHost()
        await host.expect(Self.stub, reply: FakeReply(stdout: Data("80\n".utf8)))

        let tail = try await TranscriptReader(channel: WindowsHostChannel(host)).tail(path: Self.path, from: 80)

        #expect(tail == .unchanged)
        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(stdin.contains("\n$a=@('C:\\Users\\demo\\.claude\\projects\\C--work\\abc.jsonl','80','65536')\n"))
        #expect(stdin.hasSuffix("\n#purrdr-end-of-script\n"))
        #expect(!stdin.contains("awk"), "POSIX 腳本不能送到 Windows")
    }

    @Test("對話紀錄的 Windows 輸出(錄自實測機，三行 303 bytes、第二行有 200 字元的 base64):視窗與追蹤解析成同樣的行")
    func transcriptOutputFromWindows() async throws {
        let host = FakeHost()
        await host.expect(Self.stub, reply: FakeReply(stdout: Fixtures.data("windows/transcript.window.stdout.txt")))
        await host.expect(Self.stub, reply: FakeReply(stdout: Fixtures.data("windows/transcript.tail.stdout.txt")))
        let reader = TranscriptReader(channel: WindowsHostChannel(host), windowChunkBytes: 16)

        let window = try await reader.window(path: Self.path, endingAt: 303, lines: 2)
        let tail = try await reader.tail(path: Self.path, from: 43)

        // 原始長度(237、21)照實回報，游標才精確;圖片字串剝成 ""。
        let lines = [#"{"type":"assistant","n":2,"image":""}"#, #"{"type":"user","n":3}"#]
        #expect(window == TranscriptChunk(start: 43, end: 303, lines: lines))
        #expect(tail == .appended(TranscriptChunk(start: 43, end: 303, lines: lines)))
    }

    @Test("Claude 的定位：exit 3(還沒有檔案)照樣是 absent")
    func claudeLocateAbsent() async {
        let host = FakeHost()
        await host.expect(Self.stub, reply: FakeReply(exitCode: 3))

        await #expect(throws: TranscriptReadError.absent) {
            _ = try await TranscriptReader(channel: WindowsHostChannel(host)).locate(sessionID: "abc", cwd: #"C:\work"#)
        }
        #expect(await host.executions.first?.stdinText.contains("$a=@('abc','C--work')") == true)
    }

    @Test("圖片上傳：腳本與參數在命令列(stdin 留給 bytes),stdin 只有圖片的 bytes")
    func imageUpload() async throws {
        let name = UploadFileName("m3x-abc.jpg")!
        let host = CapturingHost(reply: FakeReply(stdout: Data("C:\\Users\\demo\\.purrdr\\uploads\\m3x-abc.jpg\n".utf8)))

        _ = try await ImageUploader(channel: WindowsHostChannel(host)).upload(Data([0, 0x0D, 0x0A, 0x1A]), named: name)

        let command = try #require(await host.fake.executions.first?.command)
        let script = try #require(PowerShell.script(inEncodedCommand: command))
        #expect(script.contains("\n$a=@('m3x-abc.jpg','4')\n"))
        #expect(script.contains(#"Join-Path $env:USERPROFILE '.purrdr\uploads'"#))
        #expect(await host.fake.executions.first?.stdin == Data([0, 0x0D, 0x0A, 0x1A]))
        #expect(command.count <= 8_191, "cmd 的命令列上限")
    }

    @Test("檔案上傳：參數在命令列(引號照 PowerShell 規則);長路徑仍在 cmd 的命令列上限內")
    func folderUpload() async throws {
        let longFolder = #"C:\Users\demo\"# + String(repeating: "很長的資料夾名稱", count: 30)
        let host = CapturingHost(reply: FakeReply(stdout: Data((longFolder + #"\報告 it's.pdf"# + "\n").utf8)))

        _ = try await HostFolders(channel: WindowsHostChannel(host)).upload(Data("123456789".utf8), named: "報告 it's.pdf", to: longFolder)

        let command = try #require(await host.fake.executions.first?.command)
        #expect(try #require(PowerShell.script(inEncodedCommand: command)).contains("\n$a=@('\(longFolder)','報告 it''s.pdf','9','identity','9')\n"))
        #expect(command.count <= 8_191)
    }

    @Test("檔案上傳以 gzip 傳輸：傳輸編碼與傳輸大小帶進參數,stdin 只有 gzip 後的 bytes")
    func folderUploadGzip() async throws {
        let host = CapturingHost(reply: FakeReply(stdout: Data((#"C:\work\build.log"# + "\n").utf8)))
        let original = Data(repeating: 0x61, count: 1_000)

        _ = try await HostFolders(channel: WindowsHostChannel(host), deflate: FixedDeflate(output: Data([1, 2, 3])))
            .upload(original, named: "build.log", to: #"C:\work"#)

        let command = try #require(await host.fake.executions.first?.command)
        #expect(try #require(PowerShell.script(inEncodedCommand: command)).contains(#"$a=@('C:\work','build.log','1000','gzip','21')"#))
        let stdin = try #require(await host.fake.executions.first?.stdin)
        #expect(stdin.count == 21)
        #expect(Array(stdin.prefix(2)) == [0x1F, 0x8B])
    }

    @Test("資料夾清單、新增對話的資料夾：走 stdin 的唯讀腳本")
    func folderListings() async throws {
        let host = FakeHost()
        await host.expect(Self.stub, reply: FakeReply(stdout: Data("C:\\Users\\demo\nd--------- 1 0 0 0 Nov 16 09:05 work\n".utf8)))
        await host.expect(Self.stub, reply: FakeReply(stdout: Data("C:\\Users\\demo\nwork\n".utf8)))
        let channel = WindowsHostChannel(host)

        #expect(try await HostFolders(channel: channel).list().entries.map(\.name) == ["work"])
        #expect(try await NewChatFolders(channel: channel).list("~").folders == ["work"])
        #expect(await host.executions.map(\.stdinText).allSatisfy { $0.hasSuffix("#purrdr-end-of-script\n") })
        #expect(await host.executions.first?.stdinText.contains("\n$a=@('')\n") == true)
        #expect(await host.executions.last?.stdinText.contains("\n$a=@('~')\n") == true)
    }
}

/// 不管指令是什麼都回同一個回應的主機(指令內容由測試事後檢查)。
actor CapturingHost: HostChannel {
    let fake = FakeHost()
    private let reply: FakeReply

    init(reply: FakeReply) {
        self.reply = reply
    }

    func execute(_ command: String) async throws -> any ExecSession {
        await fake.expect(command, reply: reply)
        return try await fake.execute(command)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await fake.openPTY(request) }
}
