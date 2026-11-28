import Foundation
import PurrdrCore

/// Windows 主機的主機通道(#26):包住真正的通道，把 app 送出的 POSIX 指令換成 PowerShell 方言。
///
/// 呼叫端(`HerdrClient`、`TranscriptReader`、`SSHHostUploader`…)照常送 POSIX 指令，不知道主機是 Windows;
/// 換方言集中在這一層(`WindowsCommand`)。認不得的指令丟 `WindowsCommandError.unsupported`,不會把 POSIX
/// 腳本送到 Windows 上執行。
///
/// - 一般指令：整段包成 `-EncodedCommand`(`PowerShell.encodedCommand`)。
/// - 經 stdin 的腳本(對話紀錄、資料夾清單、主機檔案讀寫、slash 清單探索):命令列只放一個固定的小 stub,腳本經 stdin 送過去再送 EOF。
///   cmd 是預設 shell 時命令列上限是 8,191 字元,UTF-16 base64 會把腳本放大約 2.7 倍,放不下這些腳本。
/// - PTY 不帶指令(登入 Shell)時原樣交給主機：sshd 開使用者的預設 shell(行為規格 §11.1)。
public struct WindowsHostChannel: HostChannel {
    private let base: any HostChannel

    public init(_ base: any HostChannel) {
        self.base = base
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        let invocation = try WindowsCommand.translate(command)
        let session = WindowsExecSession(try await base.execute(invocation.command))
        if let script = invocation.stdinScript {
            do {
                try await session.write(script)
            } catch {
                await session.close()
                throw error
            }
            if !invocation.keepsStdinOpen { await session.closeStdin() }
        }
        return session
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        guard let command = request.command else {
            // 登入 Shell:不依賴 OpenSSH 的 DefaultShell(預設 cmd),明確開 PowerShell(#732)。
            var login = request
            login.command = WindowsCommand.loginShell
            return try await base.openPTY(login)
        }
        let invocation = try WindowsCommand.translate(command)
        guard invocation.stdinScript == nil else { throw WindowsCommandError.unsupported(command) }
        var translated = request
        translated.command = invocation.command
        return try await base.openPTY(translated)
    }

    public func disconnect() async {
        await base.disconnect()
    }

    public func beginQuickDisconnectDetection() async {
        await base.beginQuickDisconnectDetection()
    }

    public func endQuickDisconnectDetection() async {
        await base.endQuickDisconnectDetection()
    }
}

/// 只送一次 EOF:stdin 腳本由通道自己送完 EOF,呼叫端(例如 `HostFolders`)之後再送一次時不再往下傳。
/// 實測對同一個 SSH channel 第二次送 EOF 會讓輸出在結束狀態之前就斷掉。
actor WindowsExecSession: ExecSession {
    private let base: any ExecSession
    private var stdinClosed = false
    nonisolated let output: AsyncThrowingStream<ExecOutput, any Error>

    init(_ base: any ExecSession) {
        self.base = base
        output = base.output
    }

    func write(_ data: Data) async throws { try await base.write(data) }

    func closeStdin() async {
        guard !stdinClosed else { return }
        stdinClosed = true
        await base.closeStdin()
    }

    func close() async { await base.close() }
}

/// 換成 PowerShell 後要執行的東西。
struct WindowsInvocation: Equatable {
    var command: String
    /// 經 stdin 送給 stub 的腳本(UTF-8);`nil` = 腳本已在命令列裡。
    var stdinScript: Data?
    /// 送完腳本不送 EOF:長駐腳本接著從同一個 stdin 讀請求行。
    var keepsStdinOpen = false
}

/// 把 app 的 POSIX 指令換成 PowerShell(行為規格 §11.2)。
enum WindowsCommand {
    /// cmd 的命令列上限(OpenSSH 預設 shell 是 cmd 時)。
    static let commandLimit = 8_191

    /// 登入 Shell 的指令(#732):互動的 `powershell.exe -NoLogo -NoExit`,啟動時先把主控台輸入輸出設成 UTF-8
    /// (Windows PowerShell 5.1 預設 OEM code page,繁中是 CP950,中文會亂碼)。
    /// 設定經 `-EncodedCommand`(純 base64),內文沒有引號與 `$`。
    /// 整串外包一組雙引號:PTY 模式下 sshd 把指令原樣接在 DefaultShell 的 `-c` 後面,Git Bash 不加引號只拿得到第一個字。
    /// 不加 `-NoProfile`:使用者的 profile 照常載入。
    static let loginShell: String = {
        let script = "$u=New-Object Text.UTF8Encoding $false;[Console]::InputEncoding=$u;[Console]::OutputEncoding=$u;$OutputEncoding=$u"
        let encoded = PowerShell.encodedCommand(script)
        return "\"powershell.exe -NoLogo -NoExit -EncodedCommand " + String(encoded.split(separator: " ").last!) + "\""
    }()

    static func translate(_ command: String) throws -> WindowsInvocation {
        // 喚醒探測只看通道活不活，exit code 不重要:不必付 PowerShell 的啟動成本(0.6–2.5 s,§7.5 的期限是 3 秒)。
        if command == WakeProbe.command { return WindowsInvocation(command: command) }
        if let script = herdr(command) { return try inline(script) }
        if let script = follow(command) ?? hostFileFollow(command) ?? hostFileFetch(command) {
            var invocation = viaStdin(script)
            invocation.keepsStdinOpen = true
            return invocation
        }
        if command == CodexPlanUsageHost.command { return try inline(codexAppServer) }
        if let script = transcript(command) { return viaStdin(script) }
        if let script = hostFiles(command) ?? gitChanges(command) ?? sessionHistory(command) { return viaStdin(script) }
        if let upload = HostUploadCommand.parse(command) {
            return try inline(WindowsScripts.upload(WindowsScripts.hostUpload, arguments: [upload.name.value, String(upload.size)]))
        }
        if let upload = HostFolderCommand.parseUpload(command) {
            return try inline(WindowsScripts.upload(WindowsScripts.folderUpload, arguments: [
                upload.folder, upload.name, String(upload.originalSize), upload.encoding.rawValue, String(upload.transferSize),
            ]))
        }
        if let path = HostFolderCommand.parseList(command) {
            return viaStdin(WindowsScripts.folders(WindowsScripts.folderList, arguments: [path ?? ""]))
        }
        if let script = AuthorizedKeyInstaller.administratorScript(for: command) { return try inline(script) }
        if let path = NewChatFolders.requestedPath(in: command) {
            return viaStdin(WindowsScripts.folders(WindowsScripts.newChatFolders, arguments: [path]))
        }
        throw WindowsCommandError.unsupported(command)
    }

    /// stdin stub 傳輸被截斷時的結束碼(上傳腳本用 64–75 其餘各碼)。
    static let stdinTruncatedExit = 74

    /// 命令列只放這個 stub:從 stdin 一行一行讀到結束標記，當成腳本執行。
    ///
    /// 不等 EOF:實測 OpenSSH 預設 shell 是 Git Bash 時，stdin 超過 4 KiB 後的 EOF 常常傳不到 PowerShell
    /// (資料都到了，只有 EOF 不見，程序就永遠等下去)。stdin 的開法同上傳(`WindowsScripts.openStdin`)。
    /// 自我時限(#92):`stdinScriptSeconds` 內沒讀到結束標記就以 124 結束;讀到後腳本本體另有 `readSeconds`。
    /// 沒讀到結束標記就 EOF(傳輸被截斷,#735)以 `stdinTruncatedExit` 結束,不執行已讀到的半份腳本。
    static let stdinStub = PowerShell.encodedCommand(
        "$ProgressPreference='SilentlyContinue';\(WindowsScripts.limit(seconds: HostScriptTimeLimit.stdinScriptSeconds));\(WindowsScripts.openStdin);$s=New-Object IO.StreamReader($stdin,(New-Object Text.UTF8Encoding $false));$b=New-Object Text.StringBuilder;$done=$false;while(($l=$s.ReadLine()) -ne $null){if($l -eq '\(endOfScript)'){$done=$true;break};[void]$b.AppendLine($l)};if(-not $done){exit \(stdinTruncatedExit)};$purrdrLimit.At=[DateTime]::UtcNow.AddSeconds(\(HostScriptTimeLimit.readSeconds));iex $b.ToString()")
    static let endOfScript = "#purrdr-end-of-script"

    static func viaStdin(_ script: String) -> WindowsInvocation {
        WindowsInvocation(command: stdinStub, stdinScript: Data((script + "\n" + endOfScript + "\n").utf8))
    }

    // MARK: - 對話紀錄

    /// `TranscriptCommand.follow` → PowerShell 版長駐追蹤腳本(#167)。參數：上限、追趕上限、閒置與總長秒數。
    static func follow(_ command: String) -> String? {
        let prefix = TranscriptCommand.followInvocation
        guard command.hasPrefix(prefix + " "), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count == 4 else { return nil }
        return WindowsScripts.transcript(WindowsScripts.follow, arguments: arguments)
    }

    /// `TranscriptCommand` 的腳本 → 同樣輸出格式的 PowerShell 腳本。
    static func transcript(_ command: String) -> String? {
        for (posix, windows) in transcriptScripts {
            let prefix = TranscriptCommand.command(posix, arguments: [])
            guard command == prefix || command.hasPrefix(prefix + " "),
                  let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))) else { continue }
            return WindowsScripts.transcript(windows, arguments: arguments)
        }
        return nil
    }

    static let transcriptScripts: [(posix: String, windows: String)] = {
        var scripts: [(String, String)] = [
            (TranscriptCommand.windowScript, WindowsScripts.window),
            (TranscriptCommand.tailScript, WindowsScripts.tail),
            (TranscriptCommand.catchUpScript, WindowsScripts.catchUp),
            (TranscriptCommand.previewsScript, WindowsScripts.previews),
            (TranscriptCommand.findSubagentScript, WindowsScripts.findSubagent),
            (TranscriptCommand.readWorkflowScript, WindowsScripts.readWorkflow),
            (TranscriptCommand.delegationLinesScript, WindowsScripts.delegationLines),
            (ClaudeSlashCommand.discoverScript, WindowsScripts.slashDiscover),
            (ClaudeSlashCommand.manifestsScript, WindowsScripts.slashManifests),
            (ClaudeSlashCommand.scanScript, WindowsScripts.slashScan),
        ]
        for locator in TranscriptLocator.all {
            let windows = locator.usesProjectFolder
                ? WindowsScripts.claudeLocate : WindowsScripts.locate(type: locator.lookupName, header: locator.readsHeader)
            scripts.append((TranscriptCommand.locateScript(locator), windows))
            scripts.append((TranscriptCommand.openScript(locator), WindowsScripts.open(locator)))
        }
        return scripts
    }()

    // MARK: - 主機檔案

    /// `HostFileScript.command` 的 `/bin/sh -c '<腳本>' purrdr <參數…>` → 同樣輸出格式的 PowerShell 腳本。
    /// 寫入的內容(base64)可能上百 KiB,一律經 stdin(cmd 的命令列上限 8,191)。
    static func hostFiles(_ command: String) -> String? {
        for (posix, windows) in hostFileScripts {
            let prefix = HostFileScript.command(posix, arguments: [])
            guard command == prefix || command.hasPrefix(prefix + " "),
                  let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))) else { continue }
            return WindowsScripts.hostFiles(windows, arguments: arguments)
        }
        return nil
    }

    /// 變更頁的唯讀指令(`GitChangesCommand`,#310)→ PowerShell 版。
    static func gitChanges(_ command: String) -> String? {
        guard let request = GitChangesCommand.arguments(in: command) else { return nil }
        return WindowsScripts.hostFiles(WindowsScripts.gitChanges, arguments: request)
    }

    /// 過去的 session 清單(`SessionHistoryCommand`,#535)→ PowerShell 版。
    static func sessionHistory(_ command: String) -> String? {
        guard let arguments = SessionHistoryCommand.arguments(in: command) else { return nil }
        return WindowsScripts.transcript(WindowsScripts.sessionHistory, arguments: arguments)
    }

    /// `HostFileScript.follow` → PowerShell 版長駐讀取(#203)。參數：閒置與總長秒數。
    static func hostFileFollow(_ command: String) -> String? {
        let prefix = HostFileScript.followInvocation
        guard command.hasPrefix(prefix + " "), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count == 2 else { return nil }
        return WindowsScripts.hostFiles(WindowsScripts.hostFileFollow, arguments: arguments)
    }

    /// `HostFileFetchScript.follow` → PowerShell 版主機取檔(#226)。參數：閒置、總長秒數、大小上限。
    static func hostFileFetch(_ command: String) -> String? {
        let prefix = HostFileFetchScript.followInvocation
        guard command.hasPrefix(prefix + " "), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count == 3 else { return nil }
        return WindowsScripts.hostFileFetch(arguments: arguments)
    }

    static let hostFileScripts: [(posix: String, windows: String)] = [
        (HostFileScript.read, WindowsScripts.hostFileRead),
        (HostFileScript.readIfChanged, WindowsScripts.hostFileReadIfChanged),
        (HostFileScript.apply, WindowsScripts.hostFileApply),
        (HostFileScript.newest, WindowsScripts.hostFileNewest),
        (SSHPushPluginInstaller.otherPairingsScript, WindowsScripts.pushPairings),
        (SSHPushTestNotifier.script, WindowsScripts.pushTest),
    ]

    static func inline(_ script: String) throws -> WindowsInvocation {
        let command = PowerShell.encodedCommand(script)
        guard command.count <= commandLimit else { throw WindowsCommandError.commandTooLong }
        return WindowsInvocation(command: command)
    }

    // MARK: - Codex

    /// `codex app-server`:PATH 上找 `codex.exe`／`codex.cmd`(找不到 exit 127),stdin／stdout 直接接到通道(同 herdr bridge)。
    static let codexAppServer = """
        $ProgressPreference='SilentlyContinue'
        $codexCommand=Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $codexCommand){[Console]::Error.Write("codex: command not found`n");exit 127}
        & $codexCommand.Source 'app-server'
        exit $LASTEXITCODE
        """

    // MARK: - herdr

    /// `HerdrCommand` 的 `PATH=… '<herdr>' <參數…>` → `& $h <參數…>; exit $LASTEXITCODE`。
    ///
    /// - herdr 由安裝程式放在 PATH 上;找不到預設的 `herdr` 時試相容別名
    ///   `%LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe`(herdr 文件 `windows-beta.mdx`)。都沒有 → exit 127。
    /// - `~/` 開頭的路徑接在 `%USERPROFILE%` 後面。
    /// - Windows 不支援 live handoff:`update --handoff` 換成 `update`,伺服器要使用者在主機上重啟才換版。
    /// - 包裝本身不往 stdout 印任何東西(PowerShell 自己印的是 `\r\n`);herdr 的 stdin／stdout 直接接到通道。
    static func herdr(_ command: String) -> String? {
        let prefix = HerdrCommand.pathPrefix + " "
        guard command.hasPrefix(prefix), let words = PosixWords.split(command.dropFirst(prefix.count)),
              let program = words.first, program.quoted else { return nil }
        var arguments = words.dropFirst().map(\.text)
        if arguments == ["update", "--handoff"] { arguments = ["update"] }
        let isDefault = !program.homeRelative && program.text == "herdr"
        let path = program.homeRelative
            ? "$h=Join-Path $env:USERPROFILE \(PowerShell.quote(program.text))"
            : "$h=\(PowerShell.quote(program.text))"
        let missing = #"[Console]::Error.Write("herdr: command not found`n");exit 127"#
        let lookup = isDefault
            ? #"if(-not(Get-Command $h -CommandType Application -ErrorAction SilentlyContinue)){$h=Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe';if(-not(Test-Path -LiteralPath $h)){"# + missing + "}}"
            : #"if(-not(Get-Command $h -CommandType Application -ErrorAction SilentlyContinue)){"# + missing + "}"
        return """
            $ProgressPreference='SilentlyContinue'
            \(path)
            \(lookup)
            & $h \(arguments.map(PowerShell.quote).joined(separator: " "))
            exit $LASTEXITCODE
            """
    }
}

/// `HerdrCommand` 產生的 POSIX 字詞：單引號字串(`'"'"'` 是一個單引號)、`"$HOME"/'…'`、不需引號的字。
struct PosixWords {
    struct Word: Equatable {
        var text: String
        /// 有引號(herdr 路徑一定有;`uname` 這種裸字沒有)。
        var quoted: Bool
        /// `"$HOME"/'…'`:相對家目錄。
        var homeRelative: Bool
    }

    static func split(_ text: Substring) -> [Word]? {
        var words: [Word] = []
        var current: Word?
        var rest = text
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case " ":
                if let word = current { words.append(word) }
                current = nil
            case "'", "\"":
                let content: String
                if character == "'" {
                    guard let end = rest.firstIndex(of: character) else { return nil }
                    content = String(rest[..<end])
                    rest = rest[rest.index(after: end)...]
                } else {
                    // 已知的 `"$HOME"/` 前綴;其餘雙引號是 `PosixShell.quote` 為含反斜線的字串產生的(`\\`、`\"`、`\$` 跳脫)。
                    if rest.hasPrefix("$HOME\"/"), current == nil {
                        rest = rest.dropFirst("$HOME\"/".count)
                        current = Word(text: "", quoted: true, homeRelative: true)
                        continue
                    }
                    guard let (decoded, remainder) = PosixShell.doubleQuotedContent(rest) else { return nil }
                    content = decoded
                    rest = remainder
                }
                var word = current ?? Word(text: "", quoted: true, homeRelative: false)
                word.text += content
                word.quoted = true
                current = word
            default:
                guard character.isLetter || character.isNumber || "-_.:=/,".contains(character) else { return nil }
                var word = current ?? Word(text: "", quoted: false, homeRelative: false)
                word.text.append(character)
                current = word
            }
        }
        if let word = current { words.append(word) }
        return words
    }
}
