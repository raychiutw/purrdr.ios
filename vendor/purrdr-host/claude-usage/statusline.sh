#!/bin/sh
# Purrdr 的 Claude 方案用量包裝：由 Purrdr app(或主機服務)安裝，在 app 關閉「Claude 方案用量」就會還原。
# 把 Claude Code 交給 status line 的輸入存起來，再原樣交給原本的 status line:
# - sessions/<session_id>.json:每次都寫(每個 session 一份，不論有沒有 rate_limits;raychiutw/purrdr.host#64)
# - usage.json:輸入含 rate_limits 時才寫(整台主機一份)
# 存檔失敗一律略過，不影響 status line 的輸出;超過 7 天沒更新的 session 檔會清掉。
dir="$HOME/.purrdr/claude-usage"
input=$(cat)
now=$(date +%s)

# 以暫存檔寫好再換上(讀的一方不會讀到寫一半的檔)。$1 資料夾，$2 檔名，$3 內容。
save() {
  tmp=$(mktemp "$1/.tmp.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$3" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1/$2" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

session=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]{1,128})".*/\1/p' | head -n 1)
case $session in
  '' | . | ..) ;;
  *)
    if mkdir -p "$dir/sessions" 2>/dev/null; then
      save "$dir/sessions" "$session.json" "{\"captured_at\":$now,\"session_id\":\"$session\",\"status_line_input\":$input}"
      find "$dir/sessions" -type f -name '*.json' -mmin +10080 -exec rm -f {} + 2>/dev/null
    fi
    ;;
esac
case $input in
  *'"rate_limits"'*) save "$dir" usage.json "{\"captured_at\":$now,\"status_line_input\":$input}" ;;
esac

# 原本的 status line 的輸出與結束碼直接交給 Claude Code;沒有原本的就不輸出。
if [ -s "$dir/original-command" ]; then
  printf '%s\n' "$input" | sh -c "$(cat "$dir/original-command")"
fi
