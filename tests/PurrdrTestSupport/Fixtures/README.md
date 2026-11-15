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
| `herdr-0.9.5/agent.wait.matched.ndjson` | `agent.wait {target, until:[idle,done], timeout_ms:300}`,對一個已閒置的 agent(唯讀：只等待，不送任何輸入) | 2026-11-16 | 等待符合(`agent_info`);也當 `agent.prompt` 成功回應的底(見下) |
| `herdr-0.9.5/error.agent-wait-timeout.ndjson` | `agent.wait {target, until:[working,blocked], timeout_ms:300}`(唯讀) | 2026-11-16 | herdr 自己的 `timeout`(停滯);也當其他 `agent.prompt` 錯誤的底 |
| `herdr-0.9.5/workspace.get.ndjson` | `workspace.get {"workspace_id":"w1"}`(唯讀;label 換成假值) | 2026-11-16 | `workspace_info` 形狀，當作 `workspace.rename` 成功回應的底 |
| `herdr-0.9.5/error.workspace-not-found.ndjson` | `workspace.get {"workspace_id":"w99"}` | 2026-11-16 | `workspace_not_found`;也當作其他 workspace 錯誤的 envelope 底 |
| `herdr-0.9.5/error.not-git-worktree.ndjson` | `worktree.list {"cwd":"/tmp"}`(唯讀) | 2026-11-16 | 建 worktree 時資料夾不在 git repo(`not_git_worktree`) |
| `herdr-0.9.5/pane.report-metadata.ndjson` | `pane.report_metadata`(`phone:on`、`model`、`ttl_ms` 45000、`seq`) | 2026-11-16 | 在場回報被接受(`{"type":"ok"}`) |
| `herdr-0.9.5/pane.read.visible.ndjson` | `pane.read {pane_id, source:"visible", lines:40}`,對一個**已經閒置**的 Claude pane(唯讀) | 2026-11-16 | `pane_read` envelope 的形狀。**`text` 整段換成手寫的 `screens/claude-idle.txt`**、pane／tab id 換成假值(原畫面含個人內容) |
| `herdr-0.9.5/pane.read.agents-pane.ndjson` | `pane.read {"pane_id":…,"source":"visible","lines":40}`(一個有 5 個背景 agent 在跑的 Claude Code pane) | 2026-11-16 | 背景 agents 窗格的解析與讀取時機(#17)。窗格的記號、種類、經過時間、tokens、`↓ 4 more` 與欄寬原樣;回覆內容、輸入框、狀態列(專案、分支、費用)與每列的任務文字換成假值 |

## Claude Code 對話紀錄(`claude-code/`)

`claude-code/session.jsonl`:從作者 Mac 上真實的 Claude Code 2.1.317–2.1.323 對話紀錄(`~/.claude/projects/…/*.jsonl`)擷取 30 行，2026-11-16。只讀取來源，不改動。

- **保留原樣**:每行的 `type`、欄位與旗標(`isMeta`、`promptId`、`origin`、`sourceToolUseID`、`isSidechain`、`is_error`…)、content block 的種類與順序、model、usage、時間戳。涵蓋：本地指令(`/effort` 的 caveat、command-name、local-command-stdout)、`api-request-blob`、使用者打的字、空的與有內容的 thinking、Bash／Edit／Skill 工具呼叫與結果(含失敗)、`Skill` 載入時的 meta 行、`queued_command` attachment、slash 指令載入 skill 的 meta 行、表格與程式碼的回覆、`system` 行。
- **換成假值**:所有文字內容、工具輸入與結果、路徑(`/Users/demo/Projects/ledger`)、session id、uuid(`00000000-0000-4000-8000-…`)、簽章;拿掉 `wireToolInputs`、`requestRef` 等可能帶原文的欄位。一個 Bash 呼叫改名為 Edit(輸入一起換)。
- 存檔後以 `grep` 確認沒有真實的使用者名稱、專案名稱或主機名。

`claude-code/delegation.jsonl` 與 `claude-code/subagents/`(#17):從作者 Mac 上兩份真實對話紀錄(Claude Code 2.1.317 與 2.1.325)與其 session 資料夾的 `subagents/` 擷取，2026-11-16。只讀取來源，不改動。

- `delegation.jsonl` 8 行：背景 `Agent` 呼叫、它的「Async agent launched」結果、harness 寫的任務通知、前景 `Agent` 呼叫與 hand-back 結果(含 `<usage>`)、`SendMessage` 呼叫與 `resumedAgentId` 結果、`queued_command` 的任務通知(只有 task-id)。
- `subagents/`:背景與前景 agent 的 `agent-<id>.meta.json`,以及背景 agent 對話紀錄的前 6 行(sidechain 的 user／assistant／tool_result,加一個 attachment)。
- **保留原樣**:行的結構、旗標(`origin.kind`、`promptSource`、`isSidechain`…)、harness 固定說明句、`<task-notification>` 的標籤與 `<usage>` 數字、hand-back 框的格式與兩格縮排、meta 的欄位、model、usage、時間戳。
- **換成假值**:所有文字內容(description、prompt、報告、結果、summary)、工具輸入與結果、路徑(`/Users/demo/Projects/ledger`、`/private/tmp/demo/tasks/…`)、session id、uuid(`00000000-0000-4000-9000-…`)、tool use id(`toolu_demo_d0N`)、agent id(`ad3e…`);拿掉 `wireToolInputs`、`requestRef`、`pin`、`outputFile`、`<worktree>` 等可能帶原文的欄位。
- **兩份來源合在一起**:第 5–7 行(`SendMessage`、續跑結果、排隊中的通知)取自另一份對話紀錄，收件的 agent id 換成第 0–2 行背景 agent 的 id,好組成「完成 → 續跑 → 再回報」的序列;因此第 7 行的時間戳早於第 5、6 行(判斷依檔案順序，不看時間戳)。
- 擷取腳本的做法：以 Python 讀 JSON、依欄位名換值，再 `grep` 確認沒有真實的使用者名稱、專案名稱、主機名或原始 id。

`claude-code/workflow/`(#17):**不是錄製的**。作者 Mac 上所有 `~/.claude/projects` 都沒有 `Workflow` 工具的紀錄、run 檔或 journal,所以 `run.json` 與 `journal.jsonl` 依行為規格 §4.6 描述的欄位寫成(journal 最後一行刻意撕裂)。測試裡 `Workflow` 呼叫與「Workflow launched」結果也是以 `delegation.jsonl` 的行為底改成。之後錄得到真實 workflow 時應換掉。

## 錄不到、以真實回應為底改動的情境

測試以 `FakeReply.recorded(_:modify:)`／`Fixtures.modifiedLine` 改動真實回應，改了什麼寫在測試裡:

- **`input_pending`**:herdr 0.9.5 的 schema(`herdr api schema --json`)與執行檔都沒有這個欄位，主機永遠不會送;行為規格 F2.2 要求出現時要讀，測試在錄製的 snapshot 上加上它。
- **`events_lost`**:要讓伺服器的事件歷史溢出才會發生。錯誤碼與訊息取自 herdr 0.9.5 執行檔的字串,envelope 形狀沿用 `error.pane-not-found.ndjson`。
- **事件行**(`{"event":"pane_agent_status_changed","data":{…}}`):錄製期間(兩次共約 45 分鐘)主機上沒有狀態改變，依 schema 的 EventEnvelope 寫在測試裡。事件只當重讀的觸發，內容不影響結果。
- **`agent.prompt`／`pane.send_keys`**:錄製會把文字或按鍵送進真的 agent,**一律不錄**。`PromptReplies` 以上面兩份唯讀的 `agent.wait` 錄製為底改動：成功換成 `agent_prompted`(`herdr api schema --json`),錯誤碼換成 `agent_prompt_stalled`(訊息取自執行檔字串)、`agent_blocked`、`agent_input_pending`;`delivery: "written_to_pty"` 只有 fork 會送，用來測「無法驗證」的 fallback Enter。按鍵成功的 `{"type":"ok"}` 沿用 `pane.report-metadata.ndjson`。
- 其他狀態組合(blocked、改名、移除 pane、workspace 順序)用 `SnapshotEdit` 改錄製的 snapshot。
- **會改主機狀態的 workspace 操作**(`workspace.rename`、`workspace.close`、`worktree.create`)**不在作者主機上執行**。成功回應：rename 以 `workspace.get.ndjson` 為底改 label;close 的 `{"type":"ok"}` 與 worktree 的 `worktree_created` 依 `herdr api schema --json` 寫在測試裡。`workspace_group_close_required` 碼取自 herdr CLI 文件(cli-reference「Worktrees」),envelope 沿用 `error.workspace-not-found.ndjson`。
- **切分、zoomed、只出現在版面的 tab／pane**:錄製時主機上每個 tab 都只有一個 pane,以 `layouts[]` 改動模擬(見 `SpacesLayoutTests`)。

## 「需要你」的畫面(`screens/`)——依行為規格手寫、未實測

`screens/*.txt` 是 pane 的 visible 畫面(`pane.read` 的 `text`),給提示解析與作答測試用(#14)。**不是錄製的**:
作者主機上沒有正在問問題的 agent,而為了錄製去製造 blocked 狀態會把按鍵送進真的 agent,所以一律不錄。
形狀依 `docs/research/herdrchat-behavior-spec.md` §5.2–§5.4 的描述(Claude 2.1.286／2.1.299 的權限與信任提示、
AskUserQuestion 的分頁頭與多選、Codex 的 `›` 游標與 `Would you like to…` 段落、Grok 的 `(●)` 列、agy 的折行資料夾),
內容(指令、路徑、問題)是自己寫的範例。測試用 `PaneScreens.read(_:)` 把它放進錄製的 `pane.read` envelope。
真機第一次看到 blocked 畫面時，以唯讀的 `pane.read` 讀下來去識別化，換掉對應的檔案。

## 其他 agent 的對話紀錄(`other-agents/`)——依文件撰寫、未實測

作者的 Mac 上沒有 Grok、Antigravity、Pi、OMP,這些檔案**不是**從真實主機擷取，而是依下列來源**手寫**的(#25)。
格式是各 agent 的內部檔案，可能與實際版本不同;拿到真實 session 後應換成擷取檔。內容(專案、路徑、文字)都是自己寫的範例。

| 檔案 | 格式依據 | 涵蓋 |
|---|---|---|
| `other-agents/grok/updates.jsonl` | 行為規格 §4.3(依 Grok 1.0.52 描述)、ACP `session/update` 通知的形狀 | 使用者訊息、Grok 自己寫的 prompt(`syntheticPrompt`)、thought、`tool_call`(`x.ai/tool` 名稱)、進度更新、completed／failed 結果、diff 結果、`_x.ai/session/update` 的 plan(忽略)、沒有 `eventId` 的行 |
| `other-agents/antigravity/transcript.jsonl` | 行為規格 §4.4(依 agy 1.3.6 描述)。`tool_calls[i]` 的參數欄位名沒有公開文件，這裡用 `args` | `USER_EXPLICIT` 與 `USER_REQUEST`、模型切換的 `USER_INPUT`、`PLANNER_RESPONSE`(thinking、文字、呼叫、token)、`GENERIC` 輸出(Created At／Completed At、CRLF)、`EPHEMERAL_MESSAGE`(忽略) |
| `other-agents/pi/session.jsonl` | 行為規格 §4.5;Pi 官方文件 `packages/coding-agent/docs/session-format.md`、`message-types.md`(github.com/badlogic/pi-mono,2026-11-16 取用) | session header、`model_change`、`thinking_level_change`、system 訊息(忽略)、user(字串與 block、圖片)、assistant(thinking、redacted、`redactedThinking`、toolCall、usage、stopReason)、toolResult(含錯誤)、`compaction`、`branch_summary`、`reset_boundary`、中斷的輪次(usage 為 0) |

`message.timestamp`(毫秒)刻意和 entry 的 ISO 時間不同，測試才分得出取的是哪一個。OMP 的標題槽(`{"type":"title",…}`)寫在測試裡。
