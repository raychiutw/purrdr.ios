# 多種 coding agent 的抽象方式：外部做法調查(截至 2026-11-22)

> 目的：在 Purrdr 引入 `AgentID`(正規化 herdr 的 agent kind 與別名)與每個 agent 一份值型別 `AgentProfile`(transcript、輸入規則、畫面解析、session 等純 dialect;主機 I/O 能力另放 registry)之前，先看別人怎麼處理「一個 UI 對多種 coding agent」。
>
> 標記:**【一手】** = 官方文件、規格或原始碼(附 URL 與 commit);**【推論】** = 依一手資料推出的判斷;**未驗證** = 找不到一手來源佐證。第三方文章只當線索，不當論據。
>
> clean-room:依 ADR-0001,本次**沒有**開啟或參考任何名為 herdrchat 的 repo。
>
> 原始碼版本(2026-11-22 shallow clone):
> - herdr `e8d7d9705a7a2c89cef4dd42079379f05685af87`(文件取 `docs/versions/0.9.5/`,與本機 `herdr 0.9.5` 相同)
> - agent-client-protocol `01a54c84f39508f73fab4d41362baf51e1320374`(schema crate 1.21.2)
> - claude-code-acp(現名 claude-agent-acp)`4af4581ad510a85d5cdfa3b9100412479e1cfef4`
> - zed-industries/codex-acp `296069e841634cd4bb9bc4515602d836e49231ec`
> - claude-squad `070eb9387cda2be2e64aa1a32ee81be160c457a1`
> - Crystal `1e18e0bc981225f75b5226f82a300fa741970c6f`

## TL;DR

- **herdr 自己就是「封閉 enum + 別名表 + 資料驅動的畫面規則」**:24 個 agent 的 Rust enum、每個有一個 canonical label(如 `agy`、`copilot`)和一串別名;畫面狀態判斷放在每個 agent 一份、帶版本號、可遠端熱更新的 TOML manifest。完全不認得的 agent 一律 `Unknown`,認得但沒有規則對上的退回 `idle`,`blocked` 只在明確比對到時才給。
- **ACP(Agent Client Protocol)走的是另一條路**:協定只定義共通語意(session、prompt、permission request、config options、available commands、plan、usage),每個 agent 的差異推給 **adapter**(`claude-agent-acp`、`codex-acp`),client 只看 `initialize` 協商出來的 capability。缺能力就是「沒宣告」,client **MUST NOT** 呼叫。
- **第一方結構化介面越來越多，但都不在我們讀的那一層**:Claude Code 的 transcript JSONL 官方明說是「internal、會隨版本改變」;Codex 有 `codex app-server`(JSON-RPC,可產生 schema);Antigravity 有 `agy acp` 與 `-p --output-format stream-json`;OpenCode 有 HTTP server 與 OpenAPI。它們全是「另外起一個 process／server」的介面，不能拿來讀**已經跑在 herdr pane 裡的互動式 TUI**。
- **多 agent 的 UI 分成三派**:(a) 字串比對散在各處(claude-squad,和我們現況一樣);(b) 抽象類別 + capability flags 的 registry(Crystal);(c) 全部經 ACP(Zed),agent 端自己負責差異。
- **建議**:`AgentProfile` 這個方向和 herdr 的作法最接近、也最適合 Purrdr 的位置(遠端讀 TUI 畫面與 transcript)。但要學 herdr 的三件事：別名與 canonical label 對齊 herdr、未知 agent 是一級公民(`AgentID.other(String)`)、每個 dialect 標明驗證過的 agent 版本並保守退回。ACP 和第一方協定是「之後另一種連線方式」的候選，不該現在塞進 `AgentProfile`。

---

## 1. herdr:怎麼偵測與建模 agent kind

### 1.1 封閉 enum + canonical label + 別名

- 【一手】`src/detect/mod.rs` 定義 `pub enum Agent`(24 個 case:Pi、Claude、Codex、Gemini、Cursor、Devin、Antigravity、Cline、Omp、Mastracode、OpenCode、GithubCopilot、Kimi、Kiro、Droid、Amp、Grok、Hermes、Kilo、Qodercli、Qwen、Letta、Maki、Muse)。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/src/detect/mod.rs#L43-L121
- 【一手】`agent_label()` 給每個 case 一個 **canonical label**,而且不一定等於產品名：`Antigravity => "agy"`、`GithubCopilot => "copilot"`。另有 `interactive_agent_executable()`(例：Kiro 是 `kiro-cli`、Cursor 在 Windows 是 `cursor-agent.cmd`)。同檔 L124-L186。
- 【一手】`lookup_agent()` 是別名表：`"claude" | "claude-code"`、`"agy" | "antigravity" | "antigravity-cli"`、`"copilot" | "github-copilot" | "ghcs"`、`"opencode" | "opencode2" | "open-code"`、`"grok" | "grok-build"`⋯;`parse_canonical_agent_label()` 則**嚴格**只接受 canonical label。測試 `every_agent_label_round_trips_through_canonical_and_alias_parsers`、`canonical_agent_labels_are_strict` 守著兩者一致。同檔 L188-L235、L1071、L1121。
- 【一手】process 辨識不只看 process 名：會拆 node／python runtime 的 argv、Windows `cmd`／PowerShell 參數、套件安裝路徑，並有 agent 專屬例外(Letta 只認互動式、Muse 認 `muse-bin-<版本>`)。同檔 L245-L330、L422-L940。
- 【一手】使用者可以用 `HERDR_AGENT=<agent>` 告訴 herdr 包裝程式(sandbox wrapper)背後是哪個 agent。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/versions/0.9.5/website/src/content/docs/agents.mdx(「VMs and sandbox wrappers」)

### 1.2 狀態：資料驅動的 detection manifest

- 【一手】狀態只有 `Idle`／`Working`／`Blocked`／`Unknown`,`Unknown` 是「plain shell or unrecognized program」。`AgentDetection` 另外帶 `skip_state_update`(畫面是 transcript viewer)、`visible_blocker`、`visible_idle`、`visible_working` 等證據旗標。`src/detect/mod.rs` L9-L40。
- 【一手】每個 agent 一份 TOML manifest(`src/detect/manifests/*.toml`),有 `id`、`version`(日期版號)、`min_engine_version`、`aliases`,與一串帶 `priority`、`region`(如 `bottom_non_empty_lines(12)`、`osc_title`)、`regex`／`line_regex`／`contains`／`not` 的規則。例：`claude.toml` 以 OSC title 的 spinner 字元判斷 working,註解寫明「Braille covers <= 2.1.227; half-circles are the 2.1.228 busy spinner」。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/src/detect/manifests/claude.toml
- 【一手】manifest 開頭用註解記錄**證據來源與驗證版本**,例：`antigravity.toml`「Evidence: Antigravity CLI 1.2.17 live pane reads, plus reporter captures from 1.1.28 through 1.2.16」,並列出各種對話框最後一行的按鍵提示。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/src/detect/manifests/antigravity.toml
- 【一手】manifest 會從 herdr.dev 遠端更新、不必重啟;本機 `~/.config/herdr/agent-detection/<agent>.toml` 覆寫永遠優先;壞掉的覆寫會被忽略並退回內建。但「Adding a completely new agent still requires a Herdr binary update for process detection, labels, and integration behavior」。`herdr agent explain` 會說明套用了哪份 manifest、哪條規則、或為何退回 idle。agents.mdx(「Detection manifests」)
- 【一手】**保守的 blocked**:「Herdr only marks `blocked` when the live bottom-buffer snapshot matches known visible approval, question, or permission UI. If no manifest rule matches for a known agent, Herdr falls back to `idle`」,並提醒「idle status is not authorization to approve an action」。agents.mdx(「Blocked state」)

### 1.3 integration 與 agent 自己回報

- 【一手】兩種支援：herdr 支援的(讀畫面)與 agent 支援 herdr 的(自己回報)。表格逐一列出 integration 名(`claude`、`codex`、`copilot`、`antigravity-cli`、`grok`⋯),備註欄區分「also reports state」「state requires the integration」「state only」「less tested」。agents.mdx(「Supported agents」)
- 【一手】integration 的主要用途是回報 **session 身分以便 restore**;只有 Pi、OMP、Kimi、OpenCode、Kilo、MastraCode 的 integration 也回報狀態(「While they report, Herdr uses them instead of reading the screen」)。Claude、Codex、Copilot 的 hook 只回報 session,狀態仍來自畫面。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/versions/0.9.5/website/src/content/docs/integrations.mdx
- 【一手】程式碼裡把這個差別寫成兩張表：`full_lifecycle_hook_authority(source, label)` 與 `session_identity_only_integration(source, label)`(例 `("herdr:antigravity_cli", "agy")`)。`src/detect/mod.rs` L330-L350。
- 【一手】Claude integration v10 只比對文件列出的 `SessionStart` source(`startup`、`resume`、`clear`、`compact`、`fork`),原因是「This prevents Grok's `new` and `load` events from launching the imported Herdr Claude hook」——也就是 **Grok CLI 會匯入 Claude 的 hook 設定**。integrations.mdx(Claude 段)
- 【一手】自訂 agent 經 `pane.report_agent`(`source`、`agent`、`state`、`seq`)、`pane.report_agent_session`(`agent_session_id`、`resume_argv`)、`pane.release_agent` 回報;`agent` 是任意字串，文件要求「Use your own agent's name, not the name of an agent Herdr already supports」。`agent.list` 等回傳唯讀的 `agent_session { source, agent, kind, value }`。https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/versions/0.9.5/website/src/content/docs/add-herdr-support.mdx 、socket-api.mdx(「Agent state reporting」)
- 【一手】`pane.report_metadata` 的 `display_agent` 可改**顯示名稱**,但「`working`, `blocked`, `idle`, waits, notifications, and rollups still come from semantic state」。socket-api.mdx

**對 Purrdr 的意義【推論】**:herdr 回傳的 `agent` 欄位有兩種來源——內建 agent 的 canonical label(封閉集合)與自訂回報者的任意字串(開放集合)。`AgentID` 必須同時容納兩者，而且應該以 canonical label 為準、別名表與 herdr 的 `lookup_agent` 對齊，不能拿 `display_agent` 當身分。

---

## 2. Agent Client Protocol(ACP)

### 2.1 協定的 agent 模型

- 【一手】連線先 `initialize`:client 送 `protocolVersion`、`clientCapabilities`(`fs`、`terminal`、`auth`)、`clientInfo`;agent 回 `agentCapabilities`(`loadSession`、`promptCapabilities.image/audio/embeddedContext`、`mcpCapabilities`)、`agentInfo`、`authMethods`。https://github.com/agentclientprotocol/agent-client-protocol/blob/01a54c84f39508f73fab4d41362baf51e1320374/docs/protocol/v1/initialization.mdx
- 【一手】**缺能力 = 沒宣告，client 不得呼叫**:「If `loadSession` is `false` or not present ... Clients **MUST NOT** attempt to call `session/load`」;`session/list` 同理看 `sessionCapabilities.list`。docs/protocol/v1/session-setup.mdx、session-list.mdx
- 【一手】permission:agent 呼叫 client 的 `session/request_permission`,選項有語意化的 `kind`:`allow_once`、`allow_always`、`reject_once`、`reject_always`;「The Agent owns remembered decisions」。docs/protocol/v1/tool-calls.mdx L137-L250
- 【一手】mode／model／effort:舊的 `modes` + `session/set_mode` 已標示將移除，改用 **Session Config Options**——agent 回一串 `{id, name, category: "mode"|"model"|"model_config"…, type: "select", currentValue, options}`,client 照樣畫成選單。docs/protocol/v1/session-modes.mdx、session-config-options.mdx
- 【一手】slash commands:agent 以 `session/update` 的 `available_commands_update` 推送 `{name, description, input.hint}`,可隨時更新;執行時就是在 `session/prompt` 送 `/name 參數` 文字。docs/protocol/v1/slash-commands.mdx
- 【一手】plan/todo:`session/update` 的 `plan`(entries 帶 `content`、`priority`、`status`);client 宣告 `plan` 後可收有 `planId` 的 `plan_update`／`plan_removed`。docs/protocol/v1/agent-plan.mdx
- 【一手】用量:`usage_update` 帶目前 context 的 `used`／`size`(token)與可選 `cost`。docs/protocol/v1/prompt-turn.mdx L505-L531
- 【一手】擴充:`_meta` 欄位、`_` 開頭的自訂 method、初始化時宣告自訂 capability;不得在規格型別根層加自訂欄位。docs/protocol/v1/extensibility.mdx
- 【一手】v2(Preview)把 capability 改成物件標記、幾乎所有 enum 都接受未知值(「`_`-prefixed values are yours」)、移除 session modes 與 client 端 fs／terminal API、`session/load` 併入 `session/resume`;建議 v1、v2 並存、逐連線協商。docs/protocol/v2/migration.mdx

### 2.2 adapter 把每個 agent 的差異吃掉

- 【一手】ACP 官方 agent 清單裡，Claude 是「via Zed's SDK adapter」、Codex 是「via ACP's adapter」、Pi 是「via pi-acp adapter」;Gemini CLI、GitHub Copilot(public preview)、OpenCode、Qwen Code、Kiro、Cursor、Hermes、Qoder 等則原生支援。docs/get-started/agents.mdx
- 【一手】`claude-agent-acp` 建在 **Claude Agent SDK** 上(不是讀 TUI),slash commands 取自 SDK 回報(`query.supportedCommands()`),再濾掉 ACP client 跑不了的(`clear`、`cost`、`login`、`logout`、`todos`⋯)與 CLI 標成 terminal-bound 的，並自己補 `/mcp`、remote-control 等指令。https://github.com/zed-industries/claude-code-acp/blob/4af4581ad510a85d5cdfa3b9100412479e1cfef4/src/slash-commands.ts
- 【一手】同一個 adapter 把 Claude 的 permission mode 對到 ACP 的 mode／config option,模型不支援 Auto 時退回 `acceptEdits` 並發 notice。src/session-mode.ts。README 列出大量 `_meta` 擴充(AIR extensions)——**共通協定不夠時，差異又從 `_meta` 長回來**。README.md
- 【一手】`codex-acp` 原本直接連結 `codex-core` 等 crate(tag `rust-v0.137.0`),approval preset 取自 Codex 的 `builtin_approval_presets` 再對成 ACP mode(`read-only` 等);README 說開發已移到 `agentclientprotocol/codex-acp`,「built on the new Codex App Server」。https://github.com/zed-industries/codex-acp/blob/296069e841634cd4bb9bc4515602d836e49231ec/README.md 、src/thread.rs L114-L192
- 【推論】ACP 的差異化策略是「把 dialect 搬到 agent 端」:adapter 以 agent 的 SDK／app-server 取得結構化資料，client 永遠只看到同一套語意。代價是 adapter 必須跟著 agent 版本走(codex-acp 綁死 Codex 的 git tag)。

---

## 3. 各 agent 的第一方結構化介面

### 3.1 Claude Code

- 【一手】headless:`claude -p`,`--output-format text|json|stream-json`,`--include-partial-messages`;`system/init` 事件帶 model、tools、MCP servers、plugins,並有 `capabilities` 字串陣列,官方建議「Check it to feature-detect instead of comparing version strings, and ignore values you don't recognize」。`--resume <id>`／`--continue`;`--permission-mode` 有 `auto`、`dontAsk`、`acceptEdits` 等;`/model`、`/effort` 在 `-p` 下以參數形式接受。https://code.claude.com/docs/en/headless
- 【一手】**transcript**:「stores transcripts as JSONL at `~/.claude/projects/<project>/<session-id>.jsonl`」,但「**The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release.**」官方建議改用 `/export`、`-p --resume`、hooks／statusline 的 `transcript_path`、或 Agent SDK。https://code.claude.com/docs/en/sessions(「Where transcripts are stored」)
- 【一手】statusline 的 stdin JSON:`session_id`、`transcript_path`、`model`、`context_window.used_percentage`(只算 input tokens,早期可能 `null`)、`effort`、`rate_limits.five_hour/seven_day.used_percentage` 與 `resets_at`(只有訂閱方案、首次回應後才有，各窗口可各自缺席)。https://code.claude.com/docs/en/statusline
- 【一手】session 名稱:`claude -n`、`/rename`,未命名時以小模型產生標題;`-p` 與 SDK session 不出現在 picker。sessions 頁同上。

### 3.2 OpenAI Codex

- 【一手】`codex app-server`:JSON-RPC 2.0(省略 `jsonrpc` 欄),stdio JSONL 為預設，websocket 實驗性;`initialize` + `initialized`,可宣告 `experimentalApi`。方法包括 `thread/start`、`thread/resume`、`thread/list`、`turn/start`、`turn/interrupt`、`model/list`(含 `supportedReasoningEfforts`、`defaultReasoningEffort`)、`skills/list`、`collaborationMode/list`(實驗性)、`review/start`;server→client 的 approval 是 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`;通知有 `thread/tokenUsage/updated`、`account/rateLimits/updated`,另可 `account/rateLimits/read`。`codex app-server generate-ts`／`generate-json-schema` 產生與該版本相符的 schema。https://learn.chatgpt.com/docs/app-server(原 developers.openai.com/codex/app-server,308 轉址)
- 【一手】`codex exec --json`:JSONL 事件 `thread.started`、`turn.started`、`turn.completed`、`turn.failed`、`item.*`、`error`;`codex exec resume --last`／`<SESSION_ID>`;rollout 檔預設寫入磁碟(`--ephemeral` 不寫)。https://learn.chatgpt.com/docs/non-interactive-mode.md
- **未驗證**:rollout 檔的確切路徑與格式穩定性——官方頁沒寫路徑，也沒說 JSONL 是否穩定。app-server 是否提供 slash command 清單：讀到的段落沒有。

### 3.3 Gemini CLI 與 Antigravity CLI(`agy`)

- 【一手】Gemini CLI headless:`-p`、`--output-format` 的 stream 版本是 JSONL,事件 `init`(session ID、model)、`message`、`tool_use`、`tool_result`、`error`、`result`。https://geminicli.com/docs/cli/headless.md
- 【一手】Gemini CLI 在 ACP 官方清單上(原生)。docs/get-started/agents.mdx。**未驗證**:啟動 ACP 的確切旗標。
- 【一手】Antigravity CLI headless:`-p`(別名 `--print`／`--prompt`)、`--output-format text|json|stream-json`,stream 事件 `init`、`step_update`、`result`;`--continue`/`-c`、`--conversation <id>`;`--dangerously-skip-permissions`,沒核准時 headless 會 soft-deny 並以 0 結束。https://antigravity.google/docs/cli/headless.md
- 【一手】`agy acp` 啟動 ACP server(stdio JSON-RPC),沿用 CLI 的登入與設定。https://antigravity.google/docs/cli/acp/ 。**未驗證**:支援哪些 ACP method(session load/resume、config options、available commands)——官方頁未列出。

### 3.4 OpenCode

- 【一手】OpenCode 有 HTTP API(頁面稱 experimental HttpApi),OpenAPI 3.1 文件在 `/docs/openapi.json`;端點如 `GET/POST /api/session`、`GET /api/session/{sessionID}/message`、`POST /api/session/{sessionID}/prompt`、`GET /api/command`、`POST /api/session/{sessionID}/permission/{requestID}/reply`、`GET /api/event`、`GET /api/agent`、`GET /api/model`。https://opencode.ai/docs/server/
- **未驗證**:啟動指令(讀到的部分沒有 `opencode serve`)與 API 穩定性承諾。OpenCode 也在 ACP 原生清單上。

**對 Purrdr 的意義【推論】**:這些介面都需要 Purrdr(或主機服務)**自己啟動或連上**一個 agent process／server;herdr pane 裡由使用者在桌機開的互動式 TUI 不會因此多出一條結構化通道。能「旁聽」既有互動 session 的第一方來源只有：transcript 檔(Claude 官方說格式不穩定)、hooks／statusline(要改使用者設定，屬 ADR-0002 的可還原寫入)、以及 herdr 回報的 `agent_session`。

---

## 4. 支援多種 CLI agent 的 orchestrator／UI

### 4.1 claude-squad(tmux)

- 【一手】設定只有 `profiles: [{name, program}]`——profile 就是一行啟動指令，沒有能力宣告。https://github.com/smtg-ai/claude-squad/blob/070eb9387cda2be2e64aa1a32ee81be160c457a1/README.md
- 【一手】agent 差異是散落的字串比對：`ProgramClaude = "claude"`、`ProgramAider`、`ProgramGemini` 常數;`HasUpdated()` 以 `t.program == ProgramClaude` 比對 `"No, and tell Claude what to do differently"`、Aider 比對 `"(Y)es/(N)o/(D)on't ask again"`、Gemini 比對 `"Yes, allow once"`;信任提示則用 `strings.HasSuffix(t.program, ProgramClaude)`。https://github.com/smtg-ai/claude-squad/blob/070eb9387cda2be2e64aa1a32ee81be160c457a1/session/tmux/tmux.go#L161-L262
- 【推論】同一個 agent 一處用 `==`、一處用 `HasSuffix`、一處用 `HasPrefix`:`program` 若是 `/usr/local/bin/claude` 或帶參數，信任提示會被處理、需要你提示卻偵測不到。這正是「沒有 `AgentID` 正規化」的典型後果。未知 agent:直接沒有 prompt 偵測(`hasPrompt` 保持 false)。

### 4.2 Crystal(已於 2026-02 停止維護，改為 Nimbalyst)

- 【一手】抽象類別 `AbstractCliManager`,每個 agent 實作 `buildCommandArgs`、`parseCliOutput`、`testCliAvailability`、`startPanel`/`continuePanel` 等。https://github.com/stravu/crystal/blob/1e18e0bc981225f75b5226f82a300fa741970c6f/main/src/services/panels/cli/AbstractCliManager.ts#L64-L340
- 【一手】`cliToolRegistry` 的 `CliToolDefinition` 帶 **capability flags**:`supportsResume`、`supportsMultipleModels`、`supportsPermissions`、`supportsStructuredOutput`、`outputFormats`⋯,註冊時驗證必填欄位。main/src/services/cliToolRegistry.ts L10-L60、L489-L520
- 【一手】它不讀 TUI:Claude 以 `--verbose --output-format stream-json` 加 `--resume`,Codex 以 `exec --json`。main/src/services/panels/claude/claudeCodeManager.ts L72-L114、codex/codexManager.ts L221。README 宣告停止維護。

### 4.3 Zed agent panel

- 【一手】External Agents 一律經 ACP;agent「usually owns its own runtime, auth, model selection, tools, and native configuration」。主要經 ACP Registry 安裝;自訂 agent 寫在 `agent_servers`,`"type": "custom"` 加 `command`/`args`/`env`;舊的 extension-provided agents 已棄用並遷移到 registry。https://zed.dev/docs/ai/external-agents
- 【推論】Zed 端沒有 per-agent dialect;差異全靠 capability 協商與 adapter。

### 4.4 VS Code

- 【一手】Claude 是「The Anthropic Claude Agent SDK is integrated into VS Code」;Codex 走 OpenAI Codex 擴充或實驗性的 Agent Host 整合，每個視窗只會有一種 Codex 實作;各自有「Claude permission modes」「Codex approval presets」。https://code.visualstudio.com/docs/copilot/agents/third-party-agents
- 【推論】每個 agent 一個專屬整合(SDK／擴充),不是共通抽象。**未驗證**:VS Code 內部是否有 chat sessions provider 之類的共通介面(該頁沒提)。

### 4.5 Warp

- 【一手】列出 16 種支援的 CLI agent;富文字輸入、code review 等大多數功能全部支援，但 **agent notifications 只有 Claude Code、Codex、OpenCode**(Claude／OpenCode 用 Warp 外掛，Codex 改 `config.toml`),Antigravity 依 CLI 送出的結構化通知。https://docs.warp.dev/agents/cli-agents/overview/
- **未驗證**:Warp 的偵測機制與未知 agent 的處理(文件沒寫)。這是典型的「功能 × agent 矩陣」,不是每個 agent 都有每項能力。

### 4.6 沒查的

- Conductor(閉源)、OpenHands 的 orchestrator 側抽象：**未驗證**(OpenHands 只確認列在 ACP agent 清單上)。

---

## 5. 比較表

| 系統 | agent 身分 | 差異放在哪 | 能力差異的表達 | 未知 agent | 資料來源 |
|---|---|---|---|---|---|
| herdr | 封閉 Rust enum + canonical label + 別名表;自訂回報者是任意字串 | 每個 agent 一份 TOML manifest(資料),process 辨識是程式碼 | integration 表的備註;兩張 `(source, label)` 權限表 | `Unknown`(plain terminal);認得但規則沒對上 → `idle` | 畫面尾端 + OSC;integration hook 回報 |
| ACP(協定) | `agentInfo.name`(agent 自報) | adapter／agent 本身 | `initialize` 協商的 capability;沒宣告就不能呼叫 | 任何講 ACP 的都能接 | 結構化 JSON-RPC |
| claude-agent-acp / codex-acp | 單一 agent | adapter 內部(SDK／codex crate／app-server) | 把 agent 原生能力映射成 ACP + `_meta` 擴充 | — | Agent SDK、Codex crates／app-server |
| claude-squad | `program` 字串(啟動指令) | 散落的 `if program ==/HasSuffix/HasPrefix` | 無 | 沒有 prompt 偵測 | tmux capture-pane |
| Crystal | registry 的 tool id | 抽象類別子類別 | `CliToolCapabilities` 布林旗標 | 不支援(要註冊) | `-p stream-json`、`exec --json` |
| Zed | registry id 或 `agent_servers` 自訂 | 全在 agent 端(ACP) | ACP capability | 任何 ACP agent | ACP |
| VS Code | 每個 agent 一個整合 | 專屬整合 | 各自的設定頁 | 未驗證 | Agent SDK、Codex 擴充 |
| Warp | 偵測到的 CLI agent | 未驗證 | 文件中的功能矩陣 | 未驗證 | 外掛／config／CLI 通知 |
| **Purrdr(規劃)** | `AgentID`(herdr label 正規化) | `AgentProfile` 的純 dialect 值 + 主機 I/O registry | dialect 為 `nil`／不支援 | 待定(見 6.3) | herdr 畫面讀取、transcript、主機腳本 |

---

## 6. 綜合：模式、取捨與對 AgentProfile 的建議

### 6.1 四種反覆出現的模式

1. **Driver interface(每個 agent 一個實作類別)**:Crystal 的 `AbstractCliManager`、VS Code 的專屬整合。好處是任意邏輯都放得下;壞處是共通行為容易在子類別間複製、測試要逐一 mock I/O。
2. **Data profile(每個 agent 一份資料)**:herdr 的 TOML manifest、claude-squad 的 profile(極簡版)。好處是可帶版本、可熱更新、可用 `explain` 除錯、純函式好測;壞處是資料表達力有上限(herdr 也承認新 agent 仍要改 binary)。
3. **Protocol adapter(差異推到協定外)**:ACP + adapter。client 最乾淨，但前提是能控制 agent 的啟動方式;adapter 要追 agent 版本,`_meta` 擴充會讓「共通」逐漸破功。
4. **Capability negotiation(執行期問)**:ACP `initialize`、Claude `system/init.capabilities`、Codex `experimentalApi`。比「看版本號猜」可靠，官方明說要 feature-detect、忽略不認得的值。

Purrdr 的 `AgentProfile` 屬於 2(資料／純值)+ 1(主機 I/O registry)的混合，和 herdr 的架構最接近。這不是巧合：兩者都站在「旁觀別人啟動的互動式 TUI」的位置，拿不到 3、4 需要的控制權。

### 6.2 畫面解析 dialect vs 採用 ACP／結構化協定

- **現在不該把 ACP 或 app-server 塞進 `AgentProfile`。** 它們是另一種「連線方式」(Purrdr 或主機服務自己啟動 agent),不是現有 pane 的另一種解析器。混在一起會讓 profile 同時描述「怎麼讀別人的 TUI」與「怎麼開自己的 session」,邊界不清。【推論】
- **但要留好接縫**:`AgentProfile` 的 dialect 輸出(permission 選項、mode、slash 清單、plan、context 用量)最好用和 ACP 對得上的語意型別——permission 選項帶 `allow_once/allow_always/reject_once/reject_always` 這類 kind,mode／model／effort 用「config option(id、category、目前值、選項)」形狀，slash 用 `{name, description, inputHint}`。這樣日後 HTTPS 主機服務若改用 ACP／app-server 取資料，上層畫面 model 不用改。依據：ACP 已把 modes 收斂到 config options(session-config-options.mdx)。
- **能用結構化來源就別解畫面**,但只限「不需要改變 agent 啟動方式」的來源：herdr 的 `agent_session`、hooks／statusline 給的 `transcript_path` 與 `context_window`、`rate_limits`(要經 ADR-0002 可還原寫入)。Purrdr 現有的 Claude 方案用量走 statusline 包裝，就是這個方向。
- **transcript 是最脆弱的 dialect**:Claude 官方明說 JSONL「internal ... can break on any release」。transcript parser 必須能部分失敗(認不得的行略過而不是整份失敗)、並記錄看過的 agent 版本。

### 6.3 「能力不支援」怎麼建模

- 學 ACP:**沒有就是沒有**,不要用預設值假裝。`AgentProfile` 的每個 dialect 用 optional(`slashDetection: SlashDialect?`),`nil` 表示這個 agent 沒有這個能力或我們沒驗證過;呼叫端照 ACP 的「MUST NOT call」精神，看到 `nil` 就隱藏 UI,而不是走 Claude 的實作。
- 區分三種狀態，畫面文字不同：(a) agent 本身沒有這功能;(b) agent 有但 Purrdr 還沒驗證／實作;(c) 主機或連線方式做不到(例：HTTPS 主機的 SSH 專屬功能、Windows 的 Codex 啟動器)。(c) 已經由主機 I/O registry 與 `HostServiceFeature` 處理，`AgentProfile` 只管 (a)(b)。
- **保守退回**:學 herdr 的 blocked 規則——needs-you／permission 解析只在明確比對到時才回報，對不上就當「沒有偵測到」,且不推定「可以安全送按鍵」。answer keys 尤其如此:herdr 明說 idle 不是核准的授權。
- 未知 agent(`AgentID.other("crush")`)應有一份 **generic profile**:只用 herdr 回報的狀態、送純文字 prompt、不做 slash／shell 偵測、不解 transcript。和 herdr「Other agents still run normally ... show up as plain terminals」一致。

### 6.4 識別碼別名

- `AgentID` 的 canonical 值直接用 herdr 的 canonical label(`claude`、`codex`、`agy`、`copilot`、`grok`、`pi`、`opencode`⋯),別名表以 herdr 的 `lookup_agent` 為準(`antigravity`、`antigravity-cli` → `agy`;`github-copilot`、`ghcs` → `copilot`;`grok-build` → `grok`)。測試仿照 herdr 的 round-trip 測試：每個 case 的 canonical label 能 parse 回自己、每個別名 parse 到正確 case。
- 注意三組名字不同:canonical label(`agy`)、integration 名(`antigravity-cli`)、hook source(`herdr:antigravity_cli`)、可執行檔(`kiro-cli`)。`AgentID` 只正規化 label;其他名字若需要，放進 profile 的欄位，不要再做字串比對。【一手】出處見 1.1、1.3。
- 不要用 `display_agent`／`terminal_title` 判斷身分(socket-api.mdx 明說只是顯示用)。
- 「相容」不等於「相同」:Grok 會匯入 Claude 的 hook(1.3),Cursor 也宣稱支援 Grok Build(ACP agents 清單)。若某 dialect 想讓 A 直接沿用 B 的實作，應在 profile 裡**明確指定**(例：`grok.transcript = nil`,而不是因為格式像就套 Claude parser),並標未驗證。

### 6.5 parser 的驗證狀態

- 學 herdr manifest 的註解習慣：每個 dialect 帶 **驗證紀錄**(看過的 agent 版本範圍、來源是真主機錄製還是推測)。可以是 profile 裡的靜態欄位(例：`verifiedVersions: "Claude Code 2.1.2xx–2.1.3xx"`),配合 `tests/PurrdrTestSupport/Fixtures/` 的錄製檔，讓「哪個 parser 有實錄佐證」一眼可見。
- herdr 的 manifest 會遠端熱更新，Purrdr 無法(App Store 發版週期)。所以 Purrdr 的畫面 dialect 比 herdr 更需要**失敗時安靜退化**,並把「對不上」記到 `os.Logger`(像 `transcript-follow` 那樣)以便收集新畫面。可考慮在 dialect 失配時附帶 herdr `agent explain` 的結果當診斷。【推論】
- 能交給 herdr 的就交給 herdr:needs-you 的「是否 blocked」herdr 已經判斷並維護 manifest;Purrdr 的畫面 dialect 只需要負責 herdr 不提供的部分(選項內容、answer keys、/model 與 /effort 面板內容)。重複判斷 blocked 會和 herdr 的熱更新規則漂移。

### 6.6 風險清單

| 風險 | 說明 | 緩解 |
|---|---|---|
| Claude transcript 格式變動 | 官方明說 internal、隨版本改 | 部分失敗、記錄版本、優先用 hooks／statusline 的欄位 |
| 畫面字串隨版本改 | herdr 的 claude manifest 已因 2.1.228 改 spinner 而更新 | 只解析 herdr 不提供的部分;失配記 log;fixture 標版本 |
| 別名漂移 | herdr 新增 agent 或別名時，Purrdr 未更新 | 未知值落到 `.other(String)` + generic profile,而不是 crash 或誤套 Claude |
| 「像 Claude」的 agent | Grok 匯入 Claude hook 等相容行為 | profile 明確指定沿用、標未驗證，不靠格式猜 |
| 過早採用 ACP | 需要改變 agent 啟動方式，和 herdr pane 模型衝突;v2 仍在 Preview | 只讓 dialect 輸出型別與 ACP 語意對齊，協定接入留給未來的主機服務 |
| 能力旗標膨脹 | Crystal 式布林旗標容易變成一長串 `supportsX` | 用 optional dialect 值本身表達有無，而不是另加旗標 |

## 參考資料(一手)

- herdr 原始碼與文件(commit `e8d7d970`):https://github.com/herdrdev/herdr/tree/e8d7d9705a7a2c89cef4dd42079379f05685af87 ——`src/detect/mod.rs`、`src/detect/manifests/`、`docs/versions/0.9.5/website/src/content/docs/{agents,integrations,add-herdr-support,socket-api}.mdx`
- Agent Client Protocol(commit `01a54c84`):https://github.com/agentclientprotocol/agent-client-protocol/tree/01a54c84f39508f73fab4d41362baf51e1320374/docs ——`protocol/v1/*`、`protocol/v2/migration.mdx`、`get-started/agents.mdx`
- claude-agent-acp:https://github.com/zed-industries/claude-code-acp/tree/4af4581ad510a85d5cdfa3b9100412479e1cfef4
- codex-acp(舊址):https://github.com/zed-industries/codex-acp/tree/296069e841634cd4bb9bc4515602d836e49231ec
- Claude Code:https://code.claude.com/docs/en/headless 、https://code.claude.com/docs/en/sessions 、https://code.claude.com/docs/en/statusline
- Codex:https://learn.chatgpt.com/docs/app-server 、https://learn.chatgpt.com/docs/non-interactive-mode.md
- Gemini CLI:https://geminicli.com/docs/cli/headless.md
- Antigravity CLI:https://antigravity.google/docs/cli/headless.md 、https://antigravity.google/docs/cli/acp/
- OpenCode:https://opencode.ai/docs/server/
- claude-squad:https://github.com/smtg-ai/claude-squad/tree/070eb9387cda2be2e64aa1a32ee81be160c457a1
- Crystal:https://github.com/stravu/crystal/tree/1e18e0bc981225f75b5226f82a300fa741970c6f
- Zed:https://zed.dev/docs/ai/external-agents
- VS Code:https://code.visualstudio.com/docs/copilot/agents/third-party-agents
- Warp:https://docs.warp.dev/agents/cli-agents/overview/
