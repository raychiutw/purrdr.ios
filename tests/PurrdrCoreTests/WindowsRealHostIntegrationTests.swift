import Crypto
import Foundation
import PurrdrCore
import Testing

/// 對真實 Windows 主機(OpenSSH + herdr Windows 版)的整合測試(#26),以環境變數開啟(預設不跑;CI 不跑)。
///
/// ```bash
/// PURRDR_WINDOWS_HOST=user@host[:port] PURRDR_WINDOWS_KEY=~/.ssh/<私鑰> \
///   swift test --filter WindowsRealHostIntegrationTests
/// # 可選:PURRDR_WINDOWS_FINGERPRINT=SHA256:…(比對 TOFU 回報的指紋)
/// ```
///
/// 安全規則：使用者既有的 workspace 只讀(`session.snapshot`、`ping`),不送按鍵、不 attach。會寫入的測試只寫在
/// `%TEMP%\purrdr-test-<亂數>`(測完整個刪掉);Pane 終端機只開在自建的 `purrdr-test` workspace(只有 shell、
/// 不啟動 agent,測完以建立時拿到的 id 關閉)。預設 shell 是 cmd／PowerShell 的情況，在 Git Bash 裡明確呼叫
/// `cmd.exe`／`powershell.exe` 模擬(`DefaultShellChannel`),不改主機設定。
@Suite("Windows 真實主機整合測試", .serialized, .enabled(if: WindowsRealHost.isConfigured))
struct WindowsRealHostIntegrationTests {
    // MARK: - 主機偵測與 herdr

    @Test("連線測試：Git Bash 的 uname 認成 Windows,herdr 指令走 PowerShell,讀到 ≥ 0.9.5 與 snapshot")
    func probeOverDefaultShell() async throws {
        let channel = try await WindowsRealHost.channel()
        let report = try await HostProbe(channel: channel, herdr: HerdrInstallation()).run()
        log("Windows:herdr \(report.herdrVersion) · \(report.operatingSystem) · \(report.agentCount) agents")
        #expect(report.operatingSystem == .windows)
        #expect(report.herdrVersion >= .minimumSupported)
        await channel.disconnect()
    }

    @Test("預設 shell 是 cmd 或 PowerShell(模擬):沒有 uname 也偵測得到 Windows,herdr 與對話紀錄指令照樣能跑",
          arguments: [DefaultShellChannel.Shell.cmd, .powershell])
    func probeWithoutUname(shell: DefaultShellChannel.Shell) async throws {
        let ssh = try await WindowsRealHost.channel()
        let channel = DefaultShellChannel(base: ssh, shell: shell)
        let report = try await HostProbe(channel: channel, herdr: HerdrInstallation()).run()
        #expect(report.operatingSystem == .windows)
        let temp = try await WindowsTemp.create(on: ssh)
        defer { Task { await temp.remove() } }
        let path = temp.path + #"\stub.jsonl"#
        try await temp.write(Data("{\"a\":1}\n".utf8), to: path)
        let size = try await TranscriptReader(channel: WindowsHostChannel(channel)).size(path: path)
        log("\(shell):\(report.operatingSystem) · stdin 腳本讀到大小 \(size)")
        #expect(size == 8)
        await temp.remove()
        await ssh.disconnect()
    }

    @Test("herdr 不在 PATH:試 %LOCALAPPDATA%\\Programs\\Herdr\\bin 的相容別名")
    func herdrFallbackWhenNotOnPath() async throws {
        let ssh = try await WindowsRealHost.channel()
        let channel = WindowsHostChannel(EnvironmentChannel(base: ssh, environment: [
            "PATH": #"C:\Windows\System32;C:\Windows\System32\WindowsPowerShell\v1.0"#,
        ]))
        let session = try await channel.execute(HerdrCommand.version(HerdrInstallation()))
        await session.closeStdin()
        let result = try await WindowsRealHost.collect(session)
        log("PATH 沒有 herdr:exit \(result.exitCode) · \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(result.exitCode == 0)
        #expect(HerdrVersion(result.stdout) != nil)
        await ssh.disconnect()
    }

    @Test("具名 session 不存在:Rust 的錯誤格式也判成伺服器沒在跑")
    func namedSessionNotRunning() async throws {
        let ssh = try await WindowsRealHost.channel()
        await #expect(throws: HostProbeError.serverNotRunning) {
            _ = try await HostProbe(channel: ssh, herdr: HerdrInstallation(session: "purrdr-nosuch")).run()
        }
        await ssh.disconnect()
    }

    // MARK: - Pane 終端機(只在自建 workspace)

    @Test("Pane 終端機:在自建的 purrdr-test workspace 以 control 接上 shell pane、送字、收到畫面、release")
    func paneTerminalInOwnWorkspace() async throws {
        let ssh = try await WindowsRealHost.channel()
        let channel = WindowsHostChannel(ssh)
        let client = HerdrClient(channel: channel)
        let temp = try await WindowsTemp.create(on: ssh)
        let created = try await client.createWorkspace(cwd: temp.path, label: "purrdr-test")
        log("建立 workspace \(created.workspaceID)、pane \(created.rootPaneID)")
        do {
            let connection = try await PaneTerminalClient(channel: channel).control(target: created.rootPaneID, columns: 60, rows: 12)
            var screen = Data()
            var sent = false
            for await event in connection.events {
                guard case .frame(let frame) = event else { continue }
                screen.append(frame.bytes)
                if !sent {
                    sent = true
                    try await connection.send(bytes: Data("Write-Output purrdr-$(6*7)\r".utf8))
                }
                if String(decoding: screen, as: UTF8.self).contains("purrdr-42") { break }
            }
            await connection.release()
            #expect(String(decoding: screen, as: UTF8.self).contains("purrdr-42"))
        } catch {
            Issue.record("Pane 終端機失敗:\(error)")
        }
        // 只關自己建的那個 workspace。
        try await client.closeWorkspace(created.workspaceID)
        let left = try await client.snapshot().agents.filter { $0.paneID.hasPrefix(created.workspaceID + ":") }
        #expect(left.isEmpty)
        log("已關閉 workspace \(created.workspaceID)")
        await temp.remove()
        await ssh.disconnect()
    }

    // MARK: - 對話紀錄

    @Test("對話紀錄：定位(回報的路徑、Claude、Codex、Grok、Pi、Antigravity)、視窗、追蹤、列表預覽，都在暫存資料夾")
    func transcripts() async throws {
        let ssh = try await WindowsRealHost.channel()
        let temp = try await WindowsTemp.create(on: ssh)
        defer { Task { await temp.remove() } }
        let image = String(repeating: "A", count: 200)
        let lines = [
            #"{"type":"user","n":1,"text":"中文 🙂"}"#,
            #"{"type":"assistant","n":2,"image":"\#(image)"}"#,
            #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"text","text":"完成了 🙂"}]}}"#,
        ]
        let body = Data(lines.map { $0 + "\n" }.joined().utf8)
        let id = "11111111-2222-3333-4444-555555555555"
        let claudeFile = temp.path + #"\claude\projects\C--work\"# + id + ".jsonl"
        try await temp.write(body, to: claudeFile)
        try await temp.write(body, to: temp.path + #"\codex\sessions\2026\11\16\rollout-2026-11-16T10-00-00-"# + id + ".jsonl")
        try await temp.write(body, to: temp.path + #"\grok\sessions\enc-cwd\"# + id + #"\updates.jsonl"#)
        try await temp.write(body, to: temp.path + #"\pi\sessions\proj\2026_"# + id + ".jsonl")
        try await temp.write(body, to: temp.path + #"\home\.gemini\antigravity-cli\brain\"# + id + #"\.system_generated\logs\transcript.jsonl"#)
        let channel = WindowsHostChannel(EnvironmentChannel(base: ssh, environment: [
            "CLAUDE_CONFIG_DIR": temp.path + #"\claude"#, "CODEX_HOME": temp.path + #"\codex"#,
            "GROK_HOME": temp.path + #"\grok"#, "PI_CODING_AGENT_DIR": temp.path + #"\pi"#, "USERPROFILE": temp.path + #"\home"#,
        ]))
        let reader = TranscriptReader(channel: channel, windowChunkBytes: 16)

        log("定位 Claude…")
        let claude = try await reader.locate(sessionID: id, cwd: #"C:\work"#)
        #expect(claude == TranscriptFile(path: claudeFile, size: body.count))
        for target in [
            TranscriptTarget(format: .codex, location: .codex(sessionID: id), sessionKey: id),
            TranscriptTarget(format: .grok, location: .grok(sessionID: id), sessionKey: id),
            TranscriptTarget(format: .piJournal, location: .piJournal(sessionID: id), sessionKey: id),
            TranscriptTarget(format: .antigravity, location: .antigravity(sessionID: id), sessionKey: id),
        ] {
            do {
                let file = try await reader.locate(target)
                log("定位 \(target.location):\(file.path)")
                #expect(file.size == body.count)
            } catch TranscriptReadError.mismatch {
                // Pi／Codex 的 header 檢查要真的 session header;這裡只驗證找得到檔、讀得到前兩行。
                log("定位 \(target.location):找到檔案(header 不是真的 session,mismatch)")
            }
        }
        await #expect(throws: TranscriptReadError.absent) {
            _ = try await reader.locate(sessionID: "99999999-0000-0000-0000-000000000000", cwd: #"C:\work"#)
        }

        log("視窗、追蹤…")
        let window = try await reader.window(path: claudeFile, endingAt: body.count, lines: 2)
        #expect(window.end == body.count)
        #expect(window.lines == [#"{"type":"assistant","n":2,"image":""}"#, lines[2]])
        let tail = try await reader.tail(path: claudeFile, from: lines[0].utf8.count + 1)
        #expect(tail == .appended(TranscriptChunk(
            start: lines[0].utf8.count + 1, end: body.count, lines: [#"{"type":"assistant","n":2,"image":""}"#, lines[2]])))
        #expect(try await reader.tail(path: claudeFile, from: body.count) == .unchanged)

        let previews = try await reader.previews(of: [
            PreviewRequest(key: "c", sessionID: id, cwd: #"C:\work"#),
            PreviewRequest(key: "missing", sessionID: "99999999-0000-0000-0000-000000000000", cwd: #"C:\work"#),
        ])
        log("預覽:\(previews.mapValues { String(describing: $0) })")
        #expect(previews["c"] != nil)
        await temp.remove()
        await ssh.disconnect()
    }

    @Test("subagent、workflow、委派：找 meta、讀 journal(checksum 相同不重傳)、父對話紀錄中指名委派的行")
    func delegations() async throws {
        let ssh = try await WindowsRealHost.channel()
        let temp = try await WindowsTemp.create(on: ssh)
        defer { Task { await temp.remove() } }
        let session = temp.path + #"\projects\C--work\abc"#
        let call = "toolu_demo_01"
        try await temp.write(Data(#"{"agentType":"general","toolUseId":"\#(call)"}"#.utf8), to: session + #"\subagents\agent-a1.meta.json"#)
        try await temp.write(Data(#"{"agentType":"general","toolUseId":"toolu_other"}"#.utf8), to: session + #"\subagents\agent-a2.meta.json"#)
        try await temp.write(Data("{\"n\":1}\n{\"n\":2}\n".utf8), to: session + #"\subagents\workflows\run1\journal.jsonl"#)
        let parent = session + ".jsonl"
        try await temp.write(Data("{\"x\":\"\(call)\"}\n{\"y\":1}\n{\"z\":\"agent-a1\"}\n".utf8), to: parent)
        let reader = TranscriptReader(channel: WindowsHostChannel(ssh))

        #expect(try await reader.locateSubagent(sessionFolder: session, callID: call) == session + #"\subagents\agent-a1.jsonl"#)
        let workflow = try await reader.readWorkflow(sessionFolder: session, runID: "run1", knownChecksum: nil)
        guard case .journal(let checksum, let lines) = workflow else {
            Issue.record("不是 journal:\(workflow)")
            return
        }
        #expect(lines == [#"{"n":1}"#, #"{"n":2}"#])
        #expect(try await reader.readWorkflow(sessionFolder: session, runID: "run1", knownChecksum: checksum) == .unchanged)
        let delegation = try await reader.delegationLines(path: parent, callID: call, agentID: "agent-a1", knownChecksum: nil)
        #expect(delegation.lines == [#"{"x":"\#(call)"}"#, #"{"z":"agent-a1"}"#])
        #expect(try await reader.delegationLines(path: parent, callID: call, agentID: "agent-a1", knownChecksum: delegation.checksum).lines == nil)
        log("委派:workflow \(checksum) · 委派 \(delegation.checksum)")
        await temp.remove()
        await ssh.disconnect()
    }

    // MARK: - 上傳

    @Test("上傳圖片(%USERPROFILE% 指向暫存資料夾)與檔案：bytes 經 stdin 原樣寫入、不覆寫;資料夾清單與新增對話的資料夾")
    func uploadsAndFolders() async throws {
        let ssh = try await WindowsRealHost.channel()
        let temp = try await WindowsTemp.create(on: ssh)
        defer { Task { await temp.remove() } }
        let home = temp.path + #"\家"#
        try await temp.makeDirectory(home + #"\專案"#)
        let channel = WindowsHostChannel(EnvironmentChannel(base: ssh, environment: ["USERPROFILE": home]))
        var bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        bytes.append(contentsOf: [0x0D, 0x0A, 0x1A, 0x00])

        let name = UploadFileName("purrdr-test-1.jpg")!
        log("上傳圖片…")
        let path = try await ImageUploader(channel: channel).upload(bytes, named: name)
        log("圖片:\(path)")
        #expect(path == home + #"\.purrdr\uploads\purrdr-test-1.jpg"#)
        #expect(try await temp.sha256(of: path) == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        await #expect(throws: ImageUploadError.self) { _ = try await ImageUploader(channel: channel).upload(bytes, named: name) }

        let files = HostFolders(channel: channel)
        log("上傳檔案…")
        let uploaded = try await files.upload(bytes, named: "報告 1.bin", to: home + #"\專案"#)
        #expect(uploaded == home + #"\專案\報告 1.bin"#)
        await #expect(throws: HostFolderError.alreadyExists) { _ = try await files.upload(bytes, named: "報告 1.bin", to: home + #"\專案"#) }
        log("列資料夾…")
        let listing = try await files.list(home + #"\專案"#)
        log("清單:\(listing.path) · \(listing.entries.map(\.name))")
        #expect(listing.entries == [FolderEntry(name: "報告 1.bin", kind: .file, size: Int64(bytes.count), modified: listing.entries.first?.modified)])
        let homeListing = try await files.list()
        #expect(homeListing.path == home)
        #expect(homeListing.entries.contains { $0.name == "專案" && $0.kind == .folder })

        log("新增對話的資料夾…")
        let folders = try await NewChatFolders(channel: channel).list("~")
        #expect(folders == NewChatFolderListing(path: home, folders: ["專案"]))
        await #expect(throws: NewChatFolderError.notFound("~/nope")) { _ = try await NewChatFolders(channel: channel).list("~/nope") }
        await temp.remove()
        await ssh.disconnect()
    }

    // MARK: - 登入 Shell

    @Test("登入 Shell:PTY 開使用者預設的 shell(實測機是 Git Bash),打字有回應")
    func loginShell() async throws {
        let ssh = try await WindowsRealHost.channel()
        let pty = try await WindowsHostChannel(ssh).openPTY(PTYRequest(columns: 80, rows: 24))
        var screen = Data()
        var sent = false
        var found = false
        for try await chunk in pty.output {
            screen.append(chunk)
            if !sent {
                sent = true
                try await pty.write(Data("echo purrdr-$((6*7))\r".utf8))
            }
            if String(decoding: screen, as: UTF8.self).contains("purrdr-42") {
                found = true
                break
            }
        }
        try? await pty.write(Data("exit\r".utf8))
        await pty.close()
        #expect(found)
        await ssh.disconnect()
    }
}

// MARK: - 測試工具

/// 立即寫到 stderr(stdout 導到檔案時有緩衝，測試卡住被中止就看不到)。
func log(_ text: String) {
    FileHandle.standardError.write(Data(("[Windows] " + text + "\n").utf8))
}

enum WindowsRealHost {
    static let environment = ProcessInfo.processInfo.environment
    static var isConfigured: Bool { environment["PURRDR_WINDOWS_HOST"] != nil && environment["PURRDR_WINDOWS_KEY"] != nil }

    /// 以私鑰登入的 SSH 通道;先以 TOFU 拿到指紋再 pin。
    static func channel() async throws -> SSHHostChannel {
        let endpoint = try #require(RealHostIntegrationTests.endpoint(environment["PURRDR_WINDOWS_HOST"] ?? ""))
        let keyPath = (environment["PURRDR_WINDOWS_KEY"] ?? "").replacingOccurrences(of: "~", with: NSHomeDirectory())
        let key = try SSHPrivateKey(openSSH: String(contentsOfFile: keyPath, encoding: .utf8))
        let credential: SSHCredentialProvider = { .privateKey(key) }
        do {
            _ = try await SSHHostChannel(endpoint: endpoint, hostKeyPin: nil, credential: credential).execute("true")
            throw WindowsRealHostError.loggedInWithoutPin
        } catch SSHConnectionError.hostKeyUnverified(let presented) {
            if let expected = environment["PURRDR_WINDOWS_FINGERPRINT"] {
                #expect(presented == HostKeyFingerprint(stored: expected))
            }
            return SSHHostChannel(endpoint: endpoint, hostKeyPin: presented, credential: credential)
        }
    }

    struct Result {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    static func collect(_ session: any ExecSession) async throws -> Result {
        var stdout = Data()
        var stderr = Data()
        var code: Int32 = -1
        for try await event in session.output {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            case .exit(let exit, _): code = exit
            }
        }
        await session.close()
        return Result(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: code)
    }

    /// 在主機上跑一段 PowerShell(測試準備與檢查用)。
    static func powershell(_ script: String, on channel: any HostChannel) async throws -> Result {
        let session = try await channel.execute(PowerShell.encodedCommand("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';" + script))
        await session.closeStdin()
        let result = try await collect(session)
        guard result.exitCode == 0 else { throw WindowsRealHostError.script(WindowsErrorText.readable(result.stderr)) }
        return result
    }
}

enum WindowsRealHostError: Error {
    case loggedInWithoutPin
    case script(String)
}

/// `%TEMP%\purrdr-test-<亂數>`:測試只寫在這裡，測完整個刪掉。
struct WindowsTemp: Sendable {
    let channel: any HostChannel
    let path: String

    static func create(on channel: any HostChannel) async throws -> WindowsTemp {
        let result = try await WindowsRealHost.powershell(
            "$d=Join-Path $env:TEMP ('purrdr-test-'+[Guid]::NewGuid().ToString('N').Substring(0,8));[void](New-Item -ItemType Directory -Path $d);[Console]::Out.Write($d)",
            on: channel)
        log("暫存資料夾:\(result.stdout)")
        return WindowsTemp(channel: channel, path: result.stdout)
    }

    func makeDirectory(_ directory: String) async throws {
        _ = try await WindowsRealHost.powershell("[void][IO.Directory]::CreateDirectory(\(PowerShell.quote(directory)))", on: channel)
    }

    func write(_ data: Data, to file: String) async throws {
        _ = try await WindowsRealHost.powershell(
            "$f=\(PowerShell.quote(file));[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f));[IO.File]::WriteAllBytes($f,[Convert]::FromBase64String('\(data.base64EncodedString())'))",
            on: channel)
    }

    func sha256(of file: String) async throws -> String {
        try await WindowsRealHost.powershell("[Console]::Out.Write((Get-FileHash -Algorithm SHA256 -LiteralPath \(PowerShell.quote(file))).Hash.ToLower())", on: channel).stdout
    }

    /// 只刪 `%TEMP%\purrdr-test-` 開頭的資料夾;刪完確認不在了。
    func remove() async {
        let script = "$d=\(PowerShell.quote(path));if(-not $d.StartsWith((Join-Path $env:TEMP 'purrdr-test-'))){throw 'not a test folder'};if(Test-Path -LiteralPath $d){Remove-Item -LiteralPath $d -Recurse -Force};[Console]::Out.Write((Test-Path -LiteralPath $d))"
        if let result = try? await WindowsRealHost.powershell(script, on: channel), result.stdout == "False" {
            log("已刪除暫存資料夾 \(path)")
        }
    }
}

/// 在 Git Bash 裡明確以 cmd 或 PowerShell 執行指令：模擬 OpenSSH 預設 shell 是它們的主機(不改主機設定)。
struct DefaultShellChannel: HostChannel {
    enum Shell: String, Sendable, CustomTestStringConvertible {
        case cmd
        case powershell
        var testDescription: String { rawValue }
    }

    let base: any HostChannel
    let shell: Shell

    func execute(_ command: String) async throws -> any ExecSession {
        switch shell {
        case .cmd:
            // MSYS 會把 `/c` 改成路徑，所以寫 `//c`;整段以單引號交給 Git Bash。
            try await base.execute("cmd.exe //c " + PosixShell.quote(command))
        case .powershell:
            try await base.execute(PowerShell.encodedCommand(command))
        }
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
}

/// 改環境變數後再執行 PowerShell 指令(把測試的家目錄、agent 設定目錄指到暫存資料夾):在腳本最前面加上設定，同一個程序。
struct EnvironmentChannel: HostChannel {
    let base: any HostChannel
    let environment: [String: String]

    func execute(_ command: String) async throws -> any ExecSession {
        guard let script = PowerShell.script(inEncodedCommand: command) else { return try await base.execute(command) }
        let assignments = environment.sorted { $0.key < $1.key }.map { "$env:\($0.key)=\(PowerShell.quote($0.value))" }.joined(separator: ";")
        return try await base.execute(PowerShell.encodedCommand(assignments + "\n" + script))
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
}
