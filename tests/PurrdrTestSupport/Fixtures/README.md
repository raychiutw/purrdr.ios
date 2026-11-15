# 錄製回應(假主機回放用)

假主機(`FakeHost`)回放的主機回應，一律從**真實主機**錄下，不照程式碼手寫。目錄依 herdr 版本分(`herdr-0.9.5/`)。

## 錄製

```bash
scripts/record-herdr-fixture.sh <檔名> <method> [params JSON] [ssh 目的地]
```

腳本經 `herdr remote-api-bridge` 送一行請求(stdin 保持開著 2 秒，不送 EOF),只留第一行回應，並自動把家目錄換成 `/Users/demo`、使用者名稱換成 `demo`、session UUID 換成 `00000000-…-000000000001` 這類假值。

**workspace 名稱、終端機標題、資料夾名稱腳本不會動**:存檔後一定要打開檢查，換成假值，再用 `grep` 確認沒有真實的專案名稱或路徑。

## 清單

| 檔案 | 請求 | 錄製日期 | 用來驗證 |
|---|---|---|---|
| `herdr-0.9.5/session.snapshot.ndjson` | `session.snapshot {}`(作者的 Mac,3 個 Claude Code agent + 1 個 shell pane) | 2026-11-15 | snapshot 解碼、Agent 列表分組 |
| `herdr-0.9.5/error.invalid-request.ndjson` | 格式錯誤的請求(`params` 不是合法 JSON) | 2026-11-15 | herdr 錯誤 envelope 保留錯誤碼與原文 |
| `herdr-0.9.5/ping.ndjson` | `ping {}`(作者的 Mac) | 2026-11-15 | 連線測試讀伺服器版本 |
| `herdr-0.9.5/integration.list.ndjson` | `integration.list {}`(作者的 Mac) | 2026-11-15 | 連線測試列出主機上有的 agent 整合 |
| `herdr-0.9.5/session-control/*.stdout.ndjson`、`*.stdin.ndjson` | `herdr terminal session control`／`observe` 的 stdout 原樣與我方送出的 stdin(#4 spike,40×12 乾淨 bash) | 2026-11-15 | Pane 終端機的 frame 解析、`terminal.closed` 分類、輸入格式;情境說明與重錄方式見 `docs/research/terminal-session-control-macos.md`「Fixture」 |
| `herdr-0.9.5/events.subscribe.started.ndjson` | `events.subscribe`(3 個 agent pane 的 `pane.agent_status_changed` + 全主機事件),只留 ack | 2026-11-15 | 訂閱開始(`subscription_started`) |
| `herdr-0.9.5/error.pane-not-found.ndjson` | `events.subscribe` 訂閱不存在的 pane `w9:pZ` | 2026-11-15 | 訂閱被拒;也當作 `events_lost` 的底(見下) |
| `herdr-0.9.5/error.unknown-subscription-type.ndjson` | `events.subscribe` 訂閱 herdr 不認得的型別 `pane.turn_completed` | 2026-11-15 | 未知型別讓整個訂閱被拒(保留備查) |
| `herdr-0.9.5/pane.report-metadata.ndjson` | `pane.report_metadata`(`phone:on`、`model`、`ttl_ms` 45000、`seq`) | 2026-11-16 | 在場回報被接受(`{"type":"ok"}`) |

## Claude Code 對話紀錄(`claude-code/`)

`claude-code/session.jsonl`:從作者 Mac 上真實的 Claude Code 2.1.317–2.1.323 對話紀錄(`~/.claude/projects/…/*.jsonl`)擷取 30 行，2026-11-16。只讀取來源，不改動。

- **保留原樣**:每行的 `type`、欄位與旗標(`isMeta`、`promptId`、`origin`、`sourceToolUseID`、`isSidechain`、`is_error`…)、content block 的種類與順序、model、usage、時間戳。涵蓋：本地指令(`/effort` 的 caveat、command-name、local-command-stdout)、`api-request-blob`、使用者打的字、空的與有內容的 thinking、Bash／Edit／Skill 工具呼叫與結果(含失敗)、`Skill` 載入時的 meta 行、`queued_command` attachment、slash 指令載入 skill 的 meta 行、表格與程式碼的回覆、`system` 行。
- **換成假值**:所有文字內容、工具輸入與結果、路徑(`/Users/demo/Projects/ledger`)、session id、uuid(`00000000-0000-4000-8000-…`)、簽章;拿掉 `wireToolInputs`、`requestRef` 等可能帶原文的欄位。一個 Bash 呼叫改名為 Edit(輸入一起換)。
- 存檔後以 `grep` 確認沒有真實的使用者名稱、專案名稱或主機名。

## 錄不到、以真實回應為底改動的情境

測試以 `FakeReply.recorded(_:modify:)`／`Fixtures.modifiedLine` 改動真實回應，改了什麼寫在測試裡:

- **`input_pending`**:herdr 0.9.5 的 schema(`herdr api schema --json`)與執行檔都沒有這個欄位，主機永遠不會送;行為規格 F2.2 要求出現時要讀，測試在錄製的 snapshot 上加上它。
- **`events_lost`**:要讓伺服器的事件歷史溢出才會發生。錯誤碼與訊息取自 herdr 0.9.5 執行檔的字串,envelope 形狀沿用 `error.pane-not-found.ndjson`。
- **事件行**(`{"event":"pane_agent_status_changed","data":{…}}`):錄製期間(兩次共約 45 分鐘)主機上沒有狀態改變，依 schema 的 EventEnvelope 寫在測試裡。事件只當重讀的觸發，內容不影響結果。
- 其他狀態組合(blocked、改名、移除 pane、workspace 順序)用 `SnapshotEdit` 改錄製的 snapshot。
