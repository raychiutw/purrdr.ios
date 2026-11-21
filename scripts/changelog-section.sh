#!/bin/sh
# 印出 CHANGELOG.md 裡某個版本那一段(不含標題行)。
# 找不到該版本,或那一段是空的就以 1 結束,什麼都不印。
# 用法:scripts/changelog-section.sh <版本號> [CHANGELOG 路徑]
# 發版時 GitHub Release 的「本版更新」從這裡取;PR 的 CI 也用它確認目前版本號有寫版本說明。
set -eu

version="${1:?用法:scripts/changelog-section.sh <版本號> [CHANGELOG 路徑]}"
file="${2:-CHANGELOG.md}"

section="$(awk -v heading="## $version" '$0 == heading { found = 1; next } found && /^## / { exit } found' "$file" | sed '/./,$!d')"

if [ -z "$section" ]; then
  echo "$file 沒有 \"## $version\" 的版本說明" >&2
  exit 1
fi
printf '%s\n' "$section"
