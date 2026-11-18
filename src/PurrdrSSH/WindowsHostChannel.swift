import Foundation
import PurrdrCore

/// Windows 主機的主機通道(#26):包住真正的通道，把 app 送出的 POSIX 指令換成 PowerShell 方言。
///
/// 呼叫端(`HerdrClient`、`TranscriptReader`、`ImageUploader`…)照常送 POSIX 指令，不知道主機是 Windows;
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
            await session.closeStdin()
        }
        return session
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        guard let command = request.command else { return try await base.openPTY(request) }
        let invocation = try WindowsCommand.translate(command)
        guard invocation.stdinScript == nil else { throw WindowsCommandError.unsupported(command) }
        var translated = request
        translated.command = invocation.command
        return try await base.openPTY(translated)
    }

    public func disconnect() async {
        await base.disconnect()
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
}

/// 把 app 的 POSIX 指令換成 PowerShell(行為規格 §11.2)。
enum WindowsCommand {
    /// cmd 的命令列上限(OpenSSH 預設 shell 是 cmd 時)。
    static let commandLimit = 8_191

    static func translate(_ command: String) throws -> WindowsInvocation {
        // 喚醒探測只看通道活不活，exit code 不重要:不必付 PowerShell 的啟動成本(0.6–2.5 s,§7.5 的期限是 3 秒)。
        if command == WakeProbe.command { return WindowsInvocation(command: command) }
        if let script = herdr(command) { return try inline(script) }
        if command == CodexPlanUsageHost.command { return try inline(codexAppServer) }
        if let script = transcript(command) { return viaStdin(script) }
        if let script = hostFiles(command) { return viaStdin(script) }
        if let upload = ImageUploadCommand.parse(command) {
            return try inline(WindowsScripts.upload(WindowsScripts.imageUpload, arguments: [upload.name.value, String(upload.size)]))
        }
        if let upload = HostFolderCommand.parseUpload(command) {
            return try inline(WindowsScripts.upload(WindowsScripts.folderUpload, arguments: [
                upload.folder, upload.name, String(upload.originalSize), upload.encoding.rawValue, String(upload.transferSize),
            ]))
        }
        if let path = HostFolderCommand.parseList(command) {
            return viaStdin(WindowsScripts.folders(WindowsScripts.folderList, arguments: [path ?? ""]))
        }
        if let path = NewChatFolders.requestedPath(in: command) {
            return viaStdin(WindowsScripts.folders(WindowsScripts.newChatFolders, arguments: [path]))
        }
        throw WindowsCommandError.unsupported(command)
    }

    /// 命令列只放這個 stub:從 stdin 一行一行讀到結束標記，當成腳本執行。
    ///
    /// 不等 EOF:實測 OpenSSH 預設 shell 是 Git Bash 時，stdin 超過 4 KiB 後的 EOF 常常傳不到 PowerShell
    /// (資料都到了，只有 EOF 不見，程序就永遠等下去)。stdin 的開法同上傳(`WindowsScripts.openStdin`)。
    /// 自我時限(#92):`stdinScriptSeconds` 內沒讀到結束標記就以 124 結束;讀到後腳本本體另有 `readSeconds`。
    static let stdinStub = PowerShell.encodedCommand(
        "$ProgressPreference='SilentlyContinue';\(WindowsScripts.limit(seconds: HostScriptTimeLimit.stdinScriptSeconds));\(WindowsScripts.openStdin);$s=New-Object IO.StreamReader($stdin,(New-Object Text.UTF8Encoding $false));$b=New-Object Text.StringBuilder;while(($l=$s.ReadLine()) -ne $null -and $l -ne '\(endOfScript)'){[void]$b.AppendLine($l)};$purrdrLimit.At=[DateTime]::UtcNow.AddSeconds(\(HostScriptTimeLimit.readSeconds));iex $b.ToString()")
    static let endOfScript = "#purrdr-end-of-script"

    static func viaStdin(_ script: String) -> WindowsInvocation {
        WindowsInvocation(command: stdinStub, stdinScript: Data((script + "\n" + endOfScript + "\n").utf8))
    }

    // MARK: - 對話紀錄

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
            (TranscriptCommand.claudeLocateScript, WindowsScripts.claudeLocate),
            (TranscriptCommand.windowScript, WindowsScripts.window),
            (TranscriptCommand.tailScript, WindowsScripts.tail),
            (TranscriptCommand.previewsScript, WindowsScripts.previews),
            (TranscriptCommand.findSubagentScript, WindowsScripts.findSubagent),
            (TranscriptCommand.readWorkflowScript, WindowsScripts.readWorkflow),
            (TranscriptCommand.delegationLinesScript, WindowsScripts.delegationLines),
            (ClaudeSlashCommand.discoverScript, WindowsScripts.slashDiscover),
            (ClaudeSlashCommand.manifestsScript, WindowsScripts.slashManifests),
            (ClaudeSlashCommand.scanScript, WindowsScripts.slashScan),
        ]
        let locations: [(TranscriptTarget.Location, String)] = [
            (.claude(sessionID: "", cwd: ""), "claude"), (.grok(sessionID: ""), "grok"), (.antigravity(sessionID: ""), "agy"),
            (.piJournal(sessionID: ""), "pi"), (.codex(sessionID: ""), "codex"), (.reportedPath(""), "path"),
        ]
        for (location, type) in locations {
            for header in [false, true] {
                scripts.append((TranscriptCommand.locateScript(location, readsHeader: header), WindowsScripts.locate(type: type, header: header)))
            }
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

    static let hostFileScripts: [(posix: String, windows: String)] = [
        (HostFileScript.read, WindowsScripts.hostFileRead),
        (HostFileScript.apply, WindowsScripts.hostFileApply),
        (HostFileScript.newest, WindowsScripts.hostFileNewest),
        (PushHost.otherPairingsScript, WindowsScripts.pushPairings),
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
        $c=Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $c){[Console]::Error.Write("codex: command not found`n");exit 127}
        & $c.Source 'app-server'
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
                guard let end = rest.firstIndex(of: character) else { return nil }
                let content = String(rest[..<end])
                rest = rest[rest.index(after: end)...]
                if character == "\"", content == "$HOME", current == nil, rest.first == "/" {
                    rest = rest.dropFirst()
                    current = Word(text: "", quoted: true, homeRelative: true)
                    continue
                }
                guard character == "'" || !content.contains(where: { "$`\\".contains($0) }) else { return nil }
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
