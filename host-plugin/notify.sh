#!/bin/sh
# Purrdr 主機外掛(macOS／Linux):herdr 在 pane.agent_status_changed 時以新程序執行這個腳本。
#
# Agent 進入 blocked(「需要你」)時，對 ~/.purrdr/push-*/pairing 的每一支配對裝置呼叫 Purrdr 後台的 /v1/push。
# 請求只帶 workspace 名稱、狀態與 pane id(推播內容由後台組),不帶終端機標題或任何對話內容。
# 配對密鑰經 stdin 交給 curl,不出現在指令參數裡。
# 沒有常駐程序、不寫任何狀態;失敗不重試(下一次「需要你」會再送)。

status=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | sed -nE 's/.*"agent_status":"([a-z_]*)".*/\1/p')
[ "$status" = "blocked" ] || exit 0

# 取出 JSON 字串欄位的值，維持 JSON 的跳脫(原樣放回請求的 JSON 裡)。
json_string() {
  printf '%s' "$1" | sed -nE 's/.*"'"$2"'":"(([^"\\]|\\.)*)".*/\1/p' | head -n 1
}

pane=$(json_string "${HERDR_PLUGIN_EVENT_JSON:-}" pane_id)
case $pane in
  '' | *[!A-Za-z0-9:_.-]*) pane= ;;
esac
workspace=$(json_string "${HERDR_PLUGIN_CONTEXT_JSON:-}" workspace_label)
[ -n "$workspace" ] || workspace=$(json_string "${HERDR_PLUGIN_EVENT_JSON:-}" workspace_id)
[ -n "$workspace" ] || exit 0

if [ -n "$pane" ]; then
  extra=',"pane":"'"$pane"'"'
else
  extra=
fi

session=
asked=
for file in "$HOME"/.purrdr/push-*/pairing; do
  [ -f "$file" ] || continue
  key=$(sed -n 's/^key=//p' "$file" | head -n 1)
  endpoint=$(sed -n 's/^endpoint=//p' "$file" | head -n 1)
  [ -n "$key" ] && [ -n "$endpoint" ] || continue
  # 這支裝置靜音了這個聊天(以 Agent 的 session 值識別)→ 跳過。有靜音時才問 herdr 一次。
  if grep -q '^muted=' "$file"; then
    if [ -z "$asked" ] && [ -n "$pane" ]; then
      asked=1
      session=$("${HERDR_BIN_PATH:-herdr}" pane get "$pane" 2>/dev/null |
        sed -nE 's/.*"agent_session":\{[^}]*"value":"([^"\\]*)".*/\1/p' | head -n 1)
    fi
    if [ -n "$session" ] && grep -qxF "muted=$session" "$file"; then
      continue
    fi
  fi
  printf '{"key":"%s","workspace":"%s","status":"blocked"%s}' "$key" "$workspace" "$extra" |
    curl -sS -o /dev/null --max-time 10 -X POST -H 'content-type: application/json' --data-binary @- "$endpoint" || true
done
