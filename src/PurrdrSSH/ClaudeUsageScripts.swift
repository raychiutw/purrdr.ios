// 由 scripts/sync-purrdr-host.sh 產生，不要手動修改。來源 https://github.com/raychiutw/purrdr.host/tree/a6ccc31ca456b184c272fda08935105c1ac9b549/claude-usage
// 腳本單一來源在 purrdr.host(SSH 與 HTTPS 共用);app 安裝時原樣寫到主機，也以它判斷主機上的包裝是不是舊版。
enum ClaudeUsageScripts {
    static let posix = #"""
#!/bin/sh
# Purrdr 的 Claude 方案用量包裝：由 Purrdr app(或主機服務)安裝，在 app 關閉「Claude 方案用量」就會還原。
# 把 Claude Code 交給 status line 的輸入存起來，再原樣交給原本的 status line:
# - sessions/<session_id>.json:每次都寫(每個 session 一份，不論有沒有 rate_limits;raychiutw/purrdr.host#64)
# - usage.json:輸入含 rate_limits 時才寫(整台主機一份)
# 存檔失敗一律略過，不影響 status line 的輸出;超過 7 天沒更新的 session 檔會清掉。
dir="$HOME/.purrdr/claude-usage"
input=$(cat)
now=$(date +%s)

# 以暫存檔寫好再換上(讀的一方不會讀到寫一半的檔)。$1 資料夾，$2 檔名，$3 內容。
save() {
  tmp=$(mktemp "$1/.tmp.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$3" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1/$2" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

session=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]{1,128})".*/\1/p' | head -n 1)
case $session in
  '' | . | ..) ;;
  *)
    if mkdir -p "$dir/sessions" 2>/dev/null; then
      save "$dir/sessions" "$session.json" "{\"captured_at\":$now,\"session_id\":\"$session\",\"status_line_input\":$input}"
      find "$dir/sessions" -type f -name '*.json' -mmin +10080 -exec rm -f {} + 2>/dev/null
    fi
    ;;
esac
case $input in
  *'"rate_limits"'*) save "$dir" usage.json "{\"captured_at\":$now,\"status_line_input\":$input}" ;;
esac

# 原本的 status line 的輸出與結束碼直接交給 Claude Code;沒有原本的就不輸出。
if [ -s "$dir/original-command" ]; then
  printf '%s\n' "$input" | sh -c "$(cat "$dir/original-command")"
fi

"""#

    static let windows = #"""
# Purrdr Claude usage wrapper (Windows). Installed by the Purrdr app (or the Purrdr host service);
# turning off "Claude Usage" in Purrdr restores your original status line and removes this folder.
# Saves Claude Code's status line input, then passes the same input to your original status line:
# - sessions\<session_id>.json: every time, one file per session (raychiutw/purrdr.host#64)
# - usage.json: only when the input has rate_limits
# Saving never breaks the status line; session files not updated for 7 days are removed.
# ASCII only: PowerShell 5.1 reads a .ps1 without BOM in the system code page.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding $false
$text = (New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)).ReadToEnd().TrimEnd("`r", "`n")
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Write a temporary file, then swap it in (readers never see a half-written file).
function Save-File([string]$folder, [string]$name, [string]$content) {
    $tmp = Join-Path $folder ('.tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, $content + "`n", $utf8)
        $file = Join-Path $folder $name
        if ([IO.File]::Exists($file)) { [void][IO.File]::Replace($tmp, $file, [NullString]::Value) } else { [IO.File]::Move($tmp, $file) }
    } catch {
        try { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch {}
    }
}

try {
    $match = [Regex]::Match($text, '"session_id"\s*:\s*"([A-Za-z0-9._-]{1,128})"')
    if ($match.Success -and $match.Groups[1].Value -ne '.' -and $match.Groups[1].Value -ne '..') {
        $session = $match.Groups[1].Value
        $sessions = Join-Path $dir 'sessions'
        [void][IO.Directory]::CreateDirectory($sessions)
        Save-File $sessions ($session + '.json') ('{"captured_at":' + $now + ',"session_id":"' + $session + '","status_line_input":' + $text + '}')
        $cutoff = [DateTime]::UtcNow.AddDays(-7)
        Get-ChildItem -LiteralPath $sessions -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
            ForEach-Object { try { $_.Delete() } catch {} }
    }
} catch {}
if ($text.Contains('"rate_limits"')) {
    Save-File $dir 'usage.json' ('{"captured_at":' + $now + ',"status_line_input":' + $text + '}')
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
    # Windows PowerShell (.NET Framework) writes the child's stdin with Console.InputEncoding; its default UTF-8
    # writes a BOM first, so the original status line would get a BOM before the JSON.
    [Console]::InputEncoding = $utf8
    $process = [Diagnostics.Process]::Start($start)
    $bytes = $utf8.GetBytes($text + "`n")
    $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $process.StandardInput.Close()
    $process.WaitForExit()
    exit $process.ExitCode
}

"""#
}
