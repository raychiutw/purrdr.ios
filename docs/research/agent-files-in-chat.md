# Agent 在主機上產生的檔案，怎麼在聊天裡顯示與開啟(截至 2026-11-19)

> **結論**
> 1. **Purrdr 現在完全看不到 agent 產生的檔案**:對話紀錄在主機上就把圖片 base64 剝掉(R-B04),解析器丟掉 `tool_result` 裡的圖片區塊，工具列只顯示一行路徑文字，訊息裡的檔案路徑不可點(R-V03 只開 http(s)),也沒有任何「從主機下載任意檔案」的通道(`HostFiles` 只讀家目錄下、字元受限、≤1 MiB 的 Purrdr 自己的設定檔;HTTPS 主機服務協定沒有檔案方法)。
> 2. **herdr 沒有檔案或 artifact API**,pane 裡也只有 http(s) 連結可點，檔案路徑不是連結。HerdrChat 依行為規格也沒有聊天內的檔案卡片，只有 Computers 分頁的檔案瀏覽器下載(25 MB、存快取後開分享表)。
> 3. **Heeler 是唯一做了的實作**:從對話紀錄的工具紀錄(Claude `Read` 圖片、Codex `view_image`／圖片生成的 `saved_path` 等)與訊息中的圖片路徑取得**主機路徑**,經既有的唯讀 SFTP 在畫面上需要時讀取(上限 20 MiB、> 8 MiB 等點擊)、縮圖只放記憶體；只做圖片，不做 PDF／一般檔案預覽。
> 4. 給 Purrdr 的建議(依優先順序):**① 可攜核心的「Agent 檔案參照」解析(純計算，最便宜、最先做)→ ② 主機檔案取用 port(SSH exec 串流 + HTTPS 主機服務新訊息兩個 adapter)→ ③ 圖片縮圖 + 其他格式 QuickLook／ShareLink → ④ 訊息內路徑可點(只在 app 內開)→ ⑤ HTTPS 的取檔授權規則**。

> 標記:**【文件】** 官方文件；**【原始碼】** 官方 repo 原始碼(固定 commit);**【Repo】** 本 repo 檔案與行號(`master` `4f5ca66`);**【Heeler】** Heeler 原始碼(固定 commit,只用自己的話描述，不貼程式碼);**【規格】** `docs/research/herdrchat-behavior-spec.md`(ADR-0001:HerdrChat 只依這份規格與公開文件);**【推論】** 由前述推得、未直接驗證；**【未查得】** 找不到一手來源。
>
> 版本:herdr `herdrdev/herdr` commit `ee5bfb5`(v0.9.5);Heeler `ZingerLittleBee/Heeler` commit [`4db5ce0`](https://github.com/ZingerLittleBee/Heeler/commit/4db5ce0ccb02842820603595d399f95ad6adfc89)(2026-11-19,下稱 `H@4db5ce0`);Codex `openai/codex` commit `b5e1f3a`。Heeler 原始碼只在暫存區閱讀、未執行或建置。

---

## 1. Purrdr 現況盤點

### 1.1 對話紀錄 → 訊息片段

| 遇到的東西 | 現在怎麼處理 | 出處 |
|---|---|---|
| 對話紀錄行裡的圖片 base64 | 主機上先以 `sed` 把長度 ≥128 的 base64 引號字串與 `data:…;base64,…` 換成 `""`,app 收到的行已沒有圖片資料 | 【Repo】`src/PurrdrCore/TranscriptCommand.swift:9-10`、`:461`;【規格】R-B04(`herdrchat-behavior-spec.md:944`、`:1468`) |
| Claude `tool_use`(Write／Edit／Read…) | 變成 `toolCall(name, input, path)`;`path` 取 `file_path`／`notebook_path`／`path`;`input` 是最多 2,000 字的扁平預覽(Write 的 `content` 不在預覽裡，因為 `file_path` 先命中) | 【Repo】`src/PurrdrCore/ClaudeTranscriptParser.swift:51-60`、`:67-91` |
| Claude `tool_result` | 只取 `content` 裡的 `text`,**圖片區塊被丟掉**;最多 4,000 字 | 【Repo】`ClaudeTranscriptParser.swift:129-134`、`:143-147` |
| Claude 行的頂層 `toolUseResult`(`filePath`、`type` 等結構化結果) | **沒有解析** | 【Repo】`ClaudeTranscriptParser.swift` 全檔無此鍵 |
| 使用者訊息的 `image` 區塊 | 只計數(`images(Int)`);Purrdr 自己上傳的圖片依 `[Image: source: …]` 或 `~/.purrdr/uploads/` 路徑行，找手機上的副本顯示 | 【Repo】`ClaudeTranscriptParser.swift:122-139`、`src/PurrdrCore/UploadedImages.swift:20-53`、`src/PurrdrAgentFeatures/ConversationModel.swift:213-220` |
| Codex `image_generation_call` | 只成為一個工具呼叫(輸入是 revised prompt),`path: nil`;沒有讀 `image_generation_end` 的 `saved_path`,也沒有把 `view_image` 的 `path` 當成檔案 | 【Repo】`src/PurrdrCore/CodexTranscriptParser.swift:57-59` |
| 片段模型 | `TranscriptPart` 沒有「檔案」或「agent 產生的圖片」種類；工具步驟 `ToolCallStep` 只有 `path: String?` 與文字結果 | 【Repo】`src/PurrdrCore/TranscriptMessage.swift:29-52`、`src/PurrdrCore/Conversation.swift:124-131` |

### 1.2 畫面

- 工具串預設收合成一行摘要;展開後每個呼叫一列(名稱 + 一行等寬的輸入)，有結果可再展開看最多 12 行。`path` 沒有用在畫面上(沒有卡片、沒有點擊動作)。【Repo】`src/PurrdrFeatures/ConversationView.swift:557-605`
- agent 的 markdown:連結只接受有主機的 http(s),其他 scheme 與相對路徑只留文字(R-V03);沒有 `![]()` 圖片語法。【Repo】`src/PurrdrCore/Markdown.swift:16`、`:52-58`、`:300-308`;【規格】`herdrchat-behavior-spec.md:375`
- 圖片顯示只存在於**使用者泡泡**:手機上有副本才畫縮圖，點開全螢幕檢視(`imageViewer`);沒有副本時顯示「Image」標籤。【Repo】`ConversationView.swift:66-69`、`:476-484`;`src/PurrdrFeatures/ComposerImageViews.swift:27-30`、`:120-126`
- 專案內沒有使用 QuickLook、`ShareLink` 或 `openURL` 開檔。【Repo】`grep` `src/` 無結果

### 1.3 主機檔案讀取能力

- `HostFiles.read`:一次往返讀多個檔，**每個最多 1 MiB**;路徑是相對家目錄的 `HostPath`,只允許 `[A-Za-z0-9._-/]`、不得有 `.`／`..`。設計對象是 Purrdr 自己的設定檔(主題、You should know、用量)。【Repo】`src/PurrdrSSH/HostFiles.swift:41-47`、`src/PurrdrCore/HostFileTypes.swift:152-158`、`src/PurrdrCore/HostFileScript.swift:16`
- 一次性指令長度上限 126 KiB。【Repo】`HostFileScript.swift:14`
- swift-nio-ssh 沒有 SFTP(ADR-0003),先前評估也**不建議**加 SFTP(不能在主機上先剝圖、Windows `sftp-server.exe` 持有 handle 會擋 rename 覆蓋)。【Repo】`docs/adr/0003-swift-nio-ssh-no-rsa.md:3`、`docs/research/ssh-transcript-channel-evaluation.md:5-7`
- 資料夾瀏覽只有列出與上傳，沒有下載。【Repo】`src/PurrdrSSH/HostFolders.swift:175-216`
- HTTPS 主機服務協定只有 agents、events、pane、transcript 方法，**沒有檔案讀取**;對話紀錄只允許 herdr snapshot 回報的 session,app 不能指定路徑。【Repo】`protocol/host-service.schema.json:284`、`host-service/service/src/connection.rs:472`
- Agent 的 `cwd` 已在 Agent 型別裡(來自 snapshot),可當相對路徑的基準與授權範圍。【Repo】`src/PurrdrCore/Agent.swift:22`

**小結**:agent 寫了 `report.md`、截了圖、產生了圖片，Purrdr 使用者只會在收合的工具串裡看到一行灰字路徑，沒辦法看內容。

---

## 2. 各實作的做法

### 2.1 herdr

- socket API 沒有 file／attachment／artifact 方法;舊的 `pane.graphics.*` 已移除且沒有替代。【文件】詳見 `docs/research/herdr-file-transfer-and-image-upload.md` §1.1(`docs/socket-api.mdx:93-113`、`:179-188`)
- pane 內只有 http(s) 連結可開:`safe_web_url` 只放行 `http://`／`https://`,測試明確斷言 `file:///tmp/a`、`javascript:` 不成為連結區域，`open file:///tmp/report` 選不到網址。【原始碼】[`src/app/actions.rs:1053-1055`](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/app/actions.rs#L1053-L1055)、[`:2406-2416`](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/app/actions.rs#L2406-L2416)、[`:2567`](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/app/actions.rs#L2567)
- `file://` 只出現在 OSC 7(shell 回報工作目錄),用來追 pane 的 cwd。【原始碼】[`src/pane/osc.rs:340`](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/pane/osc.rs#L340)、[`:665`](https://github.com/herdrdev/herdr/blob/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/pane/osc.rs#L665)
- 0.9.x 新增 Ctrl 懸停高亮、OSC 8 連結在視窗外仍可點(仍是網址)。【文件】`docs/next/CHANGELOG.md`(#1282)

→ herdr 不提供取檔方式，Purrdr 只能自己取(SSH)或經主機服務(HTTPS)。

### 2.2 HerdrChat(只依行為規格與公開文件)

- 連結只開 http(s),其他 scheme 與相對路徑當純文字。【規格】F5.10,`herdrchat-behavior-spec.md:375`
- 圖片只處理使用者上傳的(泡泡依檔名找本地副本，找不到顯示「圖片」標籤);對話紀錄的圖片 base64 在主機上剝除。【規格】F7,`:460`;R-B04,`:944`、`:1468`
- 主機檔案只能從 Computers 分頁的檔案瀏覽器下載：確認是檔案且 ≤25 MB,以 base64 傳回、存 App 快取、開系統分享表。【規格】F13,`:534`
- 聊天中顯示 agent 產生的檔案、工具結果圖片、點路徑開檔:規格與 README 都沒有。【未查得】

### 2.3 Heeler(`H@4db5ce0`)

**哪些東西變成「圖片列」**:只取對話紀錄的**中繼資料**裡記錄的主機路徑，不把顯示標題當路徑。
- Claude Code:`Read`／`NotebookRead` 且結構化結果的 `type` 是 `image` 時，取輸入的絕對 `file_path`。【Heeler】[`Chat/Claude/ClaudeToolSummary.swift:190-197`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Claude/ClaudeToolSummary.swift#L190-L197)
- Claude Code 的 Write／Edit:從行頂層 `toolUseResult` 的 `type`(`create`／`update`)、`filePath`、`structuredPatch` 或建立時的內容組出**檔案變更與 diff**(列展開看 diff,最多 40 行／32 KiB,更多時重讀該行)。【Heeler】[`Chat/Claude/ClaudeTranscriptRecord.swift:224-260`、`:516-545`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Claude/ClaudeTranscriptRecord.swift#L516-L545);[ADR 0024:430-437](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/docs/adr/0024-native-chat-from-agent-transcripts.md#L430-L437)
- Codex:`view_image` 的 `path`、`ImageView` 項目、圖片生成結束事件的 `saved_path`。【Heeler】[`Chat/Codex/CodexRecordDecoder.swift:463-470`、`:704-707`、`:811-826`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Codex/CodexRecordDecoder.swift#L811-L826)
- 其他 agent(Grok、Pi／Oh My Pi、OpenCode、Antigravity)各有對應規則。【Heeler】[ADR 0024:472-489](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/docs/adr/0024-native-chat-from-agent-transcripts.md#L472-L489)
- 相對路徑只對**該行記錄的工作目錄**解析，`~/` 只在知道家目錄時解析，其他(scheme、磁碟相對路徑)一律不解析。【Heeler】[`Chat/Source/ChatImagePreviewReader.swift:11-36`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Source/ChatImagePreviewReader.swift#L11-L36)

**訊息裡的路徑**:inline code、程式碼區塊的一行、連結或 markdown 圖片的目的地、文字裡的絕對／`~/` 路徑，只要指向圖片副檔名就畫成連結;**點之前不讀檔**;相對路徑在文字中不認(避免 `and/or.png`),開啟時才對 agent 的目前 cwd 解析。【Heeler】[`Chat/Timeline/ChatImageLink.swift:1-12`、`:74-107`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Timeline/ChatImageLink.swift#L74-L107)、[`Chat/Conversation/AgentChatStore.swift:721-736`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L721-L736)。終端機輸出則只索引 http(s) 連結(最多 20 個、只放記憶體)。【Heeler】[ADR 0010](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/docs/adr/0010-index-attach-links-from-terminal-output.md)

**怎麼取檔**:沿用讀對話紀錄的**唯讀 SFTP 連線**,不在主機執行指令。先 stat(一般檔案、非空、≤20 MiB),再每塊 256 KiB 讀取;讀取中長度變了就丟「讀取中變更」。【Heeler】[`ChatImagePreviewReader.swift:57-96`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Source/ChatImagePreviewReader.swift#L57-L96)

**流量、大小與快取**:
- 縮圖只在列出現在畫面上時讀，每個 agent 一次一個檔，列離開畫面就取消;> 8 MiB 等使用者點。【Heeler】[`Chat/Conversation/ChatImageThumbnails.swift:46-50`](https://github.com/ZingerLittleBee/Heeler/blob/4db5ce0ccb02842820603595d399f95ad6adfc89/Sources/Heeler/Chat/Conversation/ChatImageThumbnails.swift#L46-L50);ADR 0024:500-505
- 在主執行緒外以 ImageIO 降採樣：縮圖長邊 1,024 px、全螢幕 4,096 px,拒絕超過 2 億像素的圖。【Heeler】`ChatImagePreviewReader.swift:125-153`
- 解碼後的縮圖只放記憶體 `NSCache`(像素成本上限 48 MiB),鍵是「路徑 + 大小 + 修改時間」,同路徑重寫(agent 常覆寫同名截圖)會重讀；圖片 bytes 不跟對話紀錄一起快取;離線時顯示本次執行已有的副本。【Heeler】`ChatImageThumbnails.swift:236-258`;ADR 0024:506-512
- 縮圖高度固定，只變寬，圖到了不改列高。【Heeler】ADR 0024:504-505
- 預覽：可縮放的 sheet,長按預覽。【Heeler】`Chat/Timeline/ChatImagePreviewController.swift:1-13`
- **不做**:PDF、markdown、程式碼等非圖片檔的預覽或下載;沒有用 QuickLook 或分享表(`grep` 無 `QLPreview`、`ShareLink`)。【Heeler】
- 授權範圍：沒有限制在 agent 目錄內，靠「路徑只來自對話紀錄中繼資料或使用者點的訊息路徑」與 SFTP 使用者本身的權限。【推論】由上述程式碼推得

### 2.4 Claude Code 與 Codex 對話紀錄裡會出現什麼

**Claude Code**
- 官方工具清單:`Write` 建立或覆寫檔案、`Edit` 修改、`Read` 讀檔;`Read` 對 PNG／JPEG／GIF／WebP 回傳「Claude 看得到的視覺內容」(會縮圖重壓),PDF 依頁讀取，notebook 回傳含視覺化輸出的 cells;`.heic`、`.zip` 等被當二進位拒絕。【文件】<https://code.claude.com/docs/en/tools-reference>(工具表與「Read tool behavior」)
- **`SendUserFile` 工具**:把 session 中的檔案(「generated report, diagram, screenshot, or built artifact」)送到使用者裝置，`display` 可為 `render`(在 client 內嵌顯示)或 `attach`(只顯示下載卡片);**只在 Remote Control client 連著或雲端 session 時可用**,經 Anthropic 基礎設施傳送。【文件】同頁工具表 `SendUserFile` 列。在 herdr pane 裡的一般 session 通常沒有這個工具【推論】;它的輸入欄位除 `display` 外【未查得】。
- PostToolUse hook 的官方範例:`Write` 的 `tool_input` 是 `{file_path, content}`,`tool_response` 是 `{filePath, type: "create"}`。【文件】<https://code.claude.com/docs/en/hooks>(PostToolUse input)
- 對話紀錄 jsonl 的格式本身沒有官方 schema;hooks 文件只說 `transcript_path` 是「Path to conversation JSON」且可能落後。【文件】同頁 common input fields;完整 schema【未查得】
- 實際紀錄(本 repo 錄製檔):`assistant` 行的 `tool_use` 帶 `input.file_path`;`user` 行的 `tool_result` 是字串或區塊陣列;每行有 `cwd`。【Repo】`tests/PurrdrTestSupport/Fixtures/claude-code/session.jsonl:22-23`。行頂層的 `toolUseResult` 在 `delegation.jsonl` 出現(Agent 工具)。【Repo】`Fixtures/claude-code/delegation.jsonl:2`、`:5`
  - Write、Edit、Read 圖片、MCP 工具結果帶圖的樣本已於 #223 錄製(`Fixtures/claude-code/agent-files.jsonl`),實際格式見下方「錄製樣本的實際欄位格式」。
  - Write 的 `toolUseResult` 與 hook 的 `tool_response` 同形(`filePath`、`type: create／update`、`structuredPatch`)是 Heeler 的解析依據【Heeler】;#223 錄製證實，另多了 `content`、`originalFile`、`userModified`【Repo】。
- MCP 截圖工具的結果:2.1.328 實測**會把圖另存到主機檔案**,並在 `tool_result` 與 `toolUseResult` 加一段 `[Image: source: <路徑>]` 文字(見下方)。所以主機上剝掉 base64 後，仍可經這個路徑取回圖片【Repo】`agent-files.jsonl:11`。舊版本或其他工具是否也這樣【未查得】。

#### 錄製樣本的實際欄位格式(#223,Claude Code 2.1.328,Windows 主機)

來源：`tests/PurrdrTestSupport/Fixtures/claude-code/agent-files.jsonl`(錄製方式與去個資規則見 Fixtures README)。以下都是**實測**,不是官方 schema;版本更新可能改名。

**共通**:工具呼叫在 `assistant` 行的 `message.content[]`,`{type:"tool_use", id, name, input, caller:{type:"direct"}}`;結果在下一個 `user` 行，
`message.content[]` 的 `{tool_use_id, type:"tool_result", content}`(`content` 是字串或區塊陣列),同一行頂層有 `toolUseResult`(結構化結果)與 `sourceToolAssistantUUID`(指回呼叫那一行的 `uuid`)。
每行有 `cwd`(錄製主機是 Windows,路徑是反斜線的 `C:\…`)。`tool_use.input.file_path` 是**絕對路徑**(prompt 給的是相對檔名，CLI 已解析)。

| 情境 | `tool_use.input` | `tool_result.content` | 行頂層 `toolUseResult` |
|---|---|---|---|
| `Write` 新建 | `{file_path, content}` | 字串 `File created successfully at: <路徑> (…)` | `{type:"create", filePath, content, structuredPatch:[], originalFile:null, userModified:false}` |
| `Write` 覆寫 | 同上 | 字串 `The file <路徑> has been updated successfully. (…)` | `{type:"update", filePath, content, structuredPatch:[hunk…], originalFile:"<舊內容>", userModified:false}` |
| `Edit` | `{replace_all, file_path, old_string, new_string}` | 字串 `The file <路徑> has been updated successfully. (…)` | **沒有 `type`**:`{filePath, oldString, newString, originalFile, structuredPatch:[hunk…], userModified, replaceAll}` |
| `Read` 圖片(PNG／JPEG) | `{file_path}` | 陣列 `[{type:"image", source:{type:"base64", data, media_type:"image/png"｜"image/jpeg"}}]` | `{type:"image", file:{base64, type:"<MIME>", originalSize:<bytes>, dimensions:{originalWidth, originalHeight, displayWidth, displayHeight}}}` |
| `Read` 大圖(被縮) | 同上 | 同上(base64 是縮過的) | 同上,`displayWidth/Height` 小於原始(3000×2000 → 2000×1333);**下一行**是 `user` 行 `isMeta:true`、`turnCompanion:true`,`content` 字串 `[Image: original 3000x2000, displayed at 2000x1333. Multiply coordinates by 1.50 to map to original image.]` |
| MCP 工具帶圖(`mcp__<server>__<tool>`) | 工具自己的參數 | 陣列：工具回的 `text`、`{type:"image", source:{type:"base64", media_type, data}}`,**再加一段** `text`:`[Image: source: <家目錄>\.claude\projects\<專案資料夾>\<session id>\tool-results\mcp-<server>-blob-<數字>-<亂碼>.png]` | **陣列**(與 `tool_result.content` 相同的三個區塊,不是物件);行頂層另有 `mcpCallNotReadOnly:"no_hint"`;之後的 `assistant` 行帶 `attributionMcpServer`、`attributionMcpTool` |

- `structuredPatch` 的 hunk:`{oldStart, oldLines, newStart, newLines, lines:[…]}`,`lines` 以 ` `／`-`／`+` 開頭，檔尾沒有換行時有一行 `\ No newline at end of file`。
- Read 圖片時，**判斷依據**可用 `toolUseResult.type == "image"`,MIME 在 `toolUseResult.file.type`(不是 `media_type`);路徑只在 `tool_use.input.file_path`,`toolUseResult` 裡沒有路徑。
- 判斷寫檔來源:`Write` 有 `type`(`create`／`update`),`Edit` 沒有 `type`,要以工具名(`tool_use.name`)或 `oldString` 存在判斷。
- 小於 128 字元的 base64(例如 16×16 單色 PNG)不會被主機上剝圖的 `sed` 剝掉;一般截圖的 base64 會被剝(`toolUseResult.file.base64` 與 `source.data` 都是長字串)。【推論】由 `TranscriptCommand.swift:9-10` 的條件推得
- 沒錄到:Codex 圖片生成(`saved_path`,這台與作者的 Mac 都沒有 Codex CLI)、POSIX 路徑形式、`MultiEdit`／`NotebookEdit`、`Read` PDF、`SendUserFile`。

**Codex**
- `ImageGenerationEndEvent` 有 `saved_path: Option<AbsolutePathBuf>`(另有 `revised_prompt`、`status`)。【原始碼】[`codex-rs/protocol/src/protocol.rs:3209-3225`](https://github.com/openai/codex/blob/b5e1f3ae9d810dec3fe005fcc55552766b577bdb/codex-rs/protocol/src/protocol.rs#L3209-L3225)
- rollout 寫檔政策：在 Legacy 歷史模式下持久化 `ImageGenerationEnd`;新的分頁式 rollout 改存 `ItemCompleted`(TurnItems);`ViewImageToolCall` 事件是暫態、不寫入(但 `view_image` 的 function call 參數 `path` 仍在 response item 裡)。【原始碼】[`codex-rs/rollout/src/policy.rs:142-156`、`:166`](https://github.com/openai/codex/blob/b5e1f3ae9d810dec3fe005fcc55552766b577bdb/codex-rs/rollout/src/policy.rs#L142-L166);`view_image` 工具見 `herdr-file-transfer-and-image-upload.md` §3
- `ImageGenerationItem` 在新格式中帶的欄位名稱與 Heeler 讀的 `savedPath`/`saved_path` 是否一致：Heeler 兩種都接受【Heeler】`Chat/Codex/CodexRolloutRecord.swift:553`;官方新格式欄位【未查得】(需錄製檔驗證)。

### 2.5 Apple 平台

- **`QLPreviewController`**:可預覽 iWork、Office、RTF、PDF、圖片、`public.text` 類文字檔、CSV、USDZ;支援清單可能隨 OS 版本改變;可 present 或 push;標題預設取 URL 最後一段。嵌在別的 view controller 裡不會即時預覽、只顯示縮圖。【文件】<https://developer.apple.com/documentation/quicklook/qlpreviewcontroller>
- **`previewItemURL` 必須是 file URL**:要先把主機檔案下載到本機才能預覽。【文件】<https://developer.apple.com/documentation/quicklook/qlpreviewitem/previewitemurl>
- **SwiftUI `quickLookPreview(_:)`**:綁定設成非 nil 的 URL 就出現，使用者關閉時自動設回 nil。【文件】<https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)>
- **`ShareLink`**:分享任何 `Transferable`(`URL` 已符合);內容非立即可得時可用 `FileRepresentation`／`DataRepresentation` 非同步準備;Mail、備忘錄、訊息、AirDrop 等對檔案需要 `FileRepresentation`。【文件】<https://developer.apple.com/documentation/swiftui/sharelink>
- **縮圖**:`CGImageSourceCreateThumbnailAtIndex` 以 options 控制長邊大小;PDF 來源會產生 72 dpi 的頁面影像(需 `kCGImageSourceCreateThumbnailFromImage…` 選項)。`QLThumbnailGenerator` 是依需求產生縮圖的系統物件。【文件】<https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)>、<https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator>
- **快取**:`cachesDirectory` 是「Discardable cache files」;系統會定期清除 `Library/Caches` 與 `tmp`,iCloud 備份預設排除;可重建的資料放這裡，用完盡早刪。【文件】<https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/cachesdirectory>、<https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup>

### 2.6 比較表

| | herdr | HerdrChat | Heeler | Purrdr 現況 |
|---|---|---|---|---|
| 檔案參照的來源 | 無 | 無 | 對話紀錄中繼資料(Read 圖片、view_image、saved_path…)+ 訊息內圖片路徑 | 只有工具呼叫的 `path` 字串，未使用 |
| 工具結果內的圖片 | — | 主機上剝除 | 用工具輸入的路徑重讀檔案 | 主機上剝除、解析器丟棄 |
| Write／Edit | — | 摺疊工具列 | 檔案變更 + diff(取自 `toolUseResult`) | 摺疊工具列一行 |
| 點路徑 | 只開 http(s) | 只開 http(s) | 圖片路徑可點，點了才讀 | 不可點 |
| 取檔通道 | — | SSH exec + base64(只在檔案瀏覽器) | 既有唯讀 SFTP | 無(`HostFiles` 不適用) |
| 大小上限 | — | 25 MB | 20 MiB;> 8 MiB 等點擊 | — |
| 預覽格式 | — | 系統分享表 | 只有圖片(可縮放 sheet) | 只有自己上傳的圖片 |
| 快取 | — | App 快取 | 記憶體縮圖(48 MiB),鍵含大小與修改時間 | 上傳圖片的本機副本 |
| 範圍限制 | — | 使用者瀏覽到哪就是哪 | 只讀對話紀錄記錄或使用者點的路徑 | — |

---

## 3. 給 Purrdr 的建議(deepening opportunities)

詞彙依 codebase-design:**module**、**interface**、**seam**、**adapter**、**depth**、**leverage**、**locality**。

### 建議 1(最先做):可攜核心的「Agent 檔案參照」module — 純計算、零傳輸

**問題**:檔案參照的知識(哪個工具、哪個欄位、相對路徑怎麼解析、哪些是 Purrdr 自己的上傳)散在各解析器的 `filePath(in:)`、`UploadedImages`、畫面裡；現在每個 agent 的解析器只吐出一個沒人用的 `path` 字串。這是 shallow:interface(一個字串)幾乎沒有承載行為。

**做法**:
- 在 `TranscriptPart` 加一個片段(例如「agent 檔案」),帶**主機絕對路徑、來源(寫入／修改／讀取圖片／生成圖片／Agent 指定送出)、紀錄當時的 cwd、可選的快照內容**。解析器只負責「把該 agent 的紀錄翻成這個片段」,解析相對路徑與判斷種類集中在一個 module(in-process 依賴，直接以 `Conversation.items` 測)。
- 來源對照(依一手來源可確認的部分):
  - Claude `Write`/`Edit`/`MultiEdit`/`NotebookEdit` 的 `input.file_path` + 行頂層 `toolUseResult.type`(`create`／`update`)【文件】hooks 範例
  - Claude `Read` 且結果是圖片(`tool_result` 內有 `image` 區塊，或 `toolUseResult.type == "image"`)→ 「agent 看過的圖片」【文件】tools-reference Read;欄位值【Heeler】
  - Claude `SendUserFile`(若出現)→ 最明確的「agent 要給使用者看」訊號【文件】tools-reference
  - Codex `view_image` 的 `path`、圖片生成的 `saved_path`【原始碼】
- `Conversation` 把這些片段變成**檔案卡片**(畫面項目):圖片 → 縮圖卡;其他 → 檔名、類型圖示、大小(取得後)、「開啟」。Write 的卡片可附**快照**:`content` 本來就在 `tool_use` 行裡(sed 只剝無空白的長 base64 字串，一般文字不受影響【推論】),不必連主機就能顯示「agent 當時寫的內容」;「看目前版本」才取檔。
- 相對路徑只對該行的 `cwd` 解析(錄製檔每行有 `cwd`【Repo】`session.jsonl:23`),不猜。

**成本**:低到中(解析器 + 一個新畫面項目 + 錄製檔)。**風險**:Claude jsonl 欄位沒有官方 schema【未查得】,版本更新可能改名——用錄製檔回歸測試、未知時退回現在的摺疊工具列。**測試接點**:`ClaudeTranscriptParser`／`CodexTranscriptParser` 的錄製檔測試(需新錄 Write、Read 圖片、MCP 截圖、Codex 圖片生成四種樣本);`Conversation.items(from:)` 斷言出現檔案卡片、去重(同路徑多次寫入只留最新一張或每次一張要先決定)。不需要網路。

### 建議 2:主機檔案取用 port — 一個 interface,SSH 與 HTTPS 兩個 adapter

**問題**:現有 `HostFiles` 的 interface 為設定檔設計(家目錄相對、字元白名單、1 MiB、整檔讀),拿來讀 agent 檔案會讓呼叫端各自處理分塊、大小、變更偵測。HTTPS 根本沒有通道。

**做法**:在核心定義一個小 interface,呼叫端只知道兩件事:
- 「查狀態」:種類(一般檔／不存在／不是一般檔／不可讀)、大小、修改時間
- 「讀取」:給狀態(版本)讀整個檔(內部分塊);讀取中版本變了就丟「已變更」

Adapter:
- **SSH**(`PurrdrSSH`):一次性 exec 腳本把檔案 bytes 直接寫到 stdout(SSH 通道是二進位安全的，不需要 base64【規格】`herdrchat-behavior-spec.md:1635`),先印狀態行再印內容;POSIX 用 `stat`／`cat`,Windows 用 PowerShell 以標準輸出串流寫 bytes(`[Console]::OpenStandardOutput()`)【推論,需在 Windows OpenSSH 實測,參考上傳 stdin 問題】。走既有 `runOnce` 期限與 `HostScriptTimeLimit`。路徑以參數傳(允許空白與 Unicode,用既有 POSIX 引號規則),不放寬 `HostPath`。
  - 是否沿用長駐通道(#203 的 `HostFileScript.follow`):縮圖會連續讀多張，長駐通道省下每次 exec 的啟動成本(Windows 每個 PowerShell 0.6–2.5 秒【Repo】`WindowsHostChannel.swift:93` 註解);但大檔會塞住同一條通道上的主題／用量讀取。建議**另開一條「取檔」長駐通道**,閒置就關【推論】。
  - 不採 SFTP:維持 ADR-0003 與 `ssh-transcript-channel-evaluation.md` 的結論。
- **HTTPS**(`PurrdrHTTPS` + `host-service`):先改 `protocol/host-service.schema.json` 加檔案狀態與分塊讀取的請求／回應(二進位以 base64 包在 WSS 文字訊息，或用 binary frame;分塊 ≤256 KiB 以免卡住其他多工請求【推論】),再 codegen 兩端型別。授權見建議 5。
- **Demo** 與 **FakeHostConnection** 也各一個 adapter → 真 seam(≥2 adapter)。

**成本**:中(SSH 腳本 POSIX + Windows、協定與 Rust 實作)。**風險**:Windows stdout 二進位與大檔時限;HTTPS 多工的公平性。**測試接點**:`LocalShellHost` 以真 `/bin/sh` 跑 POSIX 腳本(含空白／中文檔名、symlink、FIFO 拒讀、讀取中被改寫);`scripts/windows-*-repro.py` 加一支取檔回歸;`FakeHostService` 回放新協定範例(`protocol/examples/`);host-service `cargo test`。

### 建議 3:預覽 — 圖片內嵌縮圖，其他一律 QuickLook + ShareLink

- **圖片**(png/jpg/gif/webp/heic…):卡片內嵌縮圖，降採樣用 `CGImageSourceCreateThumbnailAtIndex`(長邊約 1,024 px),點開沿用既有 `imageViewer`。縮圖高度固定，避免圖到了改列高(與 #130 捲動問題相同性質)。
- **其他**(PDF、markdown、程式碼、CSV、Office):卡片只顯示檔名與圖示，**點了才下載**到 `Caches` 再 `quickLookPreview`;卡片 context menu 加 `ShareLink`(下載完成的 file URL)。QuickLook 不支援的類型退回分享表。
- markdown 也可以用 Purrdr 自己的 `MarkdownView` 顯示(與對話一致)【推論,屬產品決策】;第一版用 QuickLook 最省。
- **大小上限**(建議值，取 Heeler／HerdrChat 的實務為參考):自動縮圖 ≤ 8 MiB;點擊開啟 ≤ 25 MiB;超過顯示大小與「在終端機處理」說明。
- **快取**:`Caches` 目錄、鍵 = 主機身分 + 路徑 + 大小 + 修改時間;縮圖另放記憶體 `NSCache`;刪除主機或「清除快取」時一併清。

**成本**:中(畫面 + 快取)。**風險**:QuickLook 支援清單隨 OS 改【文件】;HIG 檢核(縮圖的 VoiceOver 標籤、44pt、AX 字級)。**測試接點**:快取鍵與上限判斷放核心測(純邏輯);UI 測試用 Demo 主機的一張圖與一份 PDF;iOS 專用測試驗證降採樣不在主執行緒。

### 建議 4:訊息內的主機路徑可點(只在 app 內開)

- 擴充 `MarkdownInline` 加一種「主機路徑」(inline code、連結目的地為絕對路徑或 `file:` URL、文字中的絕對路徑);R-V03「只開 http(s)」照舊適用於**系統** `openURL`,主機路徑**不交給系統**,點了走建議 2／3 的流程(先查狀態，再依類型預覽)。
- 相對路徑只在 inline code 或連結裡認，開啟時對 agent 的 `cwd` 解析(與 Heeler 相同的保守規則，避免 `and/or.png` 誤判)。
- **點之前不讀檔**,所以不增加流量。

**成本**:低到中(Markdown 解析 + 測試)。**風險**:誤判造成可點的假路徑——只影響外觀，不會自動讀檔。**測試接點**:`Markdown` 的單元測試(中英混排、句尾標點、空白檔名、Windows 磁碟路徑)。

### 建議 5:安全 — 只讀「agent 留下參照」的檔，HTTPS 更嚴

- **SSH**:登入的就是使用者自己的帳號，能讀什麼本來就能在登入 Shell 讀，風險在**誤觸**而非越權。規則：只讀建議 1 產生的參照或使用者點擊的路徑;不自動讀非圖片;不讀 FIFO／裝置(沿用 R-F03 的「非一般檔」判斷)。
- **HTTPS**(主機服務的窄 API 原則，ADR-0010 不提供任意指令):app 不能任意指定路徑。建議主機服務只接受符合下列之一的路徑【推論,需設計審查】:
  1. 位於 herdr snapshot 中某個 Agent 的 `cwd` 之下(以 `realpath` 解析 symlink 後再比對，防 `..` 與 symlink 跳出);或
  2. 出現在**這條連線定位過**的對話紀錄裡(與 `transcript_not_allowed` 的現行規則同一套思路【Repo】`connection.rs:472`)。
  - 另外排除 `~/.ssh`、`~/.purrdr/host-service`(裝置權杖雜湊)等敏感位置;唯讀裝置可以讀(唯讀指的是不能操作 Pane)【推論】;稽核紀錄記路徑與大小、不記內容。
- 「只讀 agent 工作目錄內」單獨用不夠：agent 常把截圖寫到 `/tmp` 或 `~/Downloads`,所以第 2 條必要。

**成本**:中(Rust 端路徑驗證與測試)。**風險**:路徑正規化在 Windows(磁碟代號、大小寫、`\\?\`)容易出錯。**測試接點**:host-service `cargo test`(三平台 CI 已有);以 symlink 逃逸、`..`、大小寫變化的案例做紅燈。

### 流量考量(跨建議)

- 對話紀錄照舊在主機剝圖(R-B04 不改);圖片 bytes 永遠另外按需讀，**不進對話紀錄快取**。
- 縮圖只在卡片出現在畫面時讀、一次一張、離開畫面取消;先查狀態(很小),版本沒變就用快取。
- 非圖片永不自動下載。可考慮蜂巢式網路時連縮圖也等點擊(`NWPathMonitor` 的 `isExpensive`)【推論,屬產品決策】。
- 估算：一張 1 MB 截圖 ≈ 一次開啟對話的 1 MiB 對話紀錄視窗(`TranscriptReader.swift:207`),量級相同，所以「畫面上才讀」是必要條件。

### 優先順序總表

| # | 內容 | 成本 | 主要風險 | 先決條件 |
|---|---|---|---|---|
| 1 | Agent 檔案參照 module + 檔案卡片(含 Write 快照) | 低–中 | jsonl 無官方 schema | 新錄製檔 |
| 2 | 主機檔案取用 port(SSH、HTTPS、Demo、Fake adapter) | 中 | Windows stdout 二進位;WSS 多工 | 1 |
| 3 | 圖片縮圖 + QuickLook／ShareLink + 快取 | 中 | HIG 檢核 | 2 |
| 4 | 訊息內主機路徑可點 | 低–中 | 誤判 | 2、3 |
| 5 | HTTPS 取檔授權規則 | 中 | Windows 路徑正規化 | 2 的 HTTPS 部分 |

SSH 主機可以先做 1→2(SSH)→3,HTTPS 等 5 一起上線，避免開出沒有授權規則的檔案 API。

---

## 4. 沒有一手來源或待驗證的主張

- Claude Code 對話紀錄 jsonl 的完整 schema:無官方文件。Write／Edit／Read 圖片／MCP 帶圖的 `toolUseResult` 已以 2.1.328 錄製檔驗證(§2.4「錄製樣本的實際欄位格式」);其他版本、`MultiEdit`、`NotebookEdit`、Read PDF 仍未驗證。
- `SendUserFile` 的輸入欄位(除 `display`)與它在 herdr pane 的一般 session 是否可用。
- Codex 新的分頁式 rollout 中，圖片生成項目的路徑欄位名稱。
- Windows PowerShell 經 OpenSSH 把二進位 bytes 寫到 stdout 是否完整(上傳方向的 stdin 曾有問題)。
- HTTPS 授權規則(cwd 之下或對話紀錄中出現)是否足夠，需安全審查。
- 剝圖的 `sed` 不會誤剝 Write 的一般文字內容(只針對無空白、≥128 字元的 base64 字元集字串;極長的單行 base64 樣內容仍會被剝)。
- HerdrChat 聊天內是否有任何檔案預覽:規格與公開文件都沒有提到。

## 來源

| 代號 | 來源 |
|---|---|
| P | 本 repo(`master` `4f5ca66`):`src/PurrdrCore/{ClaudeTranscriptParser,CodexTranscriptParser,TranscriptMessage,Conversation,Markdown,TranscriptCommand,UploadedImages,HostFileTypes,HostFileScript,Agent}.swift`、`src/PurrdrSSH/{HostFiles,HostFolders}.swift`、`src/PurrdrFeatures/{ConversationView,ComposerImageViews}.swift`、`protocol/host-service.schema.json`、`host-service/service/src/connection.rs`、`tests/PurrdrTestSupport/Fixtures/claude-code/`、`docs/adr/0003`、`0010`、`docs/research/{herdr-file-transfer-and-image-upload,ssh-transcript-channel-evaluation,herdrchat-behavior-spec}.md` |
| H | herdr `ee5bfb5`:`src/app/actions.rs`、`src/pane/osc.rs`、`docs/next/CHANGELOG.md` |
| HE | Heeler `4db5ce0`:`docs/adr/0006`、`0010`、`0024`;`Sources/Heeler/Chat/Source/ChatImagePreviewReader.swift`、`Chat/Conversation/ChatImageThumbnails.swift`、`Chat/Conversation/AgentChatStore.swift`、`Chat/Timeline/ChatImageLink.swift`、`Chat/Timeline/ChatImagePreviewController.swift`、`Chat/Claude/ClaudeToolSummary.swift`、`Chat/Claude/ClaudeTranscriptRecord.swift`、`Chat/Codex/CodexRecordDecoder.swift`、`Chat/Codex/CodexRolloutRecord.swift` |
| CC | Claude Code:<https://code.claude.com/docs/en/tools-reference>、<https://code.claude.com/docs/en/hooks> |
| CX | Codex `b5e1f3a`:`codex-rs/protocol/src/protocol.rs`、`codex-rs/rollout/src/policy.rs` |
| A | Apple:QLPreviewController、QLPreviewItem.previewItemURL、View.quickLookPreview、ShareLink、CGImageSourceCreateThumbnailAtIndex、QLThumbnailGenerator、cachesDirectory、Optimizing your app's data for iCloud backup(連結見 §2.5) |
