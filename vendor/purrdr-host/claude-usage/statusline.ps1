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
