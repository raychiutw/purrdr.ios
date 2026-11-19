#!/bin/sh
# Purrdr 主機服務的一行安裝(macOS、Linux,#198):
#
#   curl -fsSL https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --yes --port 47820     # 參數原樣交給 `purrdr-host-service install`
#   curl -fsSL …/install.sh | sh -s -- --https-port 8443      # HTTPS 443 已被其他 `tailscale serve` 服務使用時
#
# 下載這台主機的 Release 壓縮檔，以 SHA256SUMS 驗證(不符就中止、不留檔),解壓到暫存資料夾後執行
# `purrdr-host-service install`(把執行檔複製到 ~/.purrdr/host-service/bin/ 並設定自動啟動)。已安裝時就是更新，
# 已配對的裝置會保留。不需要 sudo。
#
# 環境變數:
#   PURRDR_HOST_SERVICE_VERSION       指定版本(例:0.1.0);預設最新版
#   PURRDR_HOST_SERVICE_DOWNLOAD_URL  下載來源(網址或本機資料夾;測試用)
set -eu

repository="https://github.com/raychiutw/purrdr.ios"

# 重跑這個安裝的指令(主機服務的錯誤訊息用它組出「下一步」)。
rerun="curl -fsSL $repository/releases/latest/download/install.sh | sh -s --"
if [ -n "${PURRDR_HOST_SERVICE_VERSION:-}" ]; then
    # 值加單引號顯示(內含的 ' 寫成 '\''),複製貼上也不會被 shell 解讀。
    quoted_version="'$(printf '%s' "$PURRDR_HOST_SERVICE_VERSION" | sed "s/'/'\\\\''/g")'"
    rerun="curl -fsSL $repository/releases/latest/download/install.sh | PURRDR_HOST_SERVICE_VERSION=$quoted_version sh -s --"
fi

# fail <發生什麼> <下一步>
fail() {
    echo "purrdr-host-service install: $1" >&2
    echo "Next: $2" >&2
    exit 1
}

case "$(uname -s)" in
    Darwin) system="apple-darwin" ;;
    Linux) system="unknown-linux-musl" ;;
    *) fail "unsupported system: $(uname -s)." "on Windows, run install.ps1 in PowerShell: irm $repository/releases/latest/download/install.ps1 | iex" ;;
esac
case "$(uname -m)" in
    arm64 | aarch64) architecture="aarch64" ;;
    x86_64 | amd64) architecture="x86_64" ;;
    *) fail "unsupported architecture: $(uname -m); Releases are built for arm64 and x86_64." "open an issue at $repository/issues with the output of \`uname -sm\`." ;;
esac
asset="purrdr-host-service-$architecture-$system.tar.gz"

if [ -n "${PURRDR_HOST_SERVICE_DOWNLOAD_URL:-}" ]; then
    source="$PURRDR_HOST_SERVICE_DOWNLOAD_URL"
elif [ -n "${PURRDR_HOST_SERVICE_VERSION:-}" ]; then
    source="$repository/releases/download/host-service-v$PURRDR_HOST_SERVICE_VERSION"
else
    source="$repository/releases/latest/download"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/purrdr-host-service.XXXXXX")" || fail "cannot create a temporary folder in ${TMPDIR:-/tmp}." "free up space or set TMPDIR to a writable folder, then run again: $rerun"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

fetch() {
    download_failed="download failed: $source/$1 (no network, or the Release does not exist); nothing was installed."
    download_next="check your network and that the version exists at $repository/releases, then run again: $rerun"
    case "$source" in
        http://* | https://*) curl -fsSL --proto '=https,http' -o "$work/$1" "$source/$1" || fail "$download_failed" "$download_next" ;;
        *) cp "$source/$1" "$work/$1" 2>/dev/null || fail "$download_failed" "$download_next" ;;
    esac
}

fetch SHA256SUMS
fetch "$asset"

expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$work/SHA256SUMS")"
[ -n "$expected" ] || fail "no checksum for $asset in SHA256SUMS, so the download cannot be verified; nothing was installed." "run again later: $rerun (if it keeps failing, open an issue at $repository/issues)"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/$asset" | awk '{ print $1 }')"
else
    actual="$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')"
fi
[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset (expected $expected, got $actual): the download is incomplete or was altered, so nothing was installed." "run again: $rerun (if it keeps failing, open an issue at $repository/issues)"

mkdir "$work/extracted"
tar -xzf "$work/$asset" -C "$work/extracted" || fail "cannot extract $asset; nothing was installed." "run again: $rerun"
executable="$work/extracted/purrdr-host-service"
[ -x "$executable" ] || fail "$asset does not contain purrdr-host-service; nothing was installed." "open an issue at $repository/issues"

# `curl … | sh` 時 stdin 是這份腳本：安裝要問的確認改從終端機讀。沒有終端機(CI、--yes)就照原樣。
export PURRDR_HOST_SERVICE_INSTALL_COMMAND="$rerun"
status=0
if (exec </dev/tty) 2>/dev/null; then
    "$executable" install "$@" </dev/tty || status=$?
else
    "$executable" install "$@" || status=$?
fi
if [ "$status" -ne 0 ]; then
    # 主機服務已印出原因與下一步，這裡只指回去，不蓋掉它。
    echo "purrdr-host-service install: install did not finish (exit code $status); see the reason and next step above." >&2
    exit "$status"
fi
