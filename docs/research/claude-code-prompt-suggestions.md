# Claude Code 的 prompt suggestion(建議提示詞)

- 查詢日期:2026-11-17
- 本機 Claude Code 版本:2.1.326(`claude --version`)
- 用途:issue #121(聊天視窗顯示 Claude Code 的建議提示詞)的一手來源研究
- 來源只採用 Claude Code 官方文件(code.claude.com/docs)、官方 CHANGELOG(github.com/anthropics/claude-code)與本機 `claude --help`。官方沒寫的一律標「**官方未載明**」。

主要來源頁面:

| 簡稱 | 網址 |
| :- | :- |
| Interactive mode | https://code.claude.com/docs/en/interactive-mode#prompt-suggestions |
| Settings reference | https://code.claude.com/docs/en/settings-reference#promptsuggestionenabled |
| Env vars | https://code.claude.com/docs/en/env-vars |
| CLI reference | https://code.claude.com/docs/en/cli-reference#cli-flags |
| Agent SDK(TypeScript) | https://code.claude.com/docs/en/agent-sdk/typescript |
| Agent loop | https://code.claude.com/docs/en/agent-sdk/agent-loop |
| Hooks | https://code.claude.com/docs/en/hooks |
| Mods reference | https://code.claude.com/docs/en/plugins/mods/reference |
| Mods interface | https://code.claude.com/docs/en/plugins/mods/interface |
| Desktop | https://code.claude.com/docs/en/desktop#accept-a-suggested-prompt |
| VS Code | https://code.claude.com/docs/en/vs-code#use-or-turn-off-suggested-prompts |
| Costs | https://code.claude.com/docs/en/costs |
| CHANGELOG | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md |

---

## 1. 官方名稱與版本沿革

**名稱**:官方文件稱為 **Prompt suggestions**(`/config` 的開關名稱也是「Prompt suggestions」);settings key 是 `promptSuggestionEnabled`,環境變數是 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`,CLI flag 是 `--prompt-suggestions`,SDK 訊息型別是 `prompt_suggestion`(`SDKPromptSuggestionMessage`)。Desktop／VS Code 文件也稱「suggested prompt」「suggested next prompt」。(Interactive mode、Settings reference、Desktop、VS Code)

**加入版本**:**官方未載明**。CHANGELOG 最早提到 prompt suggestions 的是 2.0.70(已在修 Tab 行為),所以功能在 2.0.70 之前就已存在,確切版本 CHANGELOG 沒寫。

**CHANGELOG 中與本功能相關的變更**(版本 → 條目,出處皆為 CHANGELOG):

| 版本 | 變更 |
| :- | :- |
| 2.0.70 | Added Enter key to accept and submit prompt suggestions immediately (tab still accepts for editing);Fixed prompt suggestions replacing typed input when pressing Tab |
| 2.0.71 | Added /config toggle to enable/disable prompt suggestions |
| 2.1.49、2.1.50、2.1.62 | Fixed prompt suggestion cache regression that reduced cache hit rates |
| 2.1.136 | Fixed prompt suggestions being auto-submitted by Enter on an empty input instead of requiring Tab or arrow to accept(**推翻 2.0.70 的 Enter 直接送出**) |
| 2.1.141 | Fixed prompt suggestions being silently disabled when an output style was configured |
| 2.1.238 | Fixed `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true` not keeping prompt suggestions on when your account is near, but not over, its usage limit |
| 2.1.257 | 設了 advisor model 時,背景請求(含 prompt suggestions)沒吃到 prompt cache 的問題修正 |
| 2.1.268 | Fixed SDK prompt suggestions … sending the conversation from before a compaction |
| 2.1.269 | 修正日文、中文、泰文等不以空白分詞的語言,建議被丟掉;改進中日韓文的建議過濾(保留混合文字與單詞建議,丟掉 meta／評論性文字) |
| 2.1.283 | Changed prompt suggestions in the terminal to appear less often after 20 in a row go unused; using one brings them back |
| 2.1.288 | Fixed prompt suggestions not appearing on a phone that joins a Cowork cloud session started on another device |
| 2.1.290 | [Cloud sessions] 以 cloud environment 的環境變數關閉 prompt suggestions 無效的問題修正 |
| 2.1.295 | [VSCode] Ctrl+Tab 會接受建議的問題修正 |
| 2.1.302 | Fixed prompt suggestions spending usage credits on models your plan pays for only with credits: they are now skipped after a reply billed to credits |
| 2.1.321 | Fixed prompt suggestions making extra API requests when the model replied with a tool call |
| 2.1.325 | Changed prompt suggestions in the terminal to refresh less often after 8 turns in a row started by background or scheduled tasks…;[VSCode] Added prompt suggestions wherever the terminal shows them: Tab accepts…;`promptSuggestionEnabled: false` turns them off |
| 2.1.326 | Fixed the suggested next prompt sometimes being a bare tag, such as `<signal type="empty" />`;[VSCode] 新增 `claudeCode.promptSuggestions` 設定可關閉 |

## 2. 何時出現／不出現

### 2.1 產生方式

Claude 回覆後,Claude Code 依對話紀錄建議下一句 prompt,以**一個短的背景請求、用 session 正在用的同一個 model** 產生;重用對話的 prompt cache,成本主要是 cache read 加少量 output token,計入方案用量或 API 費用。(Interactive mode、Costs)

另有一種灰色文字:**session 剛開啟時**,輸入列會顯示一段灰色的範例指令,取自專案的 git 歷史。(Interactive mode)

### 2.2 開關

| 方式 | 說明 | 來源 |
| :- | :- | :- |
| `/config` 的 **Prompt suggestions** | 寫入 `promptSuggestionEnabled` | Interactive mode、Env vars |
| settings `promptSuggestionEnabled` | Boolean,**預設 `true`**,任何設定檔都可放;`false` 隱藏建議 | Settings reference |
| 環境變數 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` | `false` 關閉;**優先於** `promptSuggestionEnabled`(單一 session 覆寫);`true` 讓「接近用量上限時暫停」不套用,直到真的到上限(需 v2.1.238+) | Env vars、Settings reference |
| 組織 | managed settings 設 `promptSuggestionEnabled: false`,並在 managed `env` 設 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` 防止使用者以環境變數打開 | Interactive mode |
| CLI `--prompt-suggestions` | print 模式專用,見 §5 | CLI reference |

**帳號／遙測前提**(Settings reference,`promptSuggestionEnabled` 段):「Prompt suggestions need a claude.ai or Console account with telemetry on.」在 Amazon Bedrock、Google Cloud Agent Platform、Microsoft Foundry,或關閉遙測(例如 `DISABLE_TELEMETRY`)時,這個 key 無效,**只有 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1` 能打開**。

**Feature flag**(Interactive mode「When Claude Code skips suggestions」、Env vars「Features that need feature-flag fetching」「First session after an install or upgrade」):在不抓 feature flag 的 session(設了 `CLAUDE_CODE_DISABLE_FEATURE_FLAGS`、`DISABLE_TELEMETRY`、`DO_NOT_TRACK`、`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`;第三方 provider;Claude apps gateway),以及**安裝或升級後第一個 flag 還沒抓到的 session**,互動模式**預設關閉**建議,`/config` 也不顯示該開關。flag 抓到後存在本機,下一個 session 才有。

### 2.3 個別一輪被跳過的情況(Interactive mode,官方原文為「including」,即**不保證完整**)

- prompt cache 是冷的(省成本)
- 「After the first turn of a conversation, in some sessions」(某些 session 的第一輪之後)
- 上一個回應以錯誤結束
- **plan mode** 中
- 帳號接近或達到用量上限(見上,環境變數 `true` 可延後到真的到上限)
- agent team 中,teammate 的 session 預設不顯示(lead 會顯示)

其他(CHANGELOG):

- 回覆是以 usage credits 計費的 model 時跳過(2.1.302)
- 連續 20 個建議沒被使用後**變少出現**,畫面出現 `Showing fewer prompt suggestions · use one to bring them back`;用一次或設環境變數 `true` 恢復(2.1.283;Interactive mode 也有說明)
- 連續 8 輪由背景／排程任務開始時,終端機上的建議**較少更新**,直到按鍵或回到終端機(2.1.325)
- 2.1.141 之前,設定 output style 會讓建議被默默關掉(已修)

### 2.4 與特定條件的關係

| 條件 | 官方說法 |
| :- | :- |
| permission mode | 只有 **plan mode** 明確列為跳過;其他 mode(含 `bypassPermissions`、auto)**官方未載明**有影響 |
| 非互動(`-p`)模式 | 預設**不產生**;需 `--prompt-suggestions` + `--output-format stream-json` + `--verbose`;非常短的對話與冷 cache 一樣跳過,單一短 `-p` 可能完全沒有(Interactive mode、CLI reference) |
| 用量 | 接近／達到上限時暫停(見上) |
| model | 用 session 的同一個 model 產生;credits 計費的 model 跳過。其他 model 限制**官方未載明** |
| 第三方 provider／關遙測 | 只有環境變數 `=1` 能開 |

### 2.5 本機觀察對照(唯讀檢查,未改設定)

- `~/.claude/settings.json` 沒有 `promptSuggestionEnabled`(即預設 `true`);shell 沒有設 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`、`DISABLE_TELEMETRY`、`DO_NOT_TRACK`、`CLAUDE_CODE_DISABLE_FEATURE_FLAGS`、`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`。
- `~/.claude.json` 裡的 `tengu_prompt_suggestion: true` 是快取的內部 feature flag;**這個 key 的意義官方未載明**,不能拿來判斷建議是否會出現。
- 兩輪都沒看到建議,官方列出的可能原因有:冷 prompt cache、「某些 session 的第一輪之後」跳過、plan mode、上一輪錯誤、接近用量上限、連續 20 個沒用而降頻、升級後第一個 session 尚未抓到 flag(本機剛升級到 2.1.326 時有可能)。官方沒有提供查詢「這一輪為何沒有建議」的方法(**官方未載明**)。

## 3. 接受／忽略

終端機(Interactive mode):

- **Tab** 或 **→(Right arrow)**:把建議放進輸入列(可編輯),再按 **Enter** 送出
- **開始打字**:建議消失
- **空輸入列直接按 Enter**:不送出建議。2.0.70 曾改成 Enter 直接接受並送出,但 2.1.136 修正為「需要 Tab 或方向鍵才接受」(CHANGELOG)

Desktop 的 Code tab:Tab／→ 放入輸入框,Enter 送出;未接受前按 Enter 不送;建議只在輸入框空白且沒有附件時顯示;關閉開關後下次開啟或 resume 才生效。(Desktop)

VS Code:Tab 轉成可編輯文字;未接受前 Enter 不送;開始打字隱藏。(VS Code)

是否可以用 keybindings 重新綁定「接受建議」:**官方未載明**(keybindings 文件的 `autocomplete:accept`(Tab)是自動完成清單的動作,沒有說涵蓋 prompt suggestion)。

## 4. 終端機上的呈現

- 官方描述為輸入列中的「grayed-out predictions」(Settings reference、Env vars),mods 文件稱之為「the prompt box's dim suggestion text」(Mods interface)。
- 位置:prompt input(輸入列)裡。session 開始時的 git 範例指令同樣是輸入列裡的灰色文字(Interactive mode)。
- 確切的 ANSI 屬性(SGR 2 dim、特定 256 色或 truecolor 灰)、是否受主題影響:**官方未載明**。要以真實主機錄的 `pane.read` ansi 畫面為準。
- Desktop:空輸入框中的灰色文字;VS Code:灰色斜體(Desktop、VS Code)。

注意會與建議混淆的其他灰色文字(對 #121 辨識器有影響):

- session 剛開時的 git 範例指令(也在輸入列,也是灰色)
- 已送出但尚未開始處理的排隊訊息顯示為灰色(Interactive mode「Queue messages while Claude works」,但位置在對話中的清單,不在輸入列)

## 5. 程式化取得建議文字

| 管道 | 能否拿到建議文字 | 來源 |
| :- | :- | :- |
| `claude -p --prompt-suggestions --output-format stream-json --verbose` | **可以**,每輪有產生時輸出 `prompt_suggestion` 訊息 | CLI reference、Interactive mode |
| Agent SDK(TypeScript)`promptSuggestions: true` | **可以**,`SDKPromptSuggestionMessage { type: "prompt_suggestion"; suggestion: string; uuid; session_id }`;可能在 `ResultMessage` 之後才到,要把串流讀完 | Agent SDK、Agent loop |
| Hooks | **不行**。唯一相關是 `SubagentStop` 會在產生建議的內部 agent 結束時觸發(`agent_type` 為空或 session 本身的 agent 名),但 input 只有 `last_assistant_message` 等欄位,官方沒說它就是建議文字 | Hooks |
| statusline JSON 輸入 | 文件列出的欄位沒有建議文字(**官方未載明**有此欄位) | https://code.claude.com/docs/en/statusline |
| transcript JSONL | **官方未載明**建議是否寫入 transcript | — |
| Mods(v2.1.287+ 終端機) | 事件 `prompt.suggest`:「Text is about to go into the prompt box … as a dim suggestion」,hook 可 `next(e)` 改文字;另有 `$.prompt.suggest`、`$.prompt.read`。**是否涵蓋 Claude 自己產生的 prompt suggestion,官方未載明**;且需要在主機安裝 mod(屬於寫入主機,依 ADR-0002 要走 `ReversibleHostWrite`) | Mods reference、Mods interface |

結論:對**已在 herdr Pane 裡跑的互動式 Claude Code**,官方沒有提供讀出建議文字的介面;stream-json／SDK 管道只適用於由我們自己啟動的 print／SDK session,不適用於使用者在終端機開的 session。因此 #121 從 Pane 畫面(含 ANSI)辨識是目前唯一不需在主機安裝東西的方式;mods `prompt.suggest` 是值得實測的備案。

## 6. 其他與 #121 相關的事實

- **中文建議**:2.1.269 之前,中文等不以空白分詞的語言的建議會被丟掉;繁中使用者需 2.1.269+(CHANGELOG)。
- **異常內容**:2.1.326 之前建議可能是 `<signal type="empty" />` 這種裸標籤(CHANGELOG),辨識器遇到可考慮過濾。
- **頻率不固定**:建議在 20 個未使用後降頻、背景任務連續 8 輪後少更新,所以「完成狀態卻沒建議」是正常情況,UI 不能假設每輪都有。從手機接受建議(實際送出該文字)是否算「使用」而讓頻率恢復:**官方未載明**(終端機上 Claude Code 看到的只是使用者輸入了同樣文字)。
- **建議只在輸入列空白時顯示**(Desktop 明載;終端機「開始打字即消失」)——與 issue User Story 4、12 一致:輸入列有一般顏色的字就不會同時有建議。
- **session 開頭的 git 範例指令**也是輸入列裡的灰字,不是「Claude 回完一輪後的建議」;官方沒有說兩者畫面上可區分(**官方未載明**)。若只想顯示「下一句建議」,辨識器需要額外條件(例如對話中至少有一輪 assistant 回覆),或接受也顯示範例指令。
- **plan mode 不出現**:Agent 在 plan mode 完成一輪後不會有建議。
- **成本**:每個建議都是一次背景請求,由主機上的使用者帳號付費;Purrdr 只讀畫面,不會增加請求。
- **Remote Control／手機**:2.1.288 修正「手機加入另一台裝置開的 Cowork cloud session 時看不到建議」,表示 Claude 官方 app 端有建議的同步機制,但其協定**官方未載明**,不能拿來用。
- **mods 的 panel**:在 mods panel 中 `$.prompt.suggest` 回 `isShown: false`,因為輸入框的 dim 建議文字保留給 Claude 自己的建議(Mods interface)——佐證終端機上「dim 建議文字」只有一個位置、同時只有一句。
