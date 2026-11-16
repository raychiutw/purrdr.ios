# Allymote 伺服器如何與 herdr 溝通(截至 2026-11-16)

> 目的:補上 `docs/research/allymote-https-connection.md` 標為【未查得】的部分,也就是 Allymote 電腦端伺服器怎麼跟 herdr 溝通,並整理它對手機端的傳輸方式,供 Purrdr 設計主機服務時比較。
>
> 標記:**【文件】** herdr 官方文件；**【原始碼】** herdr 官方原始碼(路線 1),或 Allymote 散布檔(只出現在路線 3);**【實測】** 本機唯讀觀察；**【推論】** 由前述推得、未直接驗證；**【未查得】** 找不到來源。
>
> 版本:herdr repo `herdrdev/herdr` commit `ee5bfb5`(2026-10-29,即 v0.9.5,與 `herdrchat-behavior-spec.md` 相同);文件取 `docs/versions/0.9.5/website/src/content/docs/`(下稱 `docs/`)。本機 herdr CLI 0.9.5,但正在跑的 herdr server 是 0.9.4(見 §2.1)。Allymote 0.2.45(`package.json` 的 name 仍是 `herdr-remote`)。

## 摘要

1. **介面**:Allymote 伺服器**直接連 herdr 的本機 socket**(Windows 是 named pipe `\\.\pipe\<%APPDATA%\herdr\herdr.sock 的完整路徑>`,Unix 是 `~/.config/herdr/herdr.sock`),走 herdr 官方的 NDJSON socket API,**每個請求開一條新連線、讀到第一行回應就關閉**。不經過 `herdr remote-api-bridge`,執行期間也不 spawn `herdr` CLI。【原始碼】【實測】
2. **狀態**:每 1 秒呼叫一次 `session.snapshot` 輪詢,在伺服器內做差異比對,再推給手機。**沒有使用 `events.subscribe`**。【原始碼】
3. **對話內容**:不是 herdr 提供的。`herdr integration install claude|codex` 只在 Claude Code／Codex 安裝 `SessionStart` hook,hook 呼叫 `herdr pane report-agent-session`,把 session id 與對話紀錄路徑告訴 herdr。Allymote 從 snapshot 的 `agent_session` 取得 id 或路徑,**自己去讀** `~/.claude/projects/**.jsonl`、`~/.codex/sessions/**`,每 500 ms 檢查一次,解析後推送。【文件】【原始碼】【實測】
4. **輸入**:文字用 `pane.send_text`(切成每段 8192 字元),按鍵用 `pane.send_keys`。回答 agent 的選擇題時,先 `pane.read` 讀畫面、解析出選項,再算出要按的方向鍵與 Enter 送出;送出前會比對畫面指紋,避免答錯題。【原始碼】
5. **終端機畫面**:**不是 PTY,也不是 `terminal session control`**。做法是每 150 ms 輪詢 `pane.read`(`source: "visible"`、`format: "ansi"`),畫面雜湊改變就把整個畫面當成一個 frame 推出去。【原始碼】
6. **對手機的傳輸**:一個 HTTP 伺服器(127.0.0.1:8765)。即時資料全部走**單一 WebSocket `/ws`**,收發以 `type` 區分的 JSON 訊息,請求用 `requestId` 對應回應,伺服器每 30 秒送一次 ping。配對、上傳、下載、`/api/me` 則是一般 HTTPS 端點。沒有 SSE。【原始碼】
7. **對 Purrdr 的含意**:主機服務應該依 herdr 官方文件,直接連本機 socket。狀態改用 `session.snapshot` 加 `events.subscribe` 的對帳模式，不要輪詢。終端機用 `terminal session control/observe`,送 prompt 優先用 `agent.prompt`,對話內容仍得自己讀對話紀錄檔(用 `agent_session` 定位)。

---

## 1. 路線 1:herdr 官方介面(一手資料)

### 1.1 官方位置

- 官方 repo:`https://github.com/herdrdev/herdr`(描述 "the runtime your coding agents live on",homepage `https://herdr.dev`,預設分支 `master`,最新 release v0.9.5,2026-10-14)。【實測】`gh search repos herdr`、`gh api repos/herdrdev/herdr`
- 同組織還有 `herdrdev/herdr-app`(桌面 app)與 `herdrdev/herdr-core`。本機也有在跑(§2.1),但跟 Allymote 無關。

### 1.2 三種整合層級

- herdr 官方列出三層:Agent skill(讓 pane 內的 agent 使用 herdr)、CLI wrappers(shell 腳本與人工除錯)、**Raw socket API(自製工具、協定 client、事件訂閱者)**,並說明「三層共用同一個控制面」。【文件】`docs/socket-api.mdx:10-18`
- 安裝的 CLI 可以印出自帶的 JSON Schema:`herdr api schema --json`,涵蓋請求、回應、錯誤與事件。【文件】`docs/socket-api.mdx:20-34`
- 【推論】Purrdr 主機服務屬於「協定 client」,官方建議用 raw socket API。

### 1.3 Socket 傳輸與路徑

- **NDJSON over 本機 socket**:Unix 用 Unix domain socket,Windows 用 named pipe。一行一個請求 `{"id","method","params"}`,回應帶相同 `id`,錯誤也會回帶 `id`。訂閱類請求在第一個回應之後**保持連線**。【文件】`docs/socket-api.mdx:608-630`
- 路徑:預設 `~/.config/herdr/herdr.sock`,具名 session 是 `~/.config/herdr/sessions/<name>/herdr.sock`。解析順序:`--session` → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → 預設。raw socket client 要自己處理各平台原生的 socket 形式。【文件】`docs/socket-api.mdx:632-654`
- Windows 的 pipe 名稱是 `\\.\pipe\` 加上 socket 路徑字串。【原始碼】herdr `src/platform/windows.rs:167-179`(`connect_local_stream_with_timeout`)
- `herdr remote-api-bridge`:連到目前 session 的 API socket,把 stdin／stdout 對接到 socket。`--check` 印出 `herdr-api-bridge-v1`。【原始碼】herdr `src/remote.rs:15-38`。它是給「透過 SSH 在遠端執行」用的;本機程式可以直接連 socket,不需要它。【推論】
- 協定穩定性:JSON API client 應**忽略未知欄位**,並把不支援的 method 當一般錯誤處理。數字編號的二進位協定只給同一份安裝內部使用(direct attach、live handoff)。【文件】`docs/socket-api.mdx:942-960`

### 1.4 與 Purrdr 相關的 method(節錄)

出處:`docs/socket-api.mdx:93-133` method 表與說明。【文件】

| 用途 | method |
|---|---|
| 健康檢查、版本能力 | `ping` |
| 一次性 bootstrap 快照 | `session.snapshot`(含版本與協定、焦點、workspace／tab／pane／layout／agent 紀錄;**不是訂閱**) |
| 列表與查詢 | `workspace.list/get`、`tab.list/get`、`pane.list/get`、`agent.list/get` |
| 讀畫面 | `pane.read`(source:`visible`、`recent`、`recent-unwrapped`、`detection`;format `text|ansi`,見 `docs/cli-reference.mdx:246-251`)、`agent.read` |
| 輸入 | `pane.send_text`、`pane.send_keys`、`pane.send_input`、`agent.send_keys`、`agent.prompt`(可帶 `wait`,把送出與等待合成一個請求;agent 已經 `blocked` 時回 `agent_blocked`,不送輸入) |
| 等待 | `agent.wait`(由伺服器端事件驅動)、`pane.wait_for_output`、`events.wait` |
| 事件 | `events.subscribe` |
| 建立與管理 | `workspace.create/rename/move/close`、`tab.create/close`、`pane.split/close`、`worktree.list/create/open/remove`、`agent.start` |
| 整合 | `integration.install`、`integration.uninstall` |
| 回報 | `pane.report_agent`、`pane.report_agent_session`、`pane.report_metadata` |

### 1.5 事件訂閱(`events.subscribe`)

- 第一個回應是確認,之後每行是推送的事件。只要有任何一個 pane 不存在,整個請求就會被拒絕並關閉連線。訂閱不會回放之前的事件。【文件】`docs/socket-api.mdx:773-792`
- 事件歷史不持久。訂閱者落後時,伺服器回 `error.code: "events_lost"` 並關閉該連線。**官方建議的對帳流程**:重新訂閱，等到 `subscription_started`,同時在另一條連線讀 `session.snapshot`,以 snapshot 取代快取，把事件當成「失效通知」再讀一次權威資料;不要把事件直接套在 snapshot 上。【文件】`docs/socket-api.mdx:794-815`
- 事件類別:workspace(`workspace.created/updated/renamed/moved/closed/focused`…)、tab、pane(`pane.created/updated/closed/exited/agent_detected/output_matched/agent_status_changed/scroll_changed`…)、`layout.updated`、worktree。【文件】`docs/socket-api.mdx:817-840`

### 1.6 `herdr integration install claude|codex` 安裝了什麼

- 目的:「每個整合都告訴 herdr agent 在哪個 session,讓 herdr 在伺服器重啟後能恢復」。Claude Code 與 Codex **不回報狀態**,狀態仍由 herdr 的畫面偵測(screen manifest)決定;只有 Pi、OMP、Kimi、OpenCode、Kilo、MastraCode 的整合會回報狀態。【文件】`docs/integrations.mdx:58-64`
- **Claude Code**:使用 `~/.claude`(或 `CLAUDE_CONFIG_DIR`),目錄必須已存在。寫入 `hooks/herdr-agent-state.sh`(Windows 是 `.ps1`),並在 `settings.json` 加上 hook。v10 起 matcher 只比對 `SessionStart` 的 `startup|resume|clear|compact|fork`。解除安裝會移除 hook 與腳本。【文件】`docs/integrations.mdx:104-116`
- hook 內容:只有在 `HERDR_ENV=1` 且有 `HERDR_PANE_ID` 時才動作,從 stdin 讀 Claude 的 hook JSON,執行 `herdr pane report-agent-session <pane> --source herdr:claude --agent claude --seq <ms> --agent-session-id <session_id> [--agent-session-path <transcript_path>] [--session-start-source <source>]`。【原始碼】herdr `src/integration/assets/claude/herdr-agent-state.ps1`(v11)
- **Codex**:使用 `~/.codex`(或 `CODEX_HOME`)。寫入 `herdr-agent-state.sh`,更新 `hooks.json`,並確保 `config.toml` 有 `[features] hooks = true`。解除安裝不會還原 `config.toml`。【文件】`docs/integrations.mdx:118-128`。上游 v10 的腳本只處理 `SessionStart`,而且要求要有 `transcript_path`。【原始碼】`src/integration/assets/codex/herdr-agent-state.ps1:23-27`
- 回報的資料會出現在 `pane.get/list`、`agent.get/list` 的唯讀欄位 `agent_session`(`source`、`agent`、`kind`、`value`)。【文件】`docs/socket-api.mdx:708-720`、`docs/cli-reference.mdx:284-301`
- 【推論】herdr **不提供對話內容 API**。整合只讓「pane ↔ agent 原生 session id／對話紀錄路徑」的對應變成可查詢；對話內容仍要由 client 自己讀 agent 的對話紀錄檔(與 `GLOSSARY.md`「對話紀錄」定義一致)。

### 1.7 終端機:direct attach 與 terminal session

- `herdr terminal attach` 與 `herdr agent attach` 是 direct attach,串流 ANSI frame,需要 TTY;同一時間只有一個可寫 client(`--takeover` 可以搶)。【文件】`docs/persistence-remote.mdx:120-138`
- **給第三方 bridge 的介面**:【文件】`docs/persistence-remote.mdx:140-162`、`docs/cli-reference.mdx:372-404`
  - `herdr terminal session observe <target> [--cols N] [--rows N]`:唯讀。輸出 NDJSON `terminal.frame`(ANSI bytes 以 base64 編碼),結束時輸出 `terminal.closed`;可以有多個 observer。
  - `herdr terminal session control <target> [--takeover] [--cols N] [--rows N]`:可寫。輸出格式相同,stdin 讀 NDJSON 指令 `terminal.input`(文字或 base64 bytes)、`terminal.resize`、`terminal.scroll`、`terminal.mouse`、`terminal.release`;同時只有一個 controller。
  - Linux／macOS 上，如果 observer 的 socket 寫入 30 秒沒有進展就會被斷線，而且可能沒有 `terminal.closed`。
- 這些是 CLI 子指令(對應內部二進位協定),**不是** JSON socket method。【推論】依據:socket method 表(§1.4)沒有 terminal session 相關 method。

---

## 2. 路線 2:本機行為觀察(唯讀)

只列行程、埠、pipe 名稱、檔名與目錄結構，以及 hook 設定中與 herdr 相關的條目。沒有讀 `auth.json`、`vapid.json`、`server.log`、`audit.log`、`activity.json` 的內容，也沒有啟動或停止任何程式，沒有送出網路請求。

### 2.1 行程與埠【實測】

`Get-CimInstance Win32_Process`、`Get-NetTCPConnection -OwningProcess`:

- Allymote:`powershell.exe -NoProfile -WindowStyle Hidden -Command "& '<LOCALAPPDATA>\allymote\runtime\node-v24.22.2-win-x64\node.exe' '<LOCALAPPDATA>\allymote\run.mjs' start ..."`(排程工作啟動),子行程 `node.exe ...\run.mjs start`(PID 50012,2026-11-16 10:20 啟動)。
- PID 50012 **只聽 `127.0.0.1:8765`**,沒有其他 TCP 連線(取樣當下)。
- 以 250 ms 間隔取樣 10 秒，期間 node 行程**沒有任何子行程**。也就是說，閒置時不會 spawn `herdr`。有手機連線時的情況未觀察。
- herdr:`herdr.exe` → `herdr.exe server`(**0.9.4**,`~/.herdr/packages/standalone/releases/0.9.4-.../`),底下有 ConPTY(`OpenConsole.exe --headless`)與 pane 內的 `powershell.exe`。PATH 上的 `herdr --version` 是 0.9.5,表示**伺服器還沒有 handoff 到新版**。
- 另外有 `herdr-app.exe` 與 `herdr-core.exe serve/connect`(herdr 桌面 app,與 Allymote 無關)。

### 2.2 Named pipe【實測】

`[IO.Directory]::GetFiles('\\.\pipe\')` 篩選結果:

- `\\.\pipe\C:\Users\<user>\AppData\Roaming\herdr\herdr.sock`(API socket)
- `\\.\pipe\C:\Users\<user>\AppData\Roaming\herdr\herdr-client.sock`
- `\\.\pipe\herdr-core-<user>-default.sock`(herdr-core)

`%APPDATA%\herdr\` 裡另有同名的 25 bytes `herdr.sock`、`herdr-client.sock` 檔案。與 §1.3 的「pipe 名稱 = `\\.\pipe\` + socket 路徑」一致。沒有看到 Allymote 自己的 pipe。

### 2.3 目錄結構(只看檔名)【實測】

- `%LOCALAPPDATA%\allymote\`:`run.mjs`、`bin\allymote.cmd`、`runtime\node-v24.22.2-win-x64\`、`app\`(`package.json`、`bin\{allymote,herdr-remote,stockrider}.cmd`、`dist\cli.js`(440 KB)、`dist\web\`(PWA:`index.html`、`sw.js`、`manifest.webmanifest`、`assets\index-*.js`)、`scripts\`)。
- `~\.allymote\`:`auth.json`、`audit.log`、`server.log`、`activity.json`、`open-agents.json`、`tailnet-host`、`update.json`、`vapid.json`、`uploads\`、`handoff\`、`discarded\`。
- `%APPDATA%\herdr\`:`config.toml`、`session.json`、`session-snapshots\`、`plugins.json`、`plugins\`、`herdr-server.log`、`herdr-client.log`、`release-notes.json`。
- herdr plugin:`plugins.json` 只有一個 `heeler`(來源 GitHub `ZingerLittleBee/Heeler`,另一個行動 app 的配對 plugin)。**Allymote 沒有安裝 herdr plugin**。

### 2.4 integration 在 Claude／Codex 留下的設定【實測】

- `~/.claude/hooks/herdr-agent-state.ps1`(標頭 `HERDR_INTEGRATION_ID=claude`、`VERSION=10`),內容呼叫 `report-agent-session`,帶 `--agent-session-id`,有 `transcript_path` 時加 `--agent-session-path`。
- `~/.claude/settings.json` 中與 herdr 相關的只有一筆:`SessionStart`,matcher `^(startup|resume|clear|compact|fork)$`,執行 `powershell -NoProfile -ExecutionPolicy Bypass -File "...\.claude\hooks\herdr-agent-state.ps1" session`。
- `~/.codex/herdr-agent-state.ps1`(`VERSION=9`)、`~/.codex/hooks.json` 有 `SessionStart`(`session`)、`UserPromptSubmit`(`working`)、`Stop` 與 `Interrupt`(`idle`)四個 hook,`config.toml` 有 `[features] hooks = true`。v9 腳本對非 session 動作會呼叫 `report-agent --state`。這和上游 v10「只處理 SessionStart」不同,原因是本機裝的是較舊的整合版本(§1.6)。【推論】
- 這些檔案由 Allymote 安裝腳本呼叫的 `herdr integration install claude|codex` 產生(§3.1),寫入的是 **herdr 官方的 hook**,不是 Allymote 自己的。

---

## 3. 路線 3:閱讀反組譯／美化後的 Allymote 散布檔

> **警語：本節來自閱讀反組譯／美化後的 Allymote 散布檔，使用者已知悉並授權；違背 ADR-0001 clean-room 精神,Purrdr 實作應以路線 1 的 herdr 官方資料為準。**
>
> 方法:把 `%LOCALAPPDATA%\allymote\app\dist\cli.js` 與 `dist\web\assets\index-FVlK-dJs.js` 複製到 scratchpad 新目錄，用 prettier 3.3.3 美化(`cli.pretty.js`,23,585 行)。下文行號以這份美化副本為準。沒有執行任何 Allymote 程式碼，沒有修改原安裝檔。不引用程式碼段落；認證與配對只描述概念。

### 3.1 herdr 整合在安裝時完成

- 安裝腳本第 242–245 行印出「Letting herdr see what Claude and Codex are doing」,然後執行 `herdr integration install claude` 與 `herdr integration install codex`。若沒有 herdr 就中止，並提示官方安裝指令(第 20 行)。【原始碼】`app\scripts\windows-install.ps1`
- 伺服器執行期間**沒有**呼叫 `herdr` CLI(搜尋不到 `execFile/spawn` 呼叫 herdr)。唯一的 spawn 是「保持喚醒」:有 agent 在 `working` 時啟動作業系統的防睡眠程式。【原始碼】`cli.pretty.js:14140-14185`

### 3.2 herdr 介面:直接連 socket、一次一個請求

- socket 路徑:Windows 是 `\\.\pipe\` + (`HERDR_SOCKET_PATH` 或 `%APPDATA%\herdr\herdr.sock`),其他平台是 `HERDR_SOCKET_PATH` 或 `~/.config/herdr/herdr.sock`。**沒有處理 `HERDR_SESSION`／具名 session**。【原始碼】`cli.pretty.js:15772-15777`
- 每次呼叫都用 Node `net.connect` 開新連線，送一行 `{id: randomUUID, method, params}`,收到第一個換行就解析並關閉。一般請求 4 秒逾時，慢的請求(`agent.start`、`worktree.open`)40 秒。`pane_not_found` 會另外對應成專用錯誤碼。【原始碼】`cli.pretty.js:15778-15847`、`15921-15927`
- 用到的 herdr method:`session.snapshot`、`workspace.list/create/rename/move/close`、`tab.create/rename/close`、`pane.focus/split/close/read/process_info/send_text/send_keys`、`worktree.list/create/open`、`agent.start`。【原始碼】`cli.pretty.js:15928-16110`
- 沒有使用:`events.subscribe`、`agent.prompt`、`agent.wait`、`remote-api-bridge`、`terminal session control/observe`(整份檔案搜尋不到)。【原始碼】
- 健康檢查:定期檢查 herdr 能否回應、`https://<tailnet 主機>/api/me` 能否連上,連續兩次失敗就推播「herdr／tailscale serve 停了」。【原始碼】`cli.pretty.js:15545-15600`、`14853-14882`

### 3.3 狀態：輪詢 `session.snapshot`

- 從 snapshot 的 panes 對應出 agent 清單，欄位概念:paneId、workspaceId、tabId、agent、status(`idle|working|blocked|done|unknown`,其他值一律視為 `unknown`)、title(取 `terminal_title_stripped`,去掉開頭的 spinner)、cwd、session(取自 `agent_session`,`kind` 為 `id` 或 `path`,而且 agent 名稱必須一致)、workspace／tab 的標籤與編號。【原始碼】`cli.pretty.js:15848-15939`
- 預設每 1000 ms 輪詢一次。第一次或從中斷恢復時廣播完整的 `agents`,之後只廣播有變動的 `agent_update`(含 `removed`)。伺服器自己記錄每個 pane 的狀態起始時間(`since`)。herdr 無法連線時廣播 `herdr_unavailable`,並以指數退避重試，最長 10 秒。【原始碼】`cli.pretty.js:10246-10372`

### 3.4 對話內容：自己讀對話紀錄檔

- 對話紀錄根目錄:Claude 是 `CLAUDE_CONFIG_DIR`(可以有多個)或 `~/.claude` 底下的 `projects`;Codex 是 `CODEX_HOME` 或 `~/.codex` 底下的 `sessions`。另外支援 grok 與 agy。【原始碼】`cli.pretty.js:9541-9625`
- 依 `agent_session` 定位檔案:`kind: "id"` 就在根目錄下用 id 找 `.jsonl`,`kind: "path"` 就直接使用該路徑(仍限制在根目錄內)。【原始碼】`cli.pretty.js:9905-9915`
- 手機送 `chat_subscribe` 後，伺服器對該 pane 每 500 ms 檢查檔案大小與 mtime。有變化就重新解析(上限 16 MB),和上次結果比對：只有新增的部分送 `chat_append`,有改寫就送完整視窗 `chat`(最多 150 筆，有 `hasOlder`)。往前翻頁用 `chat_older`。【原始碼】`cli.pretty.js:9840-9904`、`10095-10144`
- 同一份解析結果也拿來判斷「Claude 正在等 ExitPlanMode／AskUserQuestion 的回應」,用來顯示計畫或選擇題。【原始碼】`cli.pretty.js:9973-9990`

### 3.5 輸入與按鍵

- `text`:驗證裝置不是唯讀後，用 `pane.send_text` 分段送出(每段 8192 字元，不切斷 UTF-16 代理對)。帶 `enter` 時再補一次 `pane.send_keys`。`keys`:`pane.send_keys`(`esc` 轉成 `Escape`)。【原始碼】`cli.pretty.js:15863-15875`、`16096-16110`、`21725-21780`
- **防止送錯對象**:訊息可以附上手機看到的 `session`(kind/value)。送出前重新讀 snapshot,如果該 pane 的 `agent_session` 已經不同，就回 `pane_changed`,不送任何東西。同一個 pane 的操作會排隊依序執行。【原始碼】`cli.pretty.js:18706-18714`、`21734-21741`
- **回答選擇題**:`prompt_read` 讀 `pane.read visible`,解析出畫面上的問題、選項與目前選取項，計算指紋(若有待確認的計畫，一併回傳計畫雜湊)。`prompt_answer` 送出前重新讀畫面，指紋或計畫雜湊不同就回 `prompt_changed`;相同才把「從目前選取項移到目標項」換算成按鍵送出。【原始碼】`cli.pretty.js:19055-19140`
- 每次寫入操作都會寫稽核紀錄，只記錄時間、裝置 id、pane、種類與**長度**,不記錄內容。【原始碼】`cli.pretty.js:21764-21770`、`18866-18873`

### 3.6 終端機畫面：輪詢 `pane.read`

- 手機送 `subscribe {paneId}`,伺服器為該 pane 建立 watch,預設**每 150 ms** 呼叫 `pane.read`(`source: "visible"`、`format: "ansi"`)。內容的 sha1 改變時，序號加一，推出 `screen` frame(整個畫面的 ANSI 字串、依內容推算的 cols／rows、seq)。多個 client 共用同一個 watch,新加入的 client 會立刻收到最後一個 frame。pane 消失時送 `pane_closed`。【原始碼】`cli.pretty.js:10226-10240`、`10287-10311`、`10373-10399`
- shell 類 pane 的捲動歷史用 `history` 訊息處理(`pane.read source: "recent"`,ansi 格式);agent pane 會被引導改用聊天畫面。【原始碼】`cli.pretty.js:15990-16001`、`18831-18853`
- 結論：既不是 PTY,也不是 herdr 的 `terminal session control/observe`,而是**整個畫面的快照輪詢**。輸入一律走 `pane.send_text/send_keys`。

### 3.7 伺服器架構與手機傳輸(概念層級)

- **單一 Node 行程**:內嵌 `ws` WebSocket 函式庫的 `node:http` 伺服器，聽 127.0.0.1:8765(由 `tailscale serve` 對外提供 TLS,見前一份報告)。【原始碼】`cli.pretty.js:18612-18690`
- **HTTP 端點**:`POST /pair`(配對)、`POST /api/upload` 與 `GET /api/upload/<id>`、`GET /api/download/<id>`、`POST /api/shortcut`、`POST /api/peer/handoff`(跨電腦交接)、`GET /api/me`(回傳裝置、主機、build、協定版本 `1` 與 feature 清單，例如 `request_ids`、`session_checks`、`text_enter`)。PWA 靜態檔也由同一個伺服器提供。【原始碼】`cli.pretty.js:18620-18666`、`11274-11285`
- **即時通道**:只有 `GET /ws` 可以升級成 WebSocket。升級前檢查 Origin(跨來源一律 403)與裝置憑證(Cookie 或其他標頭；細節不記錄),憑證無效就 401。每則訊息處理前都會重新驗證裝置，被撤銷就以 close code 4401 關閉。伺服器每 30 秒 ping,沒收到 pong 就 terminate。【原始碼】`cli.pretty.js:18058-18073`、`18680-18728`
- **訊息模型**:所有訊息都是帶 `type` 的 JSON。客戶端請求可以帶 `requestId`(1–32 字元),回應與 `error` 會帶回同一個 `requestId`;伺服器主動推送的訊息不帶。錯誤是 `{type:"error", code, message, paneId?, requestId?}`。【原始碼】`cli.pretty.js:18729-18772`、`11285-11290`
- **訊息類別(概念分組)**,完整 `type` 清單約 150 種:【原始碼】
  - 訂閱與推送:`agents`／`agent_update`、`subscribe`／`screen`、`chat_subscribe`／`chat`／`chat_append`／`chat_older`、`activity`、`conn`
  - 輸入:`text`、`keys`、`prompt_read`／`prompt`／`prompt_answer`、`input_take`、`peek`、`screen_shot`
  - herdr 結構操作:`launch`、`agent_start`、`pane_split`、`pane_close`、`close_tab`、`close_workspace`、`rename`、`workspace_move`、`focus_pane`、worktree 相關
  - 主機功能(超出 herdr 的部分):git(`changes`、`git_commit`、`git_discard_hunk`、`commit_log`、`pr_create`、`pr_merge`)、檔案(`files_find`、`file_write`、`file_download`)、剪貼簿、`run_command`、排程、待辦、佇列、預覽埠轉送、「race」worktree、session 恢復、`token_usage`、Web Push 訂閱(`push_*`)、裝置管理(`devices_list`、`device_revoke`)、稽核查詢(`audit_list`)
  - 心跳:`ping`／`pong`
- **唯讀裝置**:在每種寫入類訊息的處理裡逐一檢查，回 `forbidden`。【原始碼】例如 `cli.pretty.js:18857-18863`、`19085-19091`、`21725-21732`
- 沒有 SSE(檔案中沒有 `text/event-stream`、`EventSource`)。PWA 用 `new WebSocket(<origin 換成 ws(s)>/ws)`。【原始碼】`web.pretty.js:116`、`3501`

---

## 4. 對 Purrdr 主機服務設計的含意

以路線 1 為依據，路線 2／3 只用來交叉驗證「這樣做可行」或「Allymote 的做法有什麼代價」。

| 面向 | herdr 官方建議(路線 1) | Allymote 實際做法(路線 3) | Purrdr 建議 |
|---|---|---|---|
| 連 herdr | raw socket API 給協定 client 用 | 直接連 socket,一次一個請求 | **直接連本機 socket**(Unix socket／`\\.\pipe\<path>`),支援 `--session`／`HERDR_SOCKET_PATH`／`HERDR_SESSION` 解析順序。走 SSH 的連線方式仍用 `remote-api-bridge`(ADR-0002 不變) |
| 版本與能力 | `ping`、`herdr api schema --json`,忽略未知欄位 | 未用 ping 協商 | 啟動時 `ping` 取得協定與能力，不支援的 method 降級處理 |
| 狀態 | `events.subscribe` + `session.snapshot` 對帳,`events_lost` 時重建 | 每秒輪詢 snapshot 並自己做 diff | 依官方對帳流程。事件只當失效通知，必要時再讀權威資料。輪詢只當後備 |
| 對話內容 | herdr 不提供，只提供 `agent_session` | 依 `agent_session` 讀 `~/.claude/projects`、`~/.codex/sessions`,500 ms 輪詢 | 同樣依 `agent_session` 定位。讀檔路徑限制在已知根目錄內。可改用檔案監看,輪詢只當後備 |
| 送 prompt | `agent.prompt`(可帶 wait,`blocked` 時拒送) | `pane.send_text` 加 Enter | 一般 prompt 優先用 `agent.prompt`;其他情況用 `pane.send_text/keys` |
| 回答選擇題 | `agent.read`／`pane.read` 加 `send_keys` | 讀畫面、指紋比對後送方向鍵 | 「送出前比對畫面或 session,不一致就不送」是好的防呆，值得自行設計(行為規格已有類似規則) |
| 終端機 | `terminal session control/observe`(NDJSON,增量 ANSI) | 150 ms 輪詢整個畫面 | 維持 ADR-0005 的 `control`。輪詢整個畫面頻寬大、延遲高，不支援捲動與滑鼠 |
| 整合 | `herdr integration install claude|codex` 只裝 SessionStart hook | 安裝時執行 | 同樣只呼叫官方 `herdr integration install`,不自己寫 hook。先用 `herdr integration status` 檢查 |
| 對手機傳輸 | — | 單一 WSS `/ws`、`type` + `requestId`、30 秒 ping;上傳下載用 HTTPS | 單一 WSS 加上帶版本的自訂協定，與前一份報告選項 A 一致。上傳下載另走 HTTPS |

補充:

- **具名 session**:Allymote 只認預設 socket。Purrdr 應該支援 `HERDR_SESSION`,至少要能讓使用者選擇。【推論】
- **伺服器版本落差**:本機 CLI 0.9.5,但 server 是 0.9.4。直接連 socket 時，對話對象是 server 的版本，能力判斷要以 `ping` 結果為準，不是 CLI 版本。【實測】【推論】
- **範圍**:Allymote 的 WebSocket 協定有一大半是 herdr 以外的功能(git、檔案、PR、預覽、排程),每一項都是主機端的攻擊面。前一份報告建議「窄 API」,這份觀察支持這個方向。【推論】

## 5. 未決問題

1. `terminal session control` 在 Windows 與 herdr 0.9.4／0.9.5 server 上的實際行為(ADR-0005 的 spike 仍待做)。Allymote 沒有使用它，所以無法拿來交叉驗證。【未查得】
2. 由主機服務直接連 socket 時，要用 CLI 子行程(`herdr terminal session control`)還是有 socket 層等價介面？官方只文件化了 CLI 形式。【未查得】**已定案**:主機服務以子行程執行 CLI(ADR-0010)。
3. `agent_session.kind` 的可能值:文件範例只有 `id`,Allymote 同時處理 `id` 與 `path`;Claude hook 會帶 `--agent-session-path`。`path` 什麼時候會出現，要用 `herdr agent list --json` 實測。【未查得】
4. 本機 Codex 整合是 v9(有 state hook),上游是 v10(只有 SessionStart)。升級整合會不會影響狀態判斷，要看 `herdr integration status`。【未查得】
5. 有手機連線時 Allymote 的實際請求頻率(本次只觀察閒置狀態)。【未查得】
6. `events.subscribe` 多條訂閱與 snapshot 對帳在 Windows named pipe 上的穩定性(`herdrchat-behavior-spec.md` 記錄過 0.9.2 修正的 `events_lost` 問題)。【未查得】

## 6. 來源

| 編號 | 來源 | 用途 |
|---|---|---|
| H1 | https://github.com/herdrdev/herdr(commit `ee5bfb5`,v0.9.5) | 官方 repo |
| H2 | `docs/versions/0.9.5/website/src/content/docs/socket-api.mdx`:10-34、93-133、608-654、708-720、773-840、942-960 | 整合層級、method 表、傳輸、路徑、`agent_session`、事件、穩定性 |
| H3 | 同目錄 `integrations.mdx`:58-64、104-128 | integration 目的、Claude／Codex 安裝內容 |
| H4 | 同目錄 `persistence-remote.mdx`:120-162 | direct attach、terminal session observe／control |
| H5 | 同目錄 `cli-reference.mdx`:246-251、284-301、372-404 | `pane read --format ansi`、`report-agent-session`、terminal session |
| H6 | herdr `src/remote.rs:15-38`、`src/platform/windows.rs:167-179` | `remote-api-bridge`、Windows pipe 名稱 |
| H7 | herdr `src/integration/assets/claude/herdr-agent-state.ps1`、`assets/codex/herdr-agent-state.ps1` | hook 實際呼叫的 CLI |
| L1 | 本機 `Get-CimInstance Win32_Process`、`Get-NetTCPConnection`、`\\.\pipe\` 列舉、子行程取樣(2026-11-16) | 行程、埠、pipe |
| L2 | 本機 `~/.allymote`、`%LOCALAPPDATA%\allymote`、`%APPDATA%\herdr` 檔名；`plugins.json` 的 plugin 清單 | 目錄結構、沒有 Allymote plugin |
| L3 | 本機 `~/.claude/settings.json`(只看 herdr 條目)、`~/.claude/hooks/herdr-agent-state.ps1`、`~/.codex/hooks.json`、`~/.codex/config.toml`、`~/.codex/herdr-agent-state.ps1` | integration 實際安裝內容 |
| A1 | `%LOCALAPPDATA%\allymote\app\scripts\windows-install.ps1`:20、242-245 | 安裝時執行 integration |
| A2 | Allymote 0.2.45 `dist/cli.js`、`dist/web/assets/index-FVlK-dJs.js` 的 prettier 美化副本(只在 scratchpad,行號見 §3) | 路線 3 全部主張 |
| P1 | `docs/research/allymote-https-connection.md`、`docs/research/herdrchat-behavior-spec.md`、`docs/adr/0001`、`0002`、`0005`、`GLOSSARY.md` | 前提與約束 |
