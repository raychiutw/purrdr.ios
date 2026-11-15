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
- **`agent.prompt`／`pane.send_keys`**:錄製會把文字或按鍵送進真的 agent,**一律不錄**。`PromptReplies` 以上面兩份唯讀的 `agent.wait` 錄製為底改動：成功換成 `agent_prompted`(`herdr api schema --json`),錯誤碼換成 `agent_prompt_stalled`(訊息取自執行檔字串)、`agent_blocked`、`agent_input_pending`;`delivery: "written_to_pty"` 只有 fork 會送，用來測「無法驗證」的 fallback Enter。按鍵成功的 `{"type":"ok"}` 沿用 `pane.report-metadata.ndjson`。
- 其他狀態組合(blocked、改名、移除 pane、workspace 順序)用 `SnapshotEdit` 改錄製的 snapshot。
- **會改主機狀態的 workspace 操作**(`workspace.rename`、`workspace.close`、`worktree.create`)**不在作者主機上執行**。成功回應：rename 以 `workspace.get.ndjson` 為底改 label;close 的 `{"type":"ok"}` 與 worktree 的 `worktree_created` 依 `herdr api schema --json` 寫在測試裡。`workspace_group_close_required` 碼取自 herdr CLI 文件(cli-reference「Worktrees」),envelope 沿用 `error.workspace-not-found.ndjson`。
- **切分、zoomed、只出現在版面的 tab／pane**:錄製時主機上每個 tab 都只有一個 pane,以 `layouts[]` 改動模擬(見 `SpacesLayoutTests`)。

## 其他 agent 的對話紀錄(`other-agents/`)——依文件撰寫、未實測

作者的 Mac 上沒有 Grok、Antigravity、Pi、OMP,這些檔案**不是**從真實主機擷取，而是依下列來源**手寫**的(#25)。
格式是各 agent 的內部檔案，可能與實際版本不同;拿到真實 session 後應換成擷取檔。內容(專案、路徑、文字)都是自己寫的範例。

| 檔案 | 格式依據 | 涵蓋 |
|---|---|---|
| `other-agents/grok/updates.jsonl` | 行為規格 §4.3(依 Grok 1.0.52 描述)、ACP `session/update` 通知的形狀 | 使用者訊息、Grok 自己寫的 prompt(`syntheticPrompt`)、thought、`tool_call`(`x.ai/tool` 名稱)、進度更新、completed／failed 結果、diff 結果、`_x.ai/session/update` 的 plan(忽略)、沒有 `eventId` 的行 |
| `other-agents/antigravity/transcript.jsonl` | 行為規格 §4.4(依 agy 1.3.6 描述)。`tool_calls[i]` 的參數欄位名沒有公開文件，這裡用 `args` | `USER_EXPLICIT` 與 `USER_REQUEST`、模型切換的 `USER_INPUT`、`PLANNER_RESPONSE`(thinking、文字、呼叫、token)、`GENERIC` 輸出(Created At／Completed At、CRLF)、`EPHEMERAL_MESSAGE`(忽略) |
| `other-agents/pi/session.jsonl` | 行為規格 §4.5;Pi 官方文件 `packages/coding-agent/docs/session-format.md`、`message-types.md`(github.com/badlogic/pi-mono,2026-11-16 取用) | session header、`model_change`、`thinking_level_change`、system 訊息(忽略)、user(字串與 block、圖片)、assistant(thinking、redacted、`redactedThinking`、toolCall、usage、stopReason)、toolResult(含錯誤)、`compaction`、`branch_summary`、`reset_boundary`、中斷的輪次(usage 為 0) |

`message.timestamp`(毫秒)刻意和 entry 的 ISO 時間不同，測試才分得出取的是哪一個。OMP 的標題槽(`{"type":"title",…}`)寫在測試裡。

## Claude Code plugin／skill 結構(`claude-plugins/home/`)與 `skill_listing`(`claude-code/skill-listing.jsonl`)

`scripts/record-claude-plugins-fixture.py` 從作者 Mac 的 `~/.claude` **唯讀**錄製(2026-11-16),給 slash 清單的發現測試(#15)。

- **保留原樣**:`installed_plugins.json` 的結構與各筆安裝(版本、scope、多筆安裝);每個已安裝 plugin 的 `.claude-plugin/plugin.json`;
  所有 `SKILL.md` 與指令 `.md` 的路徑與 frontmatter(公開 plugin 的內容)。`mattpocock-skills` 1.3.2 有 38 個 SKILL.md,
  `plugin.json` 以 `skills/<分類>/<名稱>` 宣告其中 27 個,`skills/in-progress`、`skills/misc` 的 11 個沒有宣告。
- **換成假值或刪掉**:家目錄換成 `/Users/demo`;專案層安裝的 `projectPath` 換成 `/Users/demo/Projects/other-project-1`;
  `settings.json` 只留 `enabledPlugins`;`.md` 的內文換成「(內容略)」;作者自己寫的使用者層 skill(`apim-*`、
  `skill-creator-advanced` 等)不錄，`skill_listing` 中也一併拿掉(名稱、說明、digest);attachment 行的 uuid、session id、cwd、分支換成假值。
- **測試裡的改動**(錄不到的情境):停用 plugin(作者 Mac 上全部啟用)——測試把 `frontend-design` 在使用者層設成 `false`、
  `webwright` 在專案層 `settings.local.json` 設成 `false`;專案層 skills／commands(作者 Mac 沒有)寫在測試裡;
  `skill_listing` 的增量行(`isInitial: false`)以錄製行為底改動。
- 存檔後以 `grep` 確認沒有真實的使用者名稱、主機名或專案名。
