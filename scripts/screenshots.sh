#!/bin/sh
# 截圖巡覽(#34):以 Demo 主機跑 `ScreenshotTourUITests`,把每張截圖匯出成 PNG。
#
#   scripts/screenshots.sh [輸出資料夾] [模擬器名稱]
#
# 預設輸出到 .derivedData/screenshots/<模擬器名稱>/,模擬器是「iPhone 17」(iPad 用「iPad Air 11-inch (M4)」)。
# 只用 Demo 主機(`-uiTesting`),不連任何真實主機，畫面上也沒有真實路徑、主機名或帳號。
# 模擬器只有一台、可能有別的 worktree 在用，所以整段 xcodebuild 在 /tmp/purrdr-uitest.lock 的鎖內執行;
# 跑完關掉模擬器。截圖檔名 = 測試裡 XCTAttachment 的名稱(例如 01-agent-list.png)。
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
device="${2:-iPhone 17}"
out="${1:-$root/.derivedData/screenshots/$device}"
bundle="$root/.derivedData/screenshots/Tour.xcresult"

rm -rf "$bundle"
mkdir -p "$out"
lockf /tmp/purrdr-uitest.lock sh -c '
    status=0
    xcodebuild test -project "$1/src/App/Purrdr.xcodeproj" -scheme Purrdr \
        -destination "platform=iOS Simulator,name=$2" -derivedDataPath "$1/.derivedData" \
        -parallel-testing-enabled NO -disable-concurrent-destination-testing -skipPackagePluginValidation -collect-test-diagnostics never \
        -resultBundlePath "$3" -only-testing:PurrdrUITests/ScreenshotTourUITests -quiet || status=$?
    xcrun simctl shutdown "$2" 2>/dev/null || true
    exit $status
' sh "$root" "$device" "$bundle"

export_dir="$(mktemp -d)"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$export_dir"
# manifest.json:每個測試的 attachment(exportedFileName、suggestedHumanReadableName)。
# 系統給的名稱是「<名稱>_<序號>_<UUID>.png」,只留名稱。
jq -r '.[].attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' "$export_dir/manifest.json" |
    while IFS="$(printf '\t')" read -r file name; do
        clean="$(printf '%s' "$name" | sed -E 's/_[0-9]+_[0-9A-Fa-f-]{36}(\.[a-z]+)$/\1/')"
        cp "$export_dir/$file" "$out/$clean"
    done
rm -rf "$export_dir"
echo "截圖在 $out"
ls "$out"
