# Antigravity CLI (`agy`) 實測與官方文件查證報告

> **驗證環境**：`agy 1.5.14`（`/Users/<user>/.local/bin/agy`）、`herdr 0.9.5`（`/opt/homebrew/bin/herdr`）、macOS（`HERDR_ENV=1`）。
> **去識別化說明**：以下所有路徑中的使用者帳號皆改為 `<user>`，session / conversation ID 皆改為 `<conversation-id>` 或假 UUID（`00000000-0000-0000-0000-000000000000`），不含任何帳號、權杖或個人資料。
> **查證原則**：每項均標示資料來源（實測指令輸出、檔案路徑、內建技能文件或官方網站文件）；無法直接確認的細節均明確標註「不確定」。

---

## 1. herdr 怎麼辨認 `agy`

### 實測結果
- **`agent` 欄位實際值**：`"agy"`（並非 `"antigravity"`）。
- **`agent_session` 欄位**：回報的是 **`id`**（非檔案路徑），值為 UUID v4 格式，來源標記為 `"herdr:antigravity_cli"`。
- **啟動與整合識別名**：
  - `herdr agent start --kind` 使用 `agy`。
  - `herdr integration install` 使用 `antigravity-cli`（安裝 hook 至 `/Users/<user>/.gemini/config/hooks/herdr-agent-state.sh`，並寫入 `/Users/<user>/.gemini/config/hooks.json` 的 `PreInvocation` 事件）。

### 來源與輸出摘錄
1. **實測指令**：`herdr agent list`（於 `herdr 0.9.5` 執行，節錄本 pane 物件並已去識別化）：
   ```json
   {
     "agent": "agy",
     "agent_session": {
       "agent": "agy",
       "kind": "id",
       "source": "herdr:antigravity_cli",
       "value": "00000000-0000-0000-0000-000000000000"
     },
     "agent_status": "working",
     "cwd": "/Users/<user>/Projects",
     "focused": false,
     "foreground_cwd": "/Users/<user>/Projects",
     "pane_id": "w1:pE",
     "tab_id": "w1:tE",
     "workspace_id": "w1"
   }
   ```
2. **實測指令**：`herdr agent start --help` 輸出摘錄：
   ```text
   --kind <KIND>
       Supported agent kind and canonical executable
       [possible values: pi, claude, codex, gemini, cursor, devin, agy, ...]
   ```
3. **實測檔案**：`/Users/<user>/.gemini/config/hooks.json`（由 `herdr integration install antigravity-cli` 產生，去識別化）：
   ```json
   {
     "herdr": {
       "PreInvocation": [
         {
           "command": "bash '/Users/<user>/.gemini/config/hooks/herdr-agent-state.sh' session",
           "timeout": 10,
           "type": "command"
         }
       ]
     }
   }
   ```
4. **補充備註**（來源：實測 `herdr --skill`）：
   - Herdr 內建 skill 特別註明：`Antigravity and Grok can be idle while background tasks or subagents keep running, so a settled-state wait is not proof those jobs have finished.`

---

## 2. 對話紀錄（Transcript）

### 存放路徑與檔名規則
- **目錄結構**：`~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/`
  - `<conversation-id>` 為 UUID v4。
  - `antigravity-cli/` 是 CLI 專用的 app data 目錄名（內建文件 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md` 註明：CLI 為 `antigravity-cli/`、Antigravity 2.0 App 為 `antigravity/`、IDE 為 `antigravity-ide/`）。
- **檔案清單（實測 `ls -la`）**：
  - `transcript.jsonl`：精簡版對話紀錄（過長欄位會截斷並附帶 `"truncated_fields": ["content"]`）。
  - `transcript_full.jsonl`：完整未截斷版對話紀錄。
  - `chunks/transcript/00000000.jsonl`, `00000001.jsonl`, ...：約 100 KiB（102,400 bytes）切塊的精簡版分片。
  - `chunks/transcript_full/00000000.jsonl`, `00000001.jsonl`, ...：約 100 KiB 切塊的完整版分片。
- **同目錄其他子資料夾**：`~/.gemini/antigravity-cli/brain/<conversation-id>/` 下尚有 `.user_uploaded/`、`scratch/`，以及 Markdown artifacts（若有產生）。

### 格式與單行範例
- **格式**：**JSONL（Newline-delimited JSON）**，每行代表一個 step（`step_index` 從 `0` 遞增）。
- **實測統計（以 Python 掃描本對話完整 `transcript.jsonl` 與 `transcript_full.jsonl`）**：
  - 出現過的 `type`：`USER_INPUT`、`PLANNER_RESPONSE`、`GENERIC`、`SYSTEM_MESSAGE`
  - 出現過的 `source`：`USER_EXPLICIT`、`MODEL`、`SYSTEM`
  - 各 `type` 的所有 key：
    - `USER_INPUT`：`content`, `created_at`, `source`, `status`, `step_index`, `type`
    - `PLANNER_RESPONSE`：`cache_read_tokens`, `content`, `created_at`, `input_tokens`, `model`, `output_tokens`, `source`, `status`, `step_index`, `thinking`, `tool_calls`, `type`
    - `GENERIC`（工具執行結果）：`content`, `created_at`, `error`, `source`, `status`, `step_index`, `type`（`transcript.jsonl` 另可能有 `truncated_fields`）
    - `SYSTEM_MESSAGE`：`content`, `created_at`, `source`, `status`, `step_index`, `type`
- **單行範例（所有值已換成假值）**：
  - `USER_INPUT`：
    ```json
    {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-01-01T00:00:00Z","content":"<USER_REQUEST>\nexample prompt\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-01-01T08:00:00+08:00.\n</ADDITIONAL_METADATA>"}
    ```
  - `PLANNER_RESPONSE`：
    ```json
    {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-01-01T00:00:01Z","model":"gemini-4-neon-high","input_tokens":1200,"cache_read_tokens":800,"output_tokens":150,"thinking":"Thinking summary...","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"ls -la /Users/<user>/Projects\"","WaitMsBeforeAsync":"5000","toolSummary":"\"List directory\""}}]}
    ```

### 模型名稱、Token / Context 百分比、Todo / 計畫的記錄情形
- **模型名稱**：**有**，記錄於 `PLANNER_RESPONSE` 的 `model` 欄位（例：`"gemini-4-neon-high"`）；當使用者切換模型時，`USER_INPUT` 的 `content` 內也會附帶 `<USER_SETTINGS_CHANGE>` 區塊。
- **Token 用量**：**有**，記錄於 `PLANNER_RESPONSE` 的 `input_tokens`、`cache_read_tokens`、`output_tokens`。
- **Context 百分比**：在實測的 `transcript.jsonl` / `transcript_full.jsonl` 中**沒有直接欄位**；若要取得即時 `context_window_size`、`used_percentage`、`remaining_percentage`，官方是透過 **Status Line JSON payload** 提供（見第 6 節）。
- **Todo 或計畫**：在實測的 `transcript.jsonl` / `transcript_full.jsonl` 中**沒有專屬的 `todo` 或 `plan` 結構化欄位**。依內建 `<artifacts>` 規範，計畫類報告通常寫成 Markdown 檔存於 `~/.gemini/antigravity-cli/brain/<conversation-id>/` 下；若使用 `/plan` 模式是否會寫入額外的 transcript `type` 則為**不確定**（本對話未觸發 `/plan`）。

### 來源
- 實測指令：`ls -la ~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/` 與 `chunks/`；Python 腳本遍歷 `transcript.jsonl` 及 `transcript_full.jsonl` 解析 schema。
- 內建文件：`/Users/<user>/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`（說明 CLI / App / IDE 目錄差異）。

---

## 3. 輸入與指令

### Slash 指令清單
- **說明**：由於我無法在自身運行中的 TUI 輸入 `/help` 並擷取原始畫面，因此**無法提供 `/help` 逐字完整輸出（完整清單待於互動 TUI 實測 `/help` 確認）**。
- **可確認的內建 Slash 指令**：
  - **來自本環境系統內建 `<slash_commands>` 說明**：
    - `/goal`（長時目標執行模式）
    - `/compact`（壓縮／摘要上下文釋放 context window）
    - `/schedule`（排程／計時器）
    - `/browser`（網頁瀏覽與互動）
    - `/plan`（先規劃再執行）
    - `/grill-me`（互動式訪談釐清設計決策）
    - `/teamwork`（多代理協作）
    - `/learn`（持久化修正或設定經驗）
    - `/boost`（深度思考與多視角驗證）
  - **來自內建 `antigravity_guide/references/cli.md` 與官方 `https://antigravity.google/docs/cli/reference.md` 查證**：
    - `/help`（開啟分頁式指令與快捷鍵說明）
    - `/exit`、`/quit`（離開 CLI）
    - `/clear`、`/new`（清除並開啟新對話）
    - `/resume`（別名 `/switch`、`/conversation`，開啟歷史對話選擇器）
    - `/fork`（或 `/branch`，分支目前對話）
    - `/model`（檢視／切換模型）
    - `/effort`（調整思考強度）
    - `/mode`（切換執行／權限模式）
    - `/permissions`（開啟權限規則 Allow / Ask / Deny 管理面板）
    - `/statusline`（開關或設定自訂 status line 腳本）
    - `/keybindings`（檢視／設定自訂快捷鍵）
    - `/context`（檢視目前 context window 使用量）
    - `/config`（或 `/settings`，開啟設定面板）
    - `/mcp`（管理 MCP server：`list` / `enable` / `disable`）
    - `/fast`、`/planning`（快速執行／規劃模式）
    - `/antigravity-guide`（透過 agent 查詢官方文件）
  - **補充**：Workspace / Global 載入的自訂 skills（未設 `disable-slash-command: true` 者）也會註冊成 `/<skill-name>`。

### 是否有類似 Claude `!` 的直接 Shell 前綴？
- **有**：根據官方 `https://antigravity.google/docs/cli/reference.md` 查證，在輸入框開頭輸入 `!`（例如 `!git status`）可直接執行 host shell 指令；另支援 `@` 觸發檔案與路徑自動補全。
- **備註**：未於目前互動 TUI 實機按鍵實測細節（如輸出是否自動納入模型 context），該細節標註為**不確定**。

### 切換模型與思考強度的操作方式
- **CLI 啟動參數**（來源：實測 `agy --help`）：
  - `--model`：`Model for the current CLI session`（搭配 `agy models` 查詢可用模型）
  - `--effort`：`Reasoning effort for the current CLI session (low|medium|high|xhigh|max)`
- **互動 TUI 內**（來源：官方 `https://antigravity.google/docs/cli/reference.md`）：
  - `/model`：開啟互動式模型選擇面板或直接切換模型（保留目前對話 context）。
  - `/effort`：開啟互動選擇器或帶參數切換 `low` / `medium` / `high` / `xhigh` / `max`。
  - 是否有預設快捷鍵可直接循環切換模型或 effort：**不確定**（官方文件指出可用 `/keybindings` 或 `~/.gemini/antigravity-cli/keybindings.json` 自訂）。

---

## 4. 權限與互動提示（含補充 (8)）

> **關於原樣畫面（回應補充 (8)）**：目前無法在自身 TUI 觸發權限提示並截取原樣畫面，以下整理**官方文件描述**，並將未實測的原樣字串明確標註為「不確定」。

### 權限提示畫面與選項（官方文件描述）
- **來源**：`https://antigravity.google/docs/cli/reference.md`、`https://antigravity.google/docs/permissions.md`（透過官方文件查證）。
- **檔案修改提示（官方文件描述）**：
  - 提示文字：`Accept this file edit?`
  - 選項：
    - `1. Yes, accept this change`
    - `2. No, reject this change`
- **新增檔案提示（官方文件描述）**：
  - 提示文字：`Allow creation of this file?`
  - 選項：
    - `1. Yes, allow creation`
    - `2. No, deny creation`
    - （若目標在 workspace 之外，官方文件指出可能會額外出現「永遠允許非 workspace 存取」等選項）
- **指令／工具權限提示（如 `run_command` 需跳出沙盒）**：
  - 官方文件描述權限操作分為 `Allow once`、`Always allow`、`Deny`，且支援 `Ctrl+K` 快速核准。
  - **確切逐字標題、選項編號排版與邊框文字**：**不確定**（需於互動 TUI 實機觸發後以 `herdr agent read --source visible` 抓畫面確認）。
- **Agent 提問提示（`ask_question` 工具）**：
  - 本環境工具定義顯示 `ask_question` 支援單選／多選題，UI 會自動加上選項編號並附加 `Other` 選項（來源：本環境 `ask_question` tool declaration）；其 TUI 確切原樣排版：**不確定**。

### 選選項是單按數字，還是數字＋Enter？
- 依官方 `https://antigravity.google/docs/cli` 文件對檔案編輯確認面板的說明：**可直接單按數字鍵**（如按 `1` 或 `2`），**也支援以方向鍵反白選項後按 `Enter`**。
- **備註**：以上為官方文件描述，尚未於互動 TUI 實機驗證所有提示類型（如命令權限、多選 `ask_question`）是否皆支援單鍵直選。

### 權限模式、切換方式與畫面標示
- **支援的模式**（來源：實測 `agy --help` 與官方 `https://antigravity.google/docs/permissions.md`）：
  1. `default`：檔案修改／建立會顯示 diff 確認面板，終端指令依規則詢問。
  2. `auto`：自動核准 workspace 內檔案編輯，終端指令預設在隔離的 Terminal Sandbox 內自動執行；需跳出沙盒的指令由權限引擎評估（安全可逆則放行，具風險／不可逆／連網則暫停詢問）。
  3. `accept-edits`：自動核准 workspace 內檔案建立與編輯，但執行終端指令仍詢問。
  4. `plan`：強制先探索與規劃步驟，不直接修改檔案。
  - 另提供啟動旗標 `--dangerously-skip-permissions`（或在 `settings.json` 設 `"toolPermission": "always-proceed"`），自動核准所有工具權限請求；但官方權限引擎優先順序為 **`Deny > Ask > Allow`**，顯式 `deny` 規則仍具最高優先權。
- **切換方式**：
  - TUI 內按 **`Shift+Tab`** 循環切換，或使用 **`/mode`**。
  - CLI 啟動參數：`agy --mode <accept-edits|auto|plan>`。
  - 細粒度規則管理：`/permissions` 開啟 `allow` / `deny` / `ask` 規則管理面板（規則語法如 `command(git)`、`write_file(src/)`，預設嚴格比對，正規表達式需加 `regex:` 前綴）。
- **畫面標示**：顯示於 TUI **右下角狀態列第一段**（見第 7 節）。

---

## 5. Session 控制

### 恢復舊對話與列出歷史 Session
- **CLI 啟動旗標（來源：實測 `agy --help`，`agy 1.5.14`）**：
  - `agy -c` / `agy --continue`：接續最近一次對話（`Continue the most recent conversation`）。
  - `agy --conversation <ID>`：依對話 ID 恢復指定歷史對話（`Resume a previous conversation by ID`）。
- **CLI 是否有 `agy resume` 或列出歷史 session 的子指令？**
  - **沒有**（實測 `agy 1.5.14` 的 `agy --help` 所有 subcommand 僅有：`acp`, `agent`, `agents`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`）。
- **TUI 互動介面**：
  - 輸入 `/resume`（別名 `/switch`、`/conversation`）開啟互動式歷史對話選擇器，可搜尋與切換（來源：官方 `https://antigravity.google/docs/cli/reference.md`）。
- **程式化列出歷史 session**：
  - 透過本機執行中 language server 的 Connect HTTP+JSON API `jetski.product.v1.ConversationService/ListConversations`（來源：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/conversations/SKILL.md`）。

### 中斷正在執行的工作：`Esc` 還是 `Ctrl+C`？
- **來源**：官方 `https://antigravity.google/docs/cli/reference.md` 與內建 `antigravity_guide/references/cli.md`。
- **`Esc`**：中斷／取消正在執行中的 agent 回合、輸出或提案；空輸入時 `Esc Esc` 可清除輸入或關閉面板。
- **`Ctrl+C`**：取消目前操作；連按兩次 `Ctrl+C`（或 `Ctrl+D Ctrl+D`、`/exit`、`/quit`）會結束 CLI session。
- **備註**：未實機測試單按 `Esc` 與單按 `Ctrl+C` 在工具執行中途的差異行為，細部差異標註為**不確定**。

---

## 6. 結構化介面

Antigravity CLI 提供 **6 種**不需解析 TUI 畫面的結構化介面：

### 6.1 無互動 Print Mode（JSON / NDJSON `stream-json`）
- **來源**：實測 `agy --help` 與官方 `https://antigravity.google/docs/cli/reference.md`。
- **CLI 旗標**：
  - `-p` / `--print`（別名 `--prompt`）：非互動單輪執行。
  - `--output-format <text|json|stream-json>`：
    - `json`：執行完成後輸出單一 JSON 物件。
    - `stream-json`：以 NDJSON 即時串流事件（如 `text_delta`、`result` 含 `usage`）。
  - `--input-format <text|stream-json>`：搭配 `--output-format stream-json`，可從 `stdin` 逐行送入 NDJSON 持續進行多輪對話，免重啟程序。
  - `--json-schema <string-or-path>`：以 JSON Schema 限制最終輸出格式。
  - `--print-timeout <duration>`、`--disable-slash-commands`、`--settings <json-or-path>`。

### 6.2 Agent Client Protocol（ACP）Server
- **來源**：實測 `agy help acp` 與官方 `https://antigravity.google/docs`。
- **啟動指令**：`agy acp [flags]`（預設 `--stdio`，透過 stdio 進行 JSON-RPC 2.0 溝通）。
- **實測關鍵旗標**（節錄自 `agy help acp`）：
  - `--stdio`（預設）、`--add-dir`、`--agent`、`--dangerously-skip-permissions`、`--sandbox`、`--process-per-session`、`--login`、`--ide-mcp-port`、`--app-data-dir`、`--log-file`。
- **協定方法**（來源：官方文件查證）：支援標準 ACP 生命週期如 `initialize`、`session/new`、`session/prompt`、`session/cancel`、`session/close`，供 Zed / IDE 等客戶端整合。

### 6.3 官方 Python SDK
- **來源**：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/antigravity_guide/references/sdk.md`。
- **安裝與專案**：`pip install google-antigravity`（GitHub：`google-antigravity/antigravity-sdk-python`，wheel 內含編譯好的 runtime binary）。
- **能力**：透過 `Agent`、`LocalAgentConfig`、`CapabilitiesConfig` 進行 async 呼叫，可串流文字 token、`response.thoughts`、以及強型別 `response.tool_calls`。

### 6.4 Lifecycle Hooks（`hooks.json`）
- **來源**：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`。
- **設定位置**：專案 `.agents/hooks.json` 或全域 `~/.gemini/config/hooks.json`。
- **支援事件**：`SessionStart`、`PreToolUse`、`PostToolUse`、`PreInvocation`、`PostInvocation`、`Stop`（其中 `PreToolUse` / `PostToolUse` 支援 regex `matcher`）。
- **I/O 合約**：`stdin` 傳入 camelCase JSON（共通欄位：`conversationId`、`workspacePaths`、`transcriptPath`、`artifactDirectoryPath`、`modelName`、`lastUserInput`、`hookEventName`、`cwd`）；`stdout` 回傳 JSON 控制（例如 `PreToolUse` 回傳 `decision: "allow"|"deny"|"ask"|"force_ask"` 與 `overwrite`；`PreInvocation`/`PostInvocation` 回傳 `injectSteps` 與 `terminationBehavior`；`Stop` 回傳 `decision: "continue"`）。
- **限制**：目前僅支援 `type: "command"`，且同步阻塞執行。

### 6.5 Custom Status Line（JSON Payload）
- **來源**：官方 `https://antigravity.google/docs/cli/reference.md` 查證。
- **設定方式**：透過 `/statusline <script>` 或於 `~/.gemini/antigravity-cli/settings.json` 設定：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "~/.gemini/antigravity-cli/statusline.sh",
      "enabled": true
    }
  }
  ```
- **JSON Payload 欄位**（官方文件範例結構）：
  - `version`、`product`、`plan_tier`、`agent_state`（如 `idle` / `working` / `tool_use`）、`cwd`、`workspace`（`current_dir`, `project_dir`）
  - `model`：`id`、`display_name`、`effort`
  - `context_window`：`context_window_size`、`used_percentage`、`remaining_percentage`、`total_input_tokens`、`total_output_tokens`、`current_usage`（`input_tokens`, `output_tokens`）

### 6.6 本機 `ConversationService`（Connect HTTP+JSON）
- **來源**：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/conversations/SKILL.md` 及本環境環境變數檢查（`ANTIGRAVITY_LS_ADDRESS`、`ANTIGRAVITY_CSRF_TOKEN`、`ANTIGRAVITY_CONVERSATION_ID`、`ANTIGRAVITY_PROJECT_ID`）。
- **介面**：`POST http://$ANTIGRAVITY_LS_ADDRESS/jetski.product.v1.ConversationService/<Method>`，需帶 `Connect-Protocol-Version: 1` 與 `x-antigravity-csrf-token` header。
- **方法**：`CreateConversation`、`ListConversations`、`GetConversation`、`UpdateConversation`、`DeleteConversation`。
- **回傳狀態**：包含 `state.runState`（`RUN_STATE_IDLE` / `RUN_STATE_RUNNING` / `RUN_STATE_CANCELLING`）、`state.summary`、`state.updateTime`、`metadata`、`annotations`。

---

## 7. 畫面右下角狀態列「`auto · Gemini 4 Neon · high`」解析

三段由左至右分別對應以下設定：

| 區段 | 顯示範例 | 代表意義 | 互動 TUI 切換方式 | CLI 啟動參數 |
| --- | --- | --- | --- | --- |
| 第 1 段 | `auto` | **執行／權限模式**（`default` / `auto` / `accept-edits` / `plan`） | 按 `Shift+Tab` 循環切換，或執行 `/mode` | `--mode <accept-edits\|auto\|plan>` |
| 第 2 段 | `Gemini 4 Neon` | **目前模型顯示名稱**（Model display name） | 執行 `/model` 開啟選擇器切換 | `--model <model>`（`agy models` 可查清單） |
| 第 3 段 | `high` | **思考強度／推理深度**（Reasoning effort：`low` / `medium` / `high` / `xhigh` / `max`） | 執行 `/effort` 開啟選擇器或帶參數切換 | `--effort <low\|medium\|high\|xhigh\|max>` |

- **來源**：實測 `agy --help`（確認 `--mode`、`--model`、`--effort` 合法值與定義）＋ 官方 `https://antigravity.google/docs/cli/reference.md` 與 `https://antigravity.google/docs/permissions.md`（確認 `Shift+Tab`、`/mode`、`/model`、`/effort` 與 status bar 呈現內容）。

---

## 8. 查證限制與「不確定」項目彙整

以下項目無法於目前非互動工具環境中直接實測確認，建議若需精確比對畫面字串，再於實際 TUI 觸發並以 `herdr agent read --source visible` 驗證：

1. `/help` 在 `agy 1.5.14` TUI 中的完整逐字輸出清單。
2. 權限確認卡片（尤其是 `run_command` 跳出沙盒、網路存取）與 `ask_question` 互動卡片在 TUI 中的**確切逐字標題、選項文字與編號排版**。
3. 所有權限卡片與多選題是否皆一致支援「單按數字直選」（目前僅檔案編輯提示見於官方文件明文描述）。
4. `!` shell 前綴執行後的輸出是否自動注入模型 context。
5. 單按 `Esc` 與單按 `Ctrl+C` 在工具執行中途的細部中斷差異。
6. `/plan` 模式執行時是否會在 `transcript.jsonl` 產生本對話未觀察到的其他 `type` 或 `todo` 欄位。


---

# 附錄：方案用量與額度


> **驗證環境**：`agy 1.5.14`（`/Users/<user>/.local/bin/agy`）、macOS。
> **去識別化說明**：路徑中的帳號均替換為 `<user>`，範例 ID 與 Email 皆為假值，不含個人資料、帳號或權杖。
> **查證原則**：每項均註明來源（實際執行指令、內建技能文件或官方線上文件）；無法實機驗證或官方未公開之項目明確標示「不確定」，不探測未公開本機服務。

---

## 總覽結論

Antigravity CLI **有**方案用量／額度資訊（分為「5 小時滾動額度」與「每週上限」，並依模型群組獨立計算）：
- **互動檢視**：TUI 內建 `/usage`（別名 `/quota`）開啟 **Models & Quota** 面板。
- **結構化讀取（最接近 Claude Code `statusLine.rate_limits`）**：官方 `statusLine` 設定所推送的 **JSON payload 內建 `quota` 物件**，提供各 bucket（如 `gemini-weekly`、`gemini-5h`、`3p-weekly`、`3p-5h`）的 `remaining_fraction`、`reset_time`、`reset_in_seconds` 與 `plan_tier`。
- **CLI 子指令與公開本機 Connect API**：目前 `agy 1.5.14` **沒有**獨立的 quota CLI 子指令，也**沒有**官方公開文件化的本機 Connect RPC 額度查詢 API。

---

## (a) `agy` 子指令與旗標有沒有 `quota` / `usage`？

### 結論
- **沒有**任何與 `quota`、`usage` 或 `rate-limit` 相關的頂層旗標或子指令。

### 實測來源與輸出摘錄
1. **實測指令**：`agy --help`（`agy 1.5.14`）
   - 所有頂層 subcommand 僅為：`acp`、`agent`、`agents`、`changelog`、`help`、`install`、`mcp`、`mic-serve`、`models`、`plugin`、`plugins`、`remote-control`、`update`（無 `quota` / `usage` / `billing` / `status`）。
   - 頂層 flags 皆為工作區、模型、模式、對話恢復、print mode、sandbox 與設定相關，無額度查詢旗標。
2. **實測指令**：逐一執行 `agy help <subcommand>`（涵蓋 `agent`, `agents`, `changelog`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `remote-control`, `update`, `acp`）：
   - `agy help models`：僅顯示 `List available models`，flags 只有 `-h` / `--help`。
   - `agy help agent` / `agy help agents`：僅顯示 `List available agents`，flags 只有 `-h` / `--help`。
   - 其餘子指令亦皆無任何 quota / usage 旗標。
3. **關於 `agy models` 實際輸出是否含剩餘額度**：**不確定**。於本沙盒中執行 `agy models` 時因讀取 `/Users/<user>/.gemini/antigravity-cli/installation_id` 遭沙盒阻擋（`operation not permitted`），未取得實際清單輸出。
4. **補充（內部工具而非 CLI 子指令）**：
   - 來源：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/native_swarm/SKILL.md`（L363–L365）。
   - 在 `/swarm` 協作模式內建工具中，`swarm{action:"models"}` 文件記載會顯示各模型的即時 `quota_remaining`、`quota_resets` 與 `quota_note`（當由 AI credits 支付時）；但這僅限 swarm agent 內部工具呼叫，並非外部 CLI 子指令。

---

## (b) TUI 指令（`/usage`、`/quota`、`/context`、`/stats`、`/config`）是否顯示額度？

> 因目前環境無法以非互動方式擷取 TUI 互動面板原樣畫面，以下整理自官方文件查證（`https://antigravity.google/docs/cli/reference.md`、`https://antigravity.google/docs/plans`）。

| 指令 | 是否顯示方案額度 | 官方文件描述與說明 |
| --- | --- | --- |
| **`/usage`**（別名 **`/quota`**） | **是** | 開啟互動式 **Models & Quota** TUI 面板；開啟時會自動從本機快取與後端重新整理最新額度。依**模型群組**（例如 Gemini 群組、Claude / GPT 等第三方群組）分別呈現 **5 小時額度（Five-hour limit）** 與 **每週上限（Weekly limit）** 及重置倒數。操作鍵：`↑`/`↓`（`J`/`K`）、`PgUp`/`PgDn`、`G`/`Shift+G`、`Esc`/`Q` 關閉。 |
| **`/context`** | **否** | 顯示當前對話的 context window token 使用量，非帳號方案額度。 |
| **`/stats`** | **不確定** | 官方網站搜尋摘要中偶與 `/usage` 並列提及，但無法確認在 `agy 1.5.14` 中是否為正式獨立指令或 `/usage` 別名。 |
| **`/config`**（或 `/settings`） | **不確定（非額度面板）** | 開啟互動設定面板（調整偏好、模式、verbosity、AI Credit Overages 等），非即時額度檢視器；頁內是否附帶顯示方案等級或 credits 餘額為**不確定**。 |

### 方案額度機制補充（來源：`https://antigravity.google/docs/plans`）
- **雙層限制**：Pro / Ultra 方案同時受 **5 小時滾動刷新窗口** 與 **每週總上限** 雙重限制（達週上限後，即使 5 小時窗口刷新也不會恢復，直到週重置）；Free / 基礎方案則以每週刷新為主。
- **依模型群組獨立計算**：Gemini 群組與第三方（Claude / GPT）群組額度池分開計算，某一群組耗盡時可切換至另一群組。
- **依運算量動態消耗**：非固定訊息次數制，依 agent 實際執行的工作量與計算量消耗。

---

## (c) `statusLine` JSON Payload 除了 `plan_tier` 還有沒有額度欄位？

### 結論
- **有**。根據官方 `https://antigravity.google/docs/cli/reference.md` 查證，`statusLine` 透過 `stdin` 傳遞給外部腳本的 JSON payload 包含專屬的 **`quota`** 物件（功能上對應 Claude Code `statusLine` 的 `rate_limits`），此外還有 `plan_tier`、`cost`、`context_window` 等欄位。

### 設定方式（`~/.gemini/antigravity-cli/settings.json`）
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.gemini/antigravity-cli/statusline.sh",
    "enabled": true,
    "padding": 0,
    "stack_with_default": false
  }
}
```
- `stack_with_default: true` 可在保留內建狀態列的同時，把自訂腳本的輸出疊加於下方（來源：`https://antigravity.google/docs/cli/reference.md`）。

### Payload 中的額度與用量相關欄位（官方文件範例摘錄，已去識別化）
```json
{
  "version": "1.4.5",
  "product": "antigravity",
  "plan_tier": "Pro",
  "agent_state": "idle",
  "cycle_mode": "plan",
  "model": {
    "id": "Gemini 4 Argon (Medium)",
    "display_name": "Gemini 4 Argon (Medium)",
    "effort": "medium"
  },
  "quota": {
    "gemini-weekly": {
      "remaining_fraction": 0.9378,
      "reset_time": "2026-07-06T07:50:32Z",
      "reset_in_seconds": 560580
    }
  },
  "context_window": {
    "total_input_tokens": 88244,
    "total_output_tokens": 61074,
    "context_window_size": 1048576,
    "used_percentage": 14.24,
    "remaining_percentage": 85.76,
    "current_usage": {
      "input_tokens": 63382,
      "output_tokens": 346,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 20857
    }
  },
  "cost": {
    "total_usd": 0.4213,
    "subagent_usd": 0,
    "estimated": false
  }
}
```

### `quota` 物件欄位說明（來源：`https://antigravity.google/docs/cli/reference.md`）
- **Key（bucket ID）**：官方文件與範例中出現的 bucket ID 包含 `gemini-weekly`、`gemini-5h`、`3p-weekly`、`3p-5h`（實際出現哪些 key 依帳號方案與可用模型群組而定）。
- **每個 bucket 物件的欄位**：
  - `remaining_fraction`（float，`0.0` ~ `1.0`）：剩餘額度比例（已用百分比可換算為 `(1 - remaining_fraction) * 100`）。
  - `reset_time`（string）：ISO-8601 UTC 重置時間戳。
  - `reset_in_seconds`（integer）：距離下次重置的剩餘秒數。
  - `disabled`（boolean，選填）：該 bucket 是否處於停用狀態。
- **備註**：
  - 官方文件註明 payload 內所有欄位都應視為 optional（某些方案下如 `cost` 可能省略）。
  - 本次未修改本機 `settings.json` 實際擷取 `agy 1.5.14` 的即時 `stdin` 樣本，因此 `agy 1.5.14` 是否另有新增額度子欄位（例如 AI credits 餘額）標註為**不確定**。

---

## (d) 本機 Language Server 的 Connect API 能否讀到額度？

### 已文件化的本機 Connect API（來源：本機內建技能文件）
以 `grep` 掃描 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/` 全部檔案後，本機 language server（`$ANTIGRAVITY_LS_ADDRESS`）有**兩個**官方內建文件記載的 Connect HTTP+JSON service：

1. **`jetski.product.v1.ConversationService`**
   - 來源：`/Users/<user>/.gemini/antigravity-cli/builtin/skills/conversations/SKILL.md`
   - 路徑：`http://$ANTIGRAVITY_LS_ADDRESS/jetski.product.v1.ConversationService/<Method>`（Header：`Connect-Protocol-Version: 1`、`x-antigravity-csrf-token`）
   - 公開方法：`CreateConversation`、`ListConversations`、`GetConversation`、`UpdateConversation`、`DeleteConversation`
   - **是否含額度**：**否**，僅回傳對話 `id`、`metadata`、`annotations`、`state`（`summary`、`runState`、`updateTime`）。
2. **`exa.language_server_pb.LanguageServerService`**
   - 來源：`/Users/<user>/.gemini/antigravity-cli/builtin/skills/plugin/SKILL.md`
   - 路徑：`http://$ANTIGRAVITY_LS_ADDRESS/exa.language_server_pb.LanguageServerService/<Method>`（Header：`x-codeium-csrf-token`）
   - 文件記載之唯讀方法：`GetAllPlugins`（另註明寫入類 RPC 如 `JetboxWriteState`、`DeletePlugin`、`InstallCustomization` 在 `run_command` 中受限）。
   - **是否含額度**：**文件未記載**任何額度查詢方法。

### 是否有公開的 `UserService` / `QuotaService`？
- **官方文件未公開**：在所有本機內建技能文件與 `antigravity.google` 公開文件中，**沒有**公開文件化可供外部工具呼叫的本機 `UserService` 或 `QuotaService` Connect API。
- 雖有外部技術討論提及 Antigravity 內部與後端 `cloudcode-pa` 溝通時使用類似 `GetUserStatus`、`RetrieveUserQuotaSummary` 等內部 RPC 名稱，但皆屬未公開內部介面；基於不探測未文件化本機服務之原則，本次未對 `$ANTIGRAVITY_LS_ADDRESS` 進行未公開端點探測。
- **結論**：透過本機 Connect API 讀取額度目前**無官方支援管道（不確定其穩定性且不建議依賴）**；官方文件正式提供給外部工具讀取額度的介面是 **`statusLine` JSON payload**（見 (c)）。

---

## (e) 用量超過時畫面或錯誤訊息長什麼樣子？

> 本環境未實際觸發額度耗盡，無法擷取 TUI 原樣畫面，以下整理自本機內建文件與官方支援／社群回報資料：

1. **底層錯誤碼與常見錯誤文字**（來源：`google.dev` 與官方問題排查／GitHub issue 查證）：
   - 後端常回傳 **`RESOURCE_EXHAUSTED`（HTTP 429）**。
   - 常見提示訊息包含 `Individual quota reached` 或 `AI: Out of credits`（若已無剩餘額度且未啟用／用完 AI credits overages）。
   - 若 Pro / Ultra 未啟用 **AI Credit Overages**，達上限時 CLI 會直接中止並報錯；啟用後則改扣 AI credits。
2. **低額度預警與耗盡後行為**（來源：內建 `/Users/<user>/.gemini/antigravity-cli/builtin/skills/native_swarm/SKILL.md`，L356–L375）：
   - 回合開始時可能出現 **`[quota]` 低額度警告**。
   - 若回合因 quota exhaustion 失敗，執行會停止且**不會自動重試**，需切換至仍有額度的模型群組、等待額度重置，或改由 AI credits 支付後再重新送出提示。
3. **TUI 畫面上確切逐字錯誤橫幅、倒數顯示格式與互動按鈕**：**不確定**（需實際觸發超額時抓取畫面確認）。

---

## 給共用介面設計的簡短對照註記

- 若要比照 Claude Code 的 `statusLine.rate_limits`，Antigravity CLI 最對等的官方結構化來源就是 **`statusLine` 的 `quota` 物件**（`remaining_fraction`、`reset_time`、`reset_in_seconds` + `plan_tier`），但需留意它屬於「由 CLI 在互動 session 更新時主動 pipe 給 `statusLine.command`」的推送模式，而非像 Codex `app-server` 那樣由外部隨時主動呼叫的 RPC。
