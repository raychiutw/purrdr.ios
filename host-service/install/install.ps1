# Purrdr 主機服務的一行安裝(Windows,#198):
#
#   irm https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.ps1 | iex
#   & ([scriptblock]::Create((irm …/install.ps1))) --yes --port 47820   # 參數原樣交給 `purrdr-host-service install`
#   & ([scriptblock]::Create((irm …/install.ps1))) --https-port 8443     # HTTPS 443 已被其他 `tailscale serve` 服務使用時
#
# 下載 Release 壓縮檔，以 SHA256SUMS 驗證(不符就中止、不留檔),解壓到暫存資料夾後執行
# `purrdr-host-service.exe install`(複製到 %USERPROFILE%\.purrdr\host-service\bin\ 並設定登入後自動啟動)。
# 已安裝時就是更新，已配對的裝置會保留。不需要系統管理員。
#
# 環境變數:
#   PURRDR_HOST_SERVICE_VERSION       指定版本(例:0.1.0);預設最新版
#   PURRDR_HOST_SERVICE_DOWNLOAD_URL  下載來源(網址或本機資料夾;測試用)
#
# 以 `irm | iex` 執行時這份腳本跑在使用者的 session 裡：不用 exit(會關掉視窗),失敗以 throw 結束，函式與變數都包在 scriptblock 內。
# 失敗訊息一律是「發生什麼」加一行「Next: 下一步」。

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $installArguments = @($args)

    $repository = 'https://github.com/raychiutw/purrdr.ios'
    # 重跑這個安裝的指令(主機服務的錯誤訊息用它組出「下一步」)。
    $rerun = "& ([scriptblock]::Create((irm $repository/releases/latest/download/install.ps1)))"
    if ($env:PURRDR_HOST_SERVICE_VERSION) {
        # 單引號字串裡的 ' 寫成 ''。
        $rerun = "`$env:PURRDR_HOST_SERVICE_VERSION = '$($env:PURRDR_HOST_SERVICE_VERSION.Replace("'", "''"))'; $rerun"
    }
    function Stop-Install([string] $what, [string] $next) {
        throw "purrdr-host-service install: $what`nNext: $next"
    }
    # 目前只發 x86_64;ARM64 的 Windows 以模擬執行。
    $asset = 'purrdr-host-service-x86_64-pc-windows-msvc.zip'

    if ($env:PURRDR_HOST_SERVICE_DOWNLOAD_URL) {
        $source = $env:PURRDR_HOST_SERVICE_DOWNLOAD_URL
    } elseif ($env:PURRDR_HOST_SERVICE_VERSION) {
        $source = "$repository/releases/download/host-service-v$($env:PURRDR_HOST_SERVICE_VERSION)"
    } else {
        $source = "$repository/releases/latest/download"
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('purrdr-host-service.' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        if ($source -match '^https?://') {
            # Windows PowerShell 5.1 預設可能沒開 TLS 1.2(GitHub 需要)。
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        foreach ($name in @('SHA256SUMS', $asset)) {
            $target = Join-Path $work $name
            try {
                if ($source -match '^https?://') {
                    Invoke-WebRequest -UseBasicParsing -Uri "$source/$name" -OutFile $target
                } else {
                    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target
                }
            } catch {
                Stop-Install "download failed: $source/$name ($($_.Exception.Message)); nothing was installed." `
                    "check your network and that the version exists at $repository/releases, then run again: $rerun"
            }
        }

        $expected = $null
        foreach ($line in Get-Content -LiteralPath (Join-Path $work 'SHA256SUMS')) {
            $fields = $line -split '\s+', 2
            if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -eq $asset) { $expected = $fields[0].ToLowerInvariant(); break }
        }
        if (-not $expected) {
            Stop-Install "no checksum for $asset in SHA256SUMS, so the download cannot be verified; nothing was installed." `
                "run again later: $rerun (if it keeps failing, open an issue at $repository/issues)"
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $asset)).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Stop-Install "checksum mismatch for $asset (expected $expected, got $actual): the download is incomplete or was altered, so nothing was installed." `
                "run again: $rerun (if it keeps failing, open an issue at $repository/issues)"
        }

        $extracted = Join-Path $work 'extracted'
        Expand-Archive -LiteralPath (Join-Path $work $asset) -DestinationPath $extracted
        $executable = Join-Path $extracted 'purrdr-host-service.exe'
        if (-not (Test-Path -LiteralPath $executable)) {
            Stop-Install "$asset does not contain purrdr-host-service.exe; nothing was installed." "open an issue at $repository/issues"
        }

        $env:PURRDR_HOST_SERVICE_INSTALL_COMMAND = $rerun
        try {
            & $executable install @installArguments
        } finally {
            Remove-Item Env:PURRDR_HOST_SERVICE_INSTALL_COMMAND -ErrorAction SilentlyContinue
        }
        if ($LASTEXITCODE -ne 0) {
            # 主機服務已印出原因與下一步，這裡只指回去，不蓋掉它。
            throw "purrdr-host-service install: install did not finish (exit code $LASTEXITCODE); see the reason and next step above."
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
} @args
