#!/bin/sh
# 印出某個 commit 的 app 版本號(project.pbxproj 的 MARKETING_VERSION)。
# 4 處(app、UI 測試 × Debug/Release)不一致就失敗，避免只改了其中幾處。
# 用法:scripts/marketing-version.sh [commit](預設 HEAD)
# TestFlight workflow 以它比對合併前後的版本號：有變才上傳。
set -eu

commit="${1:-HEAD}"
project="src/App/Purrdr.xcodeproj/project.pbxproj"

versions="$(git show "$commit:$project" | sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' | sort -u)"
count="$(printf '%s\n' "$versions" | grep -c . || true)"

if [ "$count" -ne 1 ]; then
  echo "$commit 的 MARKETING_VERSION 不一致或找不到:" $versions >&2
  exit 1
fi
printf '%s\n' "$versions"
