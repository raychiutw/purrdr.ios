import Foundation
import PurrdrCore

/// Claude 方案用量的主機端(行為規格 F18,ADR-0002 的寫入例外)。
///
/// Claude Code 只把 `rate_limits` 交給 status line 指令，所以經使用者同意後，把 `~/.claude/settings.json`
/// 的 `statusLine.command` 換成 `~/.purrdr/claude-usage/statusline.sh`:它把輸入存成 `usage.json`,
/// 再把同一份輸入交給使用者原本的 status line(原本的指令存在 `original-command`)。
/// 關閉時經 `ReversibleHostWrite` 還原，主機與安裝前完全相同。
///
/// Windows 主機(#68):Claude Code 在 Windows 上有 Git Bash 時經 Git Bash、沒有時經 PowerShell 執行 status line
/// (Claude Code 文件 statusline「Windows configuration」),所以包裝改成 PowerShell 腳本 `statusline.ps1`,指令寫成
/// 兩種 shell 都能跑的 `powershell.exe … -File '<家目錄>/.purrdr/claude-usage/statusline.ps1'`(正斜線、單引號;
/// `-ExecutionPolicy Bypass` 只對這個程序有效，不改主機設定)。原本的指令以 Git Bash 執行(找不到時用 PowerShell)。
public struct ClaudePlanUsageHost: Sendable {
    public static let settingsPath: HostPath = ".claude/settings.json"
    public static let feature = HostWriteFeature(id: "claude-usage", userFiles: [settingsPath])
    public static let usagePath = feature.ownFile("usage.json")
    /// 寫進 `statusLine.command` 的指令(Claude Code 以 shell 執行，`~` 會展開)。
    public static let wrapperCommand = "~/.purrdr/claude-usage/statusline.sh"

    /// Windows 主機的包裝腳本(相對於家目錄)。
    static let windowsWrapperPath = feature.ownFile("statusline.ps1")

    /// 這台主機要寫的包裝指令:Windows 主機用 PowerShell 版(`home` 是 `HostFileRead.home`,分隔符號是 `/`)。
    public static func wrapperCommand(for operatingSystem: HostOperatingSystem?, home: String?) -> String {
        guard operatingSystem == .windows, let home else { return wrapperCommand }
        return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '\(home)/\(windowsWrapperPath.relative)'"
    }

    /// 是 Purrdr 的包裝(任一種主機的)。
    static func isWrapper(_ command: String?) -> Bool {
        guard let command else { return false }
        return command == wrapperCommand
            || (command.hasPrefix("powershell.exe ") && command.hasSuffix("/\(windowsWrapperPath.relative)'"))
    }

    let write: ReversibleHostWrite
    let files: HostFiles
    /// 上次讀到的用量與版本(條件式讀取，#203)。
    private let lastRead = LastUsageRead()

    /// - Parameter files: 讀用量用的主機檔案(每台主機共用長駐讀取的那份);`nil` 時每次讀是一次性指令。
    public init(channel: any HostChannel, files: HostFiles? = nil) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
        self.files = files ?? HostFiles(channel: channel)
    }

    /// 同意前的檢查：設定可以安全修改嗎、會以哪個使用者修改。
    public func inspect() async throws -> ClaudeUsageInspection {
        let inspection = try await write.inspect()
        _ = try Self.currentSettings(in: inspection)
        return ClaudeUsageInspection(user: inspection.read.user, isInstalled: inspection.isInstalled)
    }

    /// 安裝包裝腳本。只在讀取後 `settings.json` 沒被改過時寫入(否則丟 `HostFilesError.changedSinceRead`)。
    public func install() async throws {
        try await write.install { inspection in
            let current = try Self.currentSettings(in: inspection)
            let read = inspection.read
            let command = Self.wrapperCommand(for: read.operatingSystem, home: read.home)
            var ownFiles: [String: HostWritePlan.OwnFile] = read.operatingSystem == .windows
                ? ["statusline.ps1": .init(Data(Self.windowsWrapperScript.utf8))]
                : ["statusline.sh": .init(Data(Self.wrapperScript.utf8), executable: true)]
            // 包裝腳本永遠不會被存成「原本的」:否則執行時會一直呼叫自己。
            if let original = Self.statusLineCommand(in: inspection.original(of: Self.settingsPath)), !Self.isWrapper(original) {
                ownFiles["original-command"] = .init(Data(original.utf8))
            }
            let settings = try Self.settings(current) { statusLine in
                var statusLine = statusLine ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = command
                return statusLine
            }
            return HostWritePlan(userFiles: [Self.settingsPath: settings], ownFiles: ownFiles)
        }
    }

    /// 還原原本的設定，移除 `~/.purrdr/claude-usage/`。
    public func restore() async throws {
        try await write.restore { _, current, original in
            guard let object = Self.jsonObject(current) else { throw ClaudeUsageError.settingsNotJSON }
            // 使用者已經自己換掉 status line:不動它。
            guard Self.isWrapper(Self.statusLineCommand(in: current)) else { return current }
            let originalStatusLine = original.flatMap(Self.jsonObject)?["statusLine"] as? [String: Any]
            return try Self.settings(object) { _ in originalStatusLine }
        }
    }

    /// 讀包裝腳本最後存下的用量;還沒有(沒安裝、Claude Code 還沒回報)時是 `nil`。
    /// 帶上次的版本條件式讀取，沒變時用上次的結果。
    public func readPlanUsage() async throws -> ClaudeUsage? {
        let previous = await lastRead.value
        let read = try await files.read([Self.usagePath])
        if let previous, read.unchanged.contains(Self.usagePath) { return previous.usage }
        let state = read[Self.usagePath]
        let usage = state?.contents.flatMap(ClaudeUsage.init(usageFile:))
        if case .file(_, let version)? = state {
            await lastRead.update((version, usage))
        } else {
            await lastRead.update(nil)
        }
        return usage
    }

    // MARK: - 設定檔

    /// 目前的設定：不存在是空物件;所在資料夾不存在 → 沒裝 Claude Code;不是 JSON 物件 → 拒絕。
    static func currentSettings(in inspection: HostWriteInspection) throws -> [String: Any] {
        switch inspection.read[settingsPath] ?? .missing {
        case .missing:
            return [:]
        case .missingDirectory:
            throw ClaudeUsageError.claudeNotFound
        case .file(let data, _):
            guard let object = jsonObject(data) else { throw ClaudeUsageError.settingsNotJSON }
            return object
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(settingsPath)
        }
    }

    /// 只接受 Claude Code 也讀得了的嚴格 JSON 物件。
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard StrictJSON.isValid(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func statusLineCommand(in settings: Data?) -> String? {
        (settings.flatMap(jsonObject)?["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// 改寫 `statusLine` 後輸出;回傳 `nil` 表示移除 `statusLine`。其他內容保留(鍵依字母排序)。
    /// 還原時若使用者沒再改過，會換回安裝前的原始 bytes,所以排序只在安裝期間看得到。
    static func settings(_ object: [String: Any], statusLine: ([String: Any]?) -> [String: Any]?) throws -> Data {
        var object = object
        object["statusLine"] = statusLine(object["statusLine"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    /// 包裝腳本。輸入有 `rate_limits` 才存(session 剛開始時沒有，不蓋掉上次的用量)。
    static let wrapperScript = """
        #!/bin/sh
        # Purrdr 的 Claude 方案用量包裝：由 Purrdr app 安裝，在 app 關閉「Claude 方案用量」就會還原。
        # 把 Claude Code 交給 status line 的輸入存成 usage.json,再原樣交給原本的 status line。
        dir="$HOME/.purrdr/claude-usage"
        input=$(cat)
        case $input in
          *'"rate_limits"'*)
            if tmp=$(mktemp "$dir/.usage.XXXXXX"); then
              if printf '{"captured_at":%s,"status_line_input":%s}\\n' "$(date +%s)" "$input" > "$tmp"; then
                mv -f "$tmp" "$dir/usage.json" || rm -f "$tmp"
              else
                rm -f "$tmp"
              fi
            fi
            ;;
        esac
        if [ -s "$dir/original-command" ]; then
          printf '%s\\n' "$input" | sh -c "$(cat "$dir/original-command")"
        fi

        """
}

extension ClaudePlanUsageHost {
    /// Windows 的包裝腳本(PowerShell 5.1)。與 `wrapperScript` 相同的行為：輸入有 `rate_limits` 才存 `usage.json`
    /// (暫存檔再換上),再把同一份輸入交給原本的 status line,它的輸出直接接到 Claude Code(子程序繼承 stdout)。
    ///
    /// 全部 ASCII:PowerShell 5.1 把沒有 BOM 的 `.ps1` 當成系統碼頁(繁中是 Big5)讀。
    /// 原本的指令經環境變數交給 Git Bash 的 `eval`(`CLAUDE_CODE_GIT_BASH_PATH` → `git.exe` 旁的 `bin\bash.exe` →
    /// `%ProgramFiles%\Git\bin\bash.exe`),都沒有時以 PowerShell 的 `Invoke-Expression` 執行，與 Claude Code 的選擇一致。
    static let windowsWrapperScript = #"""
        # Purrdr Claude usage wrapper (Windows). Installed by the Purrdr app; turning off
        # "Claude Usage" in Purrdr restores your original status line and removes this folder.
        # Saves Claude Code's status line input as usage.json, then passes the same input
        # to your original status line command.
        $ErrorActionPreference = 'Stop'
        $dir = $PSScriptRoot
        $utf8 = New-Object Text.UTF8Encoding $false
        $text = (New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)).ReadToEnd().TrimEnd("`r", "`n")
        if ($text.Contains('"rate_limits"')) {
            $tmp = Join-Path $dir ('.usage.' + [Guid]::NewGuid().ToString('N'))
            try {
                [IO.File]::WriteAllText($tmp, '{"captured_at":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ',"status_line_input":' + $text + "}`n", $utf8)
                $file = Join-Path $dir 'usage.json'
                if ([IO.File]::Exists($file)) { [void][IO.File]::Replace($tmp, $file, [NullString]::Value) } else { [IO.File]::Move($tmp, $file) }
            } catch {
                if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
            }
        }
        $original = Join-Path $dir 'original-command'
        if ([IO.File]::Exists($original) -and (New-Object IO.FileInfo $original).Length -gt 0) {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.UseShellExecute = $false
            $start.RedirectStandardInput = $true
            $start.EnvironmentVariables['PURRDR_ORIGINAL_COMMAND'] = [IO.File]::ReadAllText($original, $utf8)
            $bash = $env:CLAUDE_CODE_GIT_BASH_PATH
            if (-not $bash -or -not [IO.File]::Exists($bash)) {
                $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($git) { $bash = Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe' }
            }
            if (-not $bash -or -not [IO.File]::Exists($bash)) { $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
            if ([IO.File]::Exists($bash)) {
                $start.FileName = $bash
                $start.Arguments = '-c "eval \"$PURRDR_ORIGINAL_COMMAND\""'
            } else {
                $start.FileName = 'powershell.exe'
                $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Invoke-Expression $env:PURRDR_ORIGINAL_COMMAND"'
            }
            $process = [Diagnostics.Process]::Start($start)
            $bytes = $utf8.GetBytes($text + "`n")
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.Close()
            $process.WaitForExit()
            exit $process.ExitCode
        }

        """#
}

extension ClaudeUsage {
    /// 解析包裝腳本存的 `usage.json`:`{"captured_at":<epoch 秒>,"status_line_input":<Claude Code 的輸入>}`。
    /// `rate_limits.<視窗>.resets_at` 是 Unix epoch 秒(Claude Code 文件)。
    public init?(usageFile data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let capturedAt = (object["captured_at"] as? NSNumber)?.doubleValue,
              let limits = (object["status_line_input"] as? [String: Any])?["rate_limits"] as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let window = limits[key] as? [String: Any], let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Window(usedPercentage: used, resetsAt: (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        self.init(fiveHour: window("five_hour"), week: window("seven_day"), capturedAt: Date(timeIntervalSince1970: capturedAt))
    }
}

/// `ClaudePlanUsageHost` 上次讀到的用量與 `usage.json` 的版本。
private actor LastUsageRead {
    private(set) var value: (version: HostFileVersion, usage: ClaudeUsage?)?

    func update(_ value: (version: HostFileVersion, usage: ClaudeUsage?)?) {
        self.value = value
    }
}
