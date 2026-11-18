# Purrdr 主機服務的一行安裝(Windows,#198):
#
#   irm https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.ps1 | iex
#   & ([scriptblock]::Create((irm …/install.ps1))) --yes --port 47820   # 參數原樣交給 `purrdr-host-service install`
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

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $installArguments = @($args)

    $repository = 'https://github.com/raychiutw/purrdr.ios'
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
                throw "purrdr-host-service install: download failed: $source/$name"
            }
        }

        $expected = $null
        foreach ($line in Get-Content -LiteralPath (Join-Path $work 'SHA256SUMS')) {
            $fields = $line -split '\s+', 2
            if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -eq $asset) { $expected = $fields[0].ToLowerInvariant(); break }
        }
        if (-not $expected) { throw "purrdr-host-service install: no checksum for $asset in SHA256SUMS" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $asset)).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "purrdr-host-service install: checksum mismatch for $asset (expected $expected, got $actual)"
        }

        $extracted = Join-Path $work 'extracted'
        Expand-Archive -LiteralPath (Join-Path $work $asset) -DestinationPath $extracted
        $executable = Join-Path $extracted 'purrdr-host-service.exe'
        if (-not (Test-Path -LiteralPath $executable)) { throw "purrdr-host-service install: $asset does not contain purrdr-host-service.exe" }

        & $executable install @installArguments
        if ($LASTEXITCODE -ne 0) { throw "purrdr-host-service install: install exited with $LASTEXITCODE" }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
} @args
