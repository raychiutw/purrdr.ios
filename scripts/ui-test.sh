#!/bin/bash
# 跑 UI 測試:經 lockf 排隊(只有一台模擬器),取得鎖之後才重設模擬器的鍵盤偏好,再跑 xcodebuild test。
# 用法:scripts/ui-test.sh [--help] [--no-reset-keyboard] [xcodebuild 額外參數…]
#   scripts/ui-test.sh -testPlan Daily
#   scripts/ui-test.sh -testPlan Full
#   scripts/ui-test.sh -only-testing:PurrdrUITests/ConversationUITests/testComposerAndKeyboard
# 沒有帶 -testPlan 時預設 Daily。環境變數:PURRDR_SIM_NAME(預設 iPhone 17)。
# 重設內容(只動鍵盤偏好,不 erase 整台模擬器):
#   - com.apple.keyboard.preferences:刪掉 HardwareKeyboardLastSeen、AutomaticMinimizationEnabled(typeKey 寫進去的),
#     KeyboardsCurrentAndNext 改回英文
#   - 全域 AppleKeyboards 改回英文(注音、手寫等輸入法排第一會讓 typeEnglish 失敗)
# 重設只在持有鎖之後做,不會動到別人正在跑的測試。
set -euo pipefail

reset_keyboard=1
args=()
for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --no-reset-keyboard) reset_keyboard=0 ;;
    *) args+=("$a") ;;
  esac
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
sim="${PURRDR_SIM_NAME:-iPhone 17}"

has_plan=0
for a in ${args[@]+"${args[@]}"}; do
  if [[ "$a" == "-testPlan" ]]; then has_plan=1; fi
done
if [[ $has_plan -eq 0 ]]; then args+=(-testPlan Daily); fi

if [[ "${PURRDR_UITEST_LOCKED:-}" != 1 ]]; then
  # 取得鎖後以同一支腳本重入(PURRDR_UITEST_LOCKED=1),重設與測試都在鎖內
  export PURRDR_UITEST_LOCKED=1
  relock=("$0")
  if [[ $reset_keyboard -eq 0 ]]; then relock+=(--no-reset-keyboard); fi
  exec lockf /tmp/purrdr-uitest.lock "${relock[@]}" "${args[@]}"
fi

if [[ $reset_keyboard -eq 1 ]]; then
  udid="$(xcrun simctl list devices available -j | python3 -I -c '
import json,sys
name=sys.argv[1]
for rt,ds in json.load(sys.stdin)["devices"].items():
    for d in ds:
        if d["name"]==name:
            print(d["udid"]); sys.exit()
' "$sim")"
  if [[ -z "$udid" ]]; then echo "找不到模擬器「$sim」" >&2; exit 1; fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  d() { xcrun simctl spawn "$udid" defaults "$@"; }
  d delete com.apple.keyboard.preferences HardwareKeyboardLastSeen 2>/dev/null || true
  d delete com.apple.keyboard.preferences AutomaticMinimizationEnabled 2>/dev/null || true
  d write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array "en_US@sw=QWERTY;hw=Automatic" "en_US@sw=QWERTY;hw=Automatic"
  d write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic"
  echo "已重設「$sim」的鍵盤偏好"
fi

exec xcodebuild test -project src/App/Purrdr.xcodeproj -scheme Purrdr \
  -destination "platform=iOS Simulator,name=$sim" \
  -derivedDataPath .derivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -skipPackagePluginValidation -collect-test-diagnostics never \
  -clonedSourcePackagesDirPath ~/Library/Caches/purrdr-spm \
  "${args[@]}"
