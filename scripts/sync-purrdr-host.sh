#!/bin/sh
# 從主機端 repo raychiutw/purrdr.host(公開)同步 app 需要的檔案。
#
#   scripts/sync-purrdr-host.sh [ref]    以 ref(branch、tag 或 commit,預設 master)解析成 commit SHA 後拉回
#   scripts/sync-purrdr-host.sh --check  依 vendor/purrdr-host/VERSION 記的 commit 重新取回比對，不同就 exit 1(CI 跑)
#
# 同步的內容：
#   generated/swift/HostServiceProtocol.swift → src/PurrdrCore/HostServiceProtocol.swift(codegen 產生的協定型別)
#   protocol/(schema 與 examples/)             → vendor/purrdr-host/protocol/(FakeHostService 與範例測試讀它)
#   claude-usage/statusline.{sh,ps1}           → vendor/purrdr-host/claude-usage/(Claude 方案用量的 status line 包裝腳本,0.12.0 起)
#   host-service/service/Cargo.toml 的版本號    → vendor/purrdr-host/VERSION(連同 commit SHA,CI 的 --check 依它比對)
#
# 改協定的流程：在 purrdr.host 改 schema、跑 codegen 並合併 → 這裡跑本腳本 → 讓 app 的測試通過。
# 不需要本機 clone:commit 經 GitHub API 解析(有 GITHUB_TOKEN／GH_TOKEN 就帶上),內容從 codeload 的 tarball 取。
set -eu

repo="raychiutw/purrdr.host"
root="$(cd "$(dirname "$0")/.." && pwd)"
version_file="$root/vendor/purrdr-host/VERSION"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 解析 ref 成完整的 commit SHA。
resolve() {
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
        set -- -H "Authorization: Bearer $token"
    else
        set --
    fi
    curl -fsSL "$@" -H "Accept: application/vnd.github.sha" \
        "https://api.github.com/repos/$repo/commits/$ref"
}

# 取回 commit $1 的 tarball,把同步的檔案寫到 $2(與 repo 根目錄同樣的相對路徑)。
materialize() {
    sha="$1"
    out="$2"
    src="$work/src-$sha"
    mkdir -p "$src"
    curl -fsSL "https://codeload.github.com/$repo/tar.gz/$sha" | tar -xzf - -C "$src" --strip-components=1

    manifest="$src/host-service/service/Cargo.toml"
    version="$(awk '
      /^\[/ { in_package = ($0 == "[package]") }
      in_package && /^version[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }
    ' "$manifest")"
    if [ -z "$version" ]; then
        echo "$repo@$sha 的 host-service/service/Cargo.toml 找不到 [package] version" >&2
        exit 1
    fi

    mkdir -p "$out/src/PurrdrCore" "$out/vendor/purrdr-host"
    cp "$src/generated/swift/HostServiceProtocol.swift" "$out/src/PurrdrCore/HostServiceProtocol.swift"
    rm -rf "$out/vendor/purrdr-host/protocol"
    cp -R "$src/protocol" "$out/vendor/purrdr-host/protocol"
    rm -rf "$out/vendor/purrdr-host/claude-usage"
    mkdir -p "$out/vendor/purrdr-host/claude-usage"
    cp "$src/claude-usage/statusline.sh" "$src/claude-usage/statusline.ps1" "$out/vendor/purrdr-host/claude-usage/"
    {
        echo "# 由 scripts/sync-purrdr-host.sh 產生，不要手動修改。來源 https://github.com/$repo"
        echo "commit=$sha"
        echo "host_service_version=$version"
    } > "$out/vendor/purrdr-host/VERSION"
}

case "${1:-}" in
    --check)
        if [ ! -f "$version_file" ]; then
            echo "找不到 vendor/purrdr-host/VERSION;先跑 scripts/sync-purrdr-host.sh" >&2
            exit 1
        fi
        sha="$(sed -n 's/^commit=//p' "$version_file")"
        if [ -z "$sha" ]; then
            echo "vendor/purrdr-host/VERSION 沒有 commit=" >&2
            exit 1
        fi
        expected="$work/expected"
        materialize "$sha" "$expected"
        status=0
        diff -u "$expected/src/PurrdrCore/HostServiceProtocol.swift" "$root/src/PurrdrCore/HostServiceProtocol.swift" || status=1
        diff -ru "$expected/vendor/purrdr-host" "$root/vendor/purrdr-host" || status=1
        if [ "$status" -ne 0 ]; then
            echo "與 $repo@$sha 不同：協定檔案不要手改，在 purrdr.host 改好後執行 scripts/sync-purrdr-host.sh" >&2
            exit 1
        fi
        echo "與 $repo@$sha 一致"
        ;;
    -*)
        echo "用法:scripts/sync-purrdr-host.sh [ref] | --check" >&2
        exit 2
        ;;
    *)
        ref="${1:-master}"
        sha="$(resolve)"
        case "$sha" in
            *[!0-9a-f]* | "")
                echo "無法把 $ref 解析成 commit:$sha" >&2
                exit 1
                ;;
        esac
        materialize "$sha" "$root"
        echo "已同步 $repo@$sha(主機服務 $(sed -n 's/^host_service_version=//p' "$version_file"))"
        ;;
esac
