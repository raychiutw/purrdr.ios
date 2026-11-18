#!/bin/sh
# String Catalog 與程式碼同步(#32)。
#
#   scripts/strings.sh sync  [derivedData]   以編譯器抽出畫面字串，把缺的 key 加進 catalog、移除程式碼已不用的 key
#   scripts/strings.sh check [derivedData]   只檢查：缺 key、沒有繁體中文、程式碼已不用 → exit 1
#
# 為什麼要這支腳本：畫面字串寫在 package(PurrdrFeatures、PurrdrAgentFeatures),catalog 放在 app(`src/App/Purrdr/Localizable.xcstrings`),
# 執行時 SwiftUI 與 String(localized:) 預設從 Bundle.main 查字串。Xcode 只會把 app target 自己的字串
# 同步進 app 的 catalog,不會抽 package 的字串，所以由這支腳本以「編譯器抽出的 .stringsdata」補上。
# catalog 裡的 key 一律標 `extractionState: manual`,Xcode 建置 app 時才不會把它們標成 stale。
#
# 沒給 derivedData 時，自己以 iOS 編譯 package(SWIFT_EMIT_LOC_STRINGS=YES)到 .derivedData/strings。
# 給了的話，那份 derivedData 必須是以 SWIFT_EMIT_LOC_STRINGS=YES 建置的(CI 的 package iOS 編譯就是)。
set -eu

mode="${1:-}"
case "$mode" in
    sync | check) ;;
    *)
        echo "用法:scripts/strings.sh sync|check [derivedData]" >&2
        exit 2
        ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${2:-}"
if [ -z "$derived" ]; then
    derived="$root/.derivedData/strings"
    xcodebuild build -scheme Purrdr-Package -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived" -skipPackagePluginValidation SWIFT_EMIT_LOC_STRINGS=YES -quiet \
        -clonedSourcePackagesDirPath "$HOME/Library/Caches/purrdr-spm"
fi

exec python3 -I "$root/scripts/strings.py" "$mode" "$root/src/App/Purrdr/Localizable.xcstrings" "$derived"
