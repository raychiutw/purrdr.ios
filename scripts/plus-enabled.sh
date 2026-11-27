#!/bin/sh
# 印出某個 commit 的 app target 的 Purrdr Plus 編譯開關(project.pbxproj 的 PURRDR_PLUS_ENABLED)。
# 用法:scripts/plus-enabled.sh <Debug|Release> [commit](不帶 commit 讀工作目錄的檔案)
# CI 的 plus-flag job 用它確認 Release 是 NO(上架版不提供訂閱與主機同步,#676)。
# 不是剛好一筆設定就失敗(漏設或重複設定都不接受)。
set -eu

configuration="${1:?用法:$0 <Debug|Release> [commit]}"
commit="${2:-}"
project="src/App/Purrdr.xcodeproj/project.pbxproj"

if [ -n "$commit" ]; then
  source="$(git show "$commit:$project")"
else
  source="$(cat "$project")"
fi

values="$(printf '%s\n' "$source" | awk -v want="$configuration" '
  /buildSettings = \{/ { inside = 1; value = ""; next }
  inside && /PURRDR_PLUS_ENABLED = / { value = $0; sub(/.*PURRDR_PLUS_ENABLED = /, "", value); sub(/;.*/, "", value) }
  inside && /^\t\t\t\};/ { inside = 0; next }
  /^\t\t\tname = / {
    name = $0; sub(/^\t\t\tname = /, "", name); sub(/;.*/, "", name)
    if (name == want && value != "") print value
    value = ""
  }
')"
count="$(printf '%s\n' "$values" | grep -c . || true)"

if [ "$count" -ne 1 ]; then
  echo "${commit:-工作目錄} 的 $configuration 找不到唯一一筆 PURRDR_PLUS_ENABLED:" $values >&2
  exit 1
fi
printf '%s\n' "$values"
