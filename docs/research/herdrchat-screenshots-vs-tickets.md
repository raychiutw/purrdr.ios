# herdrchat 截圖對照 Drover Chat 票

逐張看 herdrchat 公開的系統截圖與 README／網站／App Store 文案(使用者看得到的行為),對照 Drover Chat 已開的票(#2 總規格、#3–#36),找出「截圖裡有、但沒有任何票涵蓋」的佈局或功能，以及票有寫、但描述和截圖明顯不同的地方。

- 依 ADR-0001(clean-room),本文只根據**截圖與文件文字**,沒有讀 herdrchat 的程式碼。
- 視覺風格不同(圖示、配色、卡片 vs. grouped list、泡泡樣式)不算缺口，因為 `DESIGN.md` 已選了不同方向;只有**功能或資訊／佈局元素**缺漏才算。
- 素材版本:herdrchat `main` @ `0ed5f50`(2026-11-14)。下文 GitHub 連結都用這個 commit 的 permalink,前綴為 `https://github.com/cobanov/herdrchat/blob/0ed5f50/`(以下簡寫為 `GH:`)。
- 票號：本文的 `#N` 是 GitHub issue 編號(票名開頭的 01–34 是另一套序號，例如 #11 = 「09 Agent 列表」)。
- 文字素材:`README.md`、`store/README.md`、`store/slides.html`(App Store 截圖的標題與說明文字就從這裡產生)、`site/index.html`(官網)、`.maestro/README.md`(e2e flow 說明，用來確認截圖裡的元素名稱)。App Store 頁面沒有另外抓，因為 `store/slides.html` 就是上架截圖的來源，說明文字已在其中。

---

## 1. 截圖清單

共 **19 張**圖片：其中 18 張是 app 畫面(或含 app 畫面的宣傳圖),1 張(S16)是截圖裡被當成「附件」的假網頁。不含 app 圖示、favicon、logo 這類非畫面圖片(`assets/icon.png`、`assets/favicon.png`、`assets/android-icon-foreground.png`、`assets/splash-icon.png`、`site/assets/logo.png`、`site/assets/favicon-*.png`、`site/assets/apple-touch-icon.png`)。repo 裡沒有 fastlane metadata,Maestro 產出的截圖也沒有 commit 進來。

### S1 Spaces 檢視(iPhone)
- 出處:`docs/screenshots/chats-dark.png`(`GH:docs/screenshots/chats-dark.png`),README 首圖
- 頂部：大標題「Spaces ⌄」(可點，切換檢視)、副標「▤ Demo ⌄」(主機切換)、右上「新增對話」(鉛筆方框)與「⋯」選單鈕
- 搜尋欄「Search chats」
- 分組標題含數量與橫線:「NEEDS YOU ─ 1」(注意色)、「WORKING ─ 1」、「IDLE ─ 6」
- 聊天卡(單一 agent 的 workspace):agent 種類圖示(Claude 星芒)、標題「Folder picker read errors」、副標「Claude · demo/herdrchat」(等寬)、預覽「Waiting for your input」(注意色)、右欄「!」圈與日期「8/19」;卡片外框為注意色
- **空間卡**(多 pane 的 workspace「api」):layers 圖示、標題「api」、統計行「2 agents, 1 working · 2 tabs · 4 panes · demo/api」、工作中轉圈、**版面圖按鈕**(田字格)
- 空間卡下方以左側「軌道」內縮列出，並**依 tab 分組**:tab 名「api」下有兩個 agent 列(Archived projects migration:實心圓點 = 未讀、8/19;Save button wrap:轉圈 +「now」)與一個**終端機列**(「Terminal / Shell · demo/api」+ ›);分隔線後 tab 名「server」下一個終端機列(「Terminal / npm run dev · api/web」)

### S2 Agents 檢視(iPhone)
- 出處:`docs/screenshots/agents-dark.png`(`GH:docs/screenshots/agents-dark.png`)
- 大標題「Agents ⌄」,其餘頂部同 S1
- 每個 agent 一列平鋪，沒有空間卡、沒有終端機列
- 列的右欄：空心圓(已讀、閒置)、實心圓(Daily screen journal,未讀)、日期「8/19」「Sat」
- OMP 的列用不同的 agent 圖示(`</>`),副標「OMP · demo/ledger」
- 預覽行「You: scratch pad — nothing running here」(自己的訊息前綴 You:)

### S3 對話：subagent／workflow 卡、shell 區塊(iPhone)
- 出處:`docs/screenshots/thread-subagents-dark.png`(`GH:docs/screenshots/thread-subagents-dark.png`),README 首圖
- Header:返回、標題「Release notes s…」、副標「● notes · Opus… · online」(狀態點、workspace、模型、狀態字);右側三顆圓形按鈕：**終端機**、**工具圖示(錘子扳手，功能文件未說明)**、**重新載入**
- Subagent 卡：展開 ›、晶片圖示、標題「Check the release notes for broken links」、「general-purpose · sonnet · 1m 6s」、完成勾、開啟 ›
- Workflow 卡：標題「release-review」、說明「Check the release, then review its wording」、「2 of 3 agents done」、轉圈
- Agent 文字全寬、不是泡泡;可點連結(紫色)
- **Shell 區塊**:「$ git status --short」(等寬粗體)+ 時間「16:35」,下方輸出「M release-notes.md / ?? draft-0.12.md」
- 使用者泡泡(右、tint 色、時間)
- 項目清單、行內 code(`SHA256:…`)
- 輸入列：左「加入圖片」、「Message」、右送出圈

### S4 Slash 選單(iPhone)
- 出處:`docs/screenshots/slash-palette-dark.png`(`GH:docs/screenshots/slash-palette-dark.png`)
- 輸入「/re」時，輸入列上方的卡片列出排名後的指令：`/release-notes`、`/review [pr]`、`/add-dir <path>`、`/compact <optional custom summarizat…>`、`/notes:summarise`;每列指令名(等寬粗體)+ **參數提示**(淡色等寬)+ 第二行說明
- 輸入列聚焦時外框 tint,多一顆**收起鍵盤**鈕;送出鈕變實心

### S5 iPad 分割：列表 + 對話
- 出處:`docs/screenshots/ipad-split-dark.png`(`GH:docs/screenshots/ipad-split-dark.png`)
- **兩欄**:左欄 = S1 的 Spaces 列表(選取中的列有 tint 外框);右欄 = 對話
- 右欄 header:標題「Release notes summary」、副標「● notes · Opus 5 · online」、右側終端機／工具／重新載入
- 對話頂端「Beginning of conversation」
- 兩張 subagent 卡、一張 workflow 卡、shell 區塊、多則使用者泡泡

### S6 iPad 分割：列表 + 終端機
- 出處:`docs/screenshots/ipad-terminal-dark.png`(`GH:docs/screenshots/ipad-terminal-dark.png`),README 首圖與 Terminal 段
- 左欄列表中「Terminal / Shell · demo/api」列被選取(tint 外框)
- 右欄終端機(不是全螢幕，在詳細欄內):header 返回、標題「Shell · demo/api」、狀態「● Connected」
- 彩色 ANSI 畫面(`ls`、`git status`)、游標
- 底部按鍵列:`esc tab ctrl alt ← ↓ ↑ → / - | ~ home end`,右側獨立的**貼上**鈕與**鍵盤**鈕

### S7 iPad 版面圖浮動卡
- 出處:`docs/screenshots/ipad-layout-dark.png`(`GH:docs/screenshots/ipad-layout-dark.png`)
- 「api」空間卡旁浮出一張卡：標題「api」、統計行、「Close」
- 兩個 tab 欄:「api」(Claude Archived projects…、Claude Save button w…兩個 agent 方塊並排，下方 Shell 方塊)、「server」(npm run dev 方塊);聚焦 pane 有 tint 外環;agent 方塊用 agent 色填色

### S8 聊天列表(舊版，有 tab bar)
- 出處:`store/raw/chats.png`(`GH:store/raw/chats.png`),App Store 第 2 張「The agent that needs you is on top.」
- 標題「Chats」、主機「mac-studio ⌄」、新增對話;沒有「⋯」
- NEEDS YOU / WORKING / IDLE 分組;預覽行無預覽時顯示狀態字(Working／Idle／Done)
- 列表底部提示「Swipe a chat either way to pin, mute, rename or close it ‹」
- 底部浮動 tab bar:**Chats(徽章 1)**、Hosts、Settings

### S9 釘選與靜音(iPhone)
- 出處:`store/raw/pinned.png`(`GH:store/raw/pinned.png`),App Store 第 7 張「Pin what matters. Quiet the rest.」
- 最上方多一組「**PINNED ─ 1**」;釘選的列標題後有**圖釘與靜音小圖示**
- 一列往右滑開，露出「Pin」「Mute」兩個動作

### S10 對話：工具串與「需要你」選項(iPhone)
- 出處:`store/raw/thread.png`(`GH:store/raw/thread.png`),App Store 第 1、3 張
- Header 副標「● Opus 5 · high effort · herdrchat · waitin…」(注意色，含 **effort**);只有工具與重新載入兩顆鈕(沒有終端機鈕，可能是加入終端機功能前拍的)
- 「Beginning of conversation」
- 工具串摘要「Ran 2 commands · read 1 file · 1 failed」(已展開成樹狀:Run…、Read client.ts、失敗的 Run 標紅)
- Blocked 卡：注意色問題文字、編號選項「1 Yes, go ahead」「2 No, tell me more first」

### S11 /model 面板(iPhone)
- 出處:`store/raw/slash.png`(`GH:store/raw/slash.png`),App Store 第 4 張「Switch the model from your phone. Type / for /model, /effort and more. The picker opens right in the chat.」
- 送出的「/model」泡泡下方，聊天內出現原生卡片：標題「Select model」、說明、選項列(Default (recommended) 打勾、Opus 5、**Sonnet 5 游標高亮**、Haiku 4.5,各有第二行說明)、「‹ High effort ›」調整、動作鈕「Set as default」「Use this session only」「Cancel」

### S12 傳圖片(iPhone)
- 出處:`store/raw/picture.png`(`GH:store/raw/picture.png`),App Store 第 6 張「Show it what you see.」
- 使用者泡泡內含圖片縮圖
- 工具串收合「› Read 2 files · searched 1 time」
- **工作中指示**:點陣動畫 +「Working…」+ 經過時間「22s」
- Header 副標狀態「…」打字點;右上**停止**鈕(紅色方塊)取代重新載入

### S13 新增主機(iPhone)
- 出處:`store/raw/host.png`(`GH:store/raw/host.png`),App Store 第 8 張「Your machine. Your keys.」
- 欄位:Name、Host、Port、Username、Authentication(Password／Private key 分段)、OpenSSH private key(折疊成「OpenSSH private key, 5 lines」+「Replace」)、說明「Stored in the device keychain, never in the database.」、**herdr path**、**herdr session**(placeholder「Default」+ 說明「Leave the session empty unless this machine runs more than one herdr session.」)、Host key fingerprint(`SHA256:…`)
- 底部:「Connected. herdr 0.9.1.」、「Test connection」、「Save」;右上「Cancel」

### S14 iPad 分割：列表 + 需要你的對話(舊版)
- 出處:`store/raw/ipad-thread.png`(`GH:store/raw/ipad-thread.png`),App Store iPad 第 1 張「Every agent on one side, the conversation on the other.」
- 頂部置中分段 tab:Chats／Hosts／Settings
- 左欄 Chats 列表(選取列 tint 外框)、底部滑動提示;右欄對話(工具串、Blocked 卡)

### S15 iPad 分割：傳圖片(舊版)
- 出處:`store/raw/ipad-picture.png`(`GH:store/raw/ipad-picture.png`),App Store iPad 第 2 張
- 同 S14 版面;「Chats」tab 有紅色徽章「1」;右欄有圖片泡泡、工具串收合、「Working… 9s」、停止鈕

### S16 假網頁(附件道具)
- 出處:`store/raw/pantry-login.png`(`GH:store/raw/pantry-login.png`)
- 不是 app 畫面，是 S12／S15 被當成附件送出的圖片(`store/README.md` 說明為 made-up web page)。不列入對照。

### S17 官網：聊天列表(更舊版)
- 出處:`site/assets/shot-chats-dark-v1.webp`(`GH:site/assets/shot-chats-dark-v1.webp`)
- 同 S8,但分組標題有「⌄」**可收合**;滑動提示「Swipe a chat to rename or close it」(還沒有釘選／靜音)

### S18 官網：需要你的對話(更舊版)
- 出處:`site/assets/shot-thread-blocked-dark-v1.webp`(`GH:site/assets/shot-thread-blocked-dark-v1.webp`)
- Agent 文字是泡泡;工具呼叫是單行「› Read {file_path: …}」;Blocked 卡在輸入列上方;header 只有返回、標題、副標與重新載入

### S19 官網 OG 圖(含推播橫幅)
- 出處:`site/assets/og-v1.png`(`GH:site/assets/og-v1.png`)
- 手機畫面頂端是**系統推播橫幅**「herdrchat / Claude is waiting for your input」
- 對話中有「Today 12:06」**日期分隔**、單行工具呼叫、Blocked 卡

---

## 2. 對照表

狀態欄:**有票** = 票有涵蓋;**部分** = 票只寫到一部分，截圖裡還有票沒提的元素;**無票** = 沒有任何票涵蓋;**描述不同** = 票有寫，但寫法與截圖明顯不同;**決策** = 刻意不同，見第 4 節。「缺口」欄對應第 3 節編號。

### 2.1 聊天列表

| 可見元素 | 出處 | 票 | 狀態 | 缺口 |
|---|---|---|---|---|
| 依「需要你／工作中／閒置」分組 | S1、S2、S8 | #11 | 有票 | |
| 分組標題顯示數量 | S1、S2、S8 | #11 | 部分(#11 沒提數量) | G9 一併 |
| **「已釘選」群組置頂**(四組，不是三組) | S9 | #11 寫三組;#19 只寫「可釘選」 | **描述不同** | G9 |
| 列上的釘選、靜音小圖示 | S9 | #19 | 部分 | G9 |
| 往右滑：Pin、Mute | S9 | #19(swipe actions) | 有票 | |
| 列表底部「滑動可釘選、靜音、重新命名、關閉」提示 | S8、S14 | — | 無票 | G10 |
| 搜尋欄 | S1、S2、S8 | #11 | 有票 | |
| 標題、副標(agent 種類 · 資料夾)、預覽、時間 | S1、S2、S8 | #11(依 F2) | 有票 | |
| 預覽行「You:」前綴、無預覽時顯示狀態字 | S2、S8 | #11(依 F2.4) | 有票 | |
| 狀態記號(!、轉圈、空心圓) | S1、S2 | #11 | 有票 | |
| **實心圓 = 已完成且未讀**(未讀標示) | S1、S2 | — | 無票 | G6 |
| 「需要你」列外框注意色 | S1、S8 | #11 | 有票(樣式依 DESIGN) | |
| Agent 種類圖示(Claude、OMP 不同) | S2 | #11(未明寫) | 部分 | G5 一併 |
| 主機切換(標題下「Demo ⌄」) | S1、S8 | #10 | 有票 | |
| **標題可切換 Spaces／Agents 兩種檢視** | S1、S2、README「Spaces」 | — | 無票 | G1 |
| **空間卡**:統計行(agents、working、tabs、panes、資料夾)、軌道、依 tab 名分組的子列 | S1、S5、S7、README | #19 只寫「多 agent 的 workspace 分別列出每個 Agent」 | 部分 | G2 |
| **列表中的終端機列**(非 agent 的 pane,顯示程式名與資料夾) | S1、S5、S6、README「Terminal」 | #20 只寫「任何 Pane 可開成終端機」,沒寫入口 | 部分 | G3 |
| 空間卡上的版面圖按鈕 → 版面圖 | S1、S7 | #19 | 有票 | |
| iPad 版面圖為浮動卡(游標停留顯示、點擊釘住、Close) | S7、README「Spaces」 | #19、#31 都沒寫 | 部分 | G23 |
| 右上「新增對話」 | S1、S8 | #18 | 有票 | |
| 右上「⋯」選單(設定、主機、新增對話的入口) | S1、S2、`.maestro/README.md` regression/menu | — | 無票 | G8 |
| 舊版 tab bar(Chats／Hosts／Settings) | S8、S9、S14、S15 | — | herdrchat 自己已改成「⋯」選單;入口問題併入 G8 | G8 |
| Chats 的注意徽章(數字) | S8、S9、S15 | — | 無票 | G7 |
| **多主機的列合併在同一個列表**、其他主機掛掉時列表下一行說明 | README「Several computers」 | #2 故事 11、#10 寫「切換目前主機」 | **描述不同** | G4 |
| 主機圖示取代 agent 圖示 | README「Several computers」 | — | 無票 | G5 |
| 分組可收合 | S17(舊版) | — | herdrchat 自己已移除(spec F2.2「群組永遠展開」),不列缺口 | |
| 「You should know」:列表標題下一行「✦ N notes for you」 | README、`.maestro/README.md` regression/you-should-know | #23 只寫「顯示註記並可標記已讀」 | 部分 | G24 |

### 2.2 對話畫面

| 可見元素 | 出處 | 票 | 狀態 | 缺口 |
|---|---|---|---|---|
| **Header 副標:workspace、模型、effort、資料夾、狀態字與狀態點** | S3、S5、S10、S11、S12;官網 callout「Model, folder and state live in the header.」 | #12 沒寫 header 內容 | 無票 | G11 |
| Header 終端機鈕 | S3、S5、README「Terminal」 | #20 沒寫入口;#31 寫鍵盤快捷鍵開終端機 | 部分 | G3 一併 |
| Header 重新載入鈕 | S3、S10、S14 | — | 無票 | G12 |
| Header 停止鈕(working 時取代重新載入) | S12、S15 | #13「可送出中斷」 | 部分(位置與長按強制結束未寫) | G12 |
| Header 錘子扳手圖示鈕 | S3、S5、S10–S15 | — | 功能文件未說明，待確認 | 第 3.4 節 |
| 「Beginning of conversation」頂端標記 | S5、S10、S12 | #12(往上捲載入) | 部分，細節可放進 #12 | |
| 使用者泡泡 + 時間 | S3、S10 | #12 | 有票 | |
| Agent 文字全寬、不是泡泡 | S3、S10 | DESIGN「標準泡泡」 | **決策** | 第 4 節 |
| Markdown:清單、行內 code、連結(只開 http(s)) | S3、S10 | #12 | 有票 | |
| 表格、code block | 官網 HTML 範例、README | #12 | 有票 | |
| 工具串摘要「Ran 2 commands · read 1 file · 1 failed」、展開成樹、失敗標紅 | S10、S12 | #12 | 有票(失敗標示可在 #12 驗收補一句) | |
| Subagent 卡(標題、類型 · 模型 · 時長、狀態、開啟) | S3、S5 | #17 | 有票 | |
| Workflow 卡(「2 of 3 agents done」) | S3、S5 | #17 | 有票 | |
| Workflow 畫面：每個 phase 與 phase 裡的 agent | README「Watch the agents…」、`.maestro` regression/subagents | #17 只寫「唯讀瀏覽其對話」 | 部分 | G25 |
| 背景 agents 列(輸入列上方) | README、`.maestro` regression/agents-pane | #17 | 有票 | |
| **Shell `!` 區塊**(`$ 指令` + 時間 + 輸出) | S3、S5、`.maestro` regression/shell-commands | — | 無票 | G14 |
| **工作中指示**(點陣動畫、「Working…」、經過時間)與即時預覽 | S12、S15 | — | 無票 | G13 |
| Blocked 卡：問題 + 編號選項 | S10、S14、S18、S19 | #14 | 有票 | |
| 圖片泡泡(縮圖) | S12、S15 | #16 | 有票 | |
| 日期分隔「Today 12:06」 | S19(舊版)、官網 HTML 範例 | — | 新版截圖都在同一天，無法判斷是否仍存在，待確認 | 第 3.4 節 |

### 2.3 輸入列與 Slash

| 可見元素 | 出處 | 票 | 狀態 | 缺口 |
|---|---|---|---|---|
| 加入圖片鈕、多行輸入、送出鈕 | S3、S4 | #13、#16 | 有票 | |
| 聚焦時「收起鍵盤」鈕 | S4 | — | 無票(#20 的收起鍵盤只講終端機) | G22 |
| Command-V 貼上圖片;剪貼簿有圖時「相簿／貼上圖片」 | README「Type like on a Mac」 | #16 只寫 PhotosPicker 與相機 | 部分 | G21 |
| Return／Shift-Return／Command-Return、設定「Return sends」 | README | #13、#32 | 有票 | |
| `/` 選單：指令名 + 第二行說明 | S4 | #15 | 有票 | |
| **參數提示**(`[pr]`、`<path>`、`<optional …>`)與挑選行為(不帶參數者點了直接送;要參數者填入並在游標後顯示提示) | S4、README「Every slash command…」 | #15 沒寫 | 無票 | G15 |
| 輸入文字後變成單一排名清單(無分組標題) | S4、`.maestro` regression/slash-commands | #15 寫「依來源分組、可搜尋」 | 部分(輸入後的排序規則未寫) | G15 一併 |
| Codex 聊天用 Codex 自己的選單 | README | #15、#24 都沒寫 | 無票 | G17 |
| `/model` 開出的**原生面板**(選項、游標高亮、effort ‹ ›、Set as default／Use this session only／Cancel) | S11、App Store 第 4 張 | #15 只寫「開出的面板用方向鍵操作」 | 部分 | G16 |
| Shell 模式提示(打 `!` 時說明會在 agent 的 shell 執行) | `.maestro` regression/shell-commands | — | 無票 | G14 一併 |

### 2.4 主機

| 可見元素 | 出處 | 票 | 狀態 | 缺口 |
|---|---|---|---|---|
| Name／Host／Port／Username | S13 | #7 | 有票 | |
| 認證：密碼／私鑰;私鑰折成「N lines」只能 Replace;「存在 Keychain」說明 | S13 | #8 | 有票(Drover 另加 Secure Enclave、Tailscale SSH) | |
| **herdr path、herdr session 欄位** | S13 | #2 故事 1 只列名稱、位址、使用者、連線方式;#7 沒寫 | 無票 | G18 |
| Host key 指紋 | S13 | #7 | 有票 | |
| Test connection + 結果「Connected. herdr 0.9.1.」、Save | S13 | #7 | 有票 | |
| 主機圖示 | README | — | 無票 | G5 |

### 2.5 終端機

| 可見元素 | 出處 | 票 | 狀態 | 缺口 |
|---|---|---|---|---|
| SwiftTerm 彩色畫面、游標 | S6 | #20 | 有票 | |
| Header:標題「Shell · demo/api」、狀態「● Connected」 | S6 | #20 沒寫狀態字 | 部分 | G20 |
| 按鍵列 esc、tab、ctrl、alt、方向鍵、home、end、貼上、鍵盤 | S6 | #20 | 有票 | |
| 按鍵列的 `/ - \| ~` 符號鍵 | S6 | #20 沒列 | **描述不同** | G19 |
| Take over、捏合調字級、滑動捲歷史 | README「Terminal」 | #20 | 有票 | |
| iPad 上終端機開在列表旁的詳細欄 | S6、README | #20「全螢幕」、#31「開在新視窗」 | **決策**(見第 4 節) | |

### 2.6 其他

| 可見元素 | 出處 | 票 | 狀態 |
|---|---|---|---|
| 系統推播橫幅「Claude is waiting for your input」 | S19、App Store 第 5 張 | #29 | 有票(Drover 改走 relay + Plus,見第 4 節) |
| 靜音某聊天的推播 | S9、App Store 第 7 張 | #19、#29 | 有票 |
| iPad 兩欄 | S5、S6、S14、S15 | #31 寫三欄 | **決策** |
| Demo 主機 | 所有 Demo 截圖、README「Try it」 | #3、#34 | 有票 |
| 主機主題(Copy prompt for an agent、Reload theme) | README「Theming」 | #23 | **決策**(見第 4 節) |
| Claude 用量(列表底部) | README 未提、截圖沒有;spec F18 | #22 | 有票(不在截圖範圍) |

---

## 3. 缺口清單

每條都寫成可以直接開票的形式。「放哪」是建議;「被擋」是要先完成的票。

### 3.1 最重要的 5 個

**G1 聊天列表的 Spaces／Agents 兩種檢視**
- 出處:S1、S2;README「See what needs you」「Spaces」;`.maestro/README.md` regression/list-modes
- 使用者看得到的行為：列表大標題就是目前檢視名，點標題可在「Spaces」與「Agents」之間切換，選擇會被記住。Spaces 一個 workspace 一張卡(單一 agent 的 workspace 就是聊天卡，其他是空間卡，見 G2);Agents 把每個 agent 平鋪成一列，不顯示終端機列。兩種檢視共用同一份分組、搜尋、已讀與釘選。
- 放哪：新開票(或併入 #19,但 #19 已經很大)。#2 的使用者故事也要補一條。
- 被擋:#11

**G2 空間卡：統計行與依 tab 分組的子列**
- 出處:S1、S5、S7;README「Spaces」;`.maestro` regression/space-layout
- 使用者看得到的行為：有兩個以上 agent、或有 agent 以外 pane 的 workspace 顯示成空間卡：標題是 workspace 名稱，統計行「N agents, M working · N tabs · N panes · 資料夾」,右側有工作中狀態與版面圖按鈕;卡片下方內縮列出每個 agent 的列與每個終端機列，tab 不只一個時依 tab 名稱分組、組間有分隔線。點卡片本身開版面圖，不是開聊天。
- 放哪:#19(把「多 agent 的 workspace 分別列出每個 Agent」改寫成空間卡)
- 被擋:#11、G1

**G4 多主機合併成同一個列表**(描述不同)
- 出處:README「Several computers」
- 使用者看得到的行為：列表同時列出所有主機的聊天，選取中主機的在前，其他主機的列在第二行開頭標示主機名;某台主機連不上時保留它最後的列，並在列表下方顯示一行「主機名：原因」。「選取中主機」只決定新對話開在哪裡、套用誰的主題、哪台的錯誤佔滿畫面。
- 目前票：#2 故事 11 與 #10 都寫成「切換目前主機」,只看一台。要先決定 Drover 是否跟進;若跟進，改寫 #10(或在 #10 下新增一張)。
- 被擋:#10、#11

**G6 未讀標示**
- 出處:S1、S2(實心圓 vs. 空心圓);spec F2.5、F2.6
- 使用者看得到的行為：有我還沒讀過的新回覆的聊天，右欄顯示實心圓;打開讀過後變空心圓。我自己送出的訊息、沒有時間戳的預覽不算未讀;herdr 回收 pane 給新 session 時要重新算未讀。iPad 上目前開在旁邊的聊天不算未讀。
- 放哪:#11
- 被擋:#11、#12(要知道開啟時間與 session)

**G14 Shell `!` 指令區塊與 shell 模式**
- 出處:S3、S5;`.maestro` regression/shell-commands;spec F5.9、F6.4
- 使用者看得到的行為：在 Claude 聊天輸入以 `!` 開頭的文字時，輸入列上方提示「這會在 agent 的 shell 執行，不會送給 Claude」;送出後對話裡出現一個終端機風格的區塊:`$ 指令`(等寬粗體)+ 時間，下方 stdout、stderr 用注意色;執行中顯示「執行中」,沒輸出顯示「無輸出」,超過 16 行折疊並有「顯示全部」;長按可複製輸出或指令。
- 放哪：顯示放 #12,送出端提示放 #13;或新開一張「Shell `!` 指令」票
- 被擋:#12、#13

### 3.2 其他功能缺口

**G3 終端機的入口：列表的終端機列與對話 header 的終端機鈕**
- 出處:S1、S3、S5、S6;README「Terminal」
- 行為:agent 以外的 pane(shell、build、`npm run dev`、vim)在 Spaces 列成「Terminal」列，副標是 herdr 回報的程式名與資料夾，點了開它的終端機;agent 的對話 header 有終端機鈕，打開那個 agent 自己的 pane。
- 放哪:#20(補入口),列表列的部分與 G2 一起做
- 被擋:#20、G2

**G5 主機圖示與 agent 種類圖示**
- 出處:README「Several computers」;S2(Claude 與 OMP 圖示不同)
- 行為：每列左側圖示表示 agent 種類;使用者可在主機清單替主機選一個圖示(桌機、筆電、伺服器…),設了之後該主機的列改顯示主機圖示，多台主機一眼分得出來。圖示只存在這支手機。
- 放哪:#10(主機圖示)、#11(agent 種類圖示)
- 被擋:#10、#11

**G7 「需要你」數量徽章**
- 出處:S8、S9、S15
- 行為：導覽入口上顯示有幾個 workspace 需要處理(blocked 或未讀);目前開在旁邊的聊天不算。不設 app 圖示徽章(app 圖示徽章屬推播，見 #29)。
- 放哪:G8 的新票，或 #31
- 被擋:G6、G8

**G8 iPhone 的頂層導覽：設定與主機的入口**
- 出處:S1、S2(「⋯」選單);S8、S14(舊版 tab bar);`.maestro` regression/menu
- 行為：從聊天列表能到「設定」「主機」「新增對話」,各自以 sheet 開啟，「完成」回到同一個列表;設定支援深層連結(`<scheme>://settings`)。
- 目前票:#31 只寫 iPad 三欄;#10、#32 寫了頁面本身，沒寫入口。HIG 研究 §6.2 也把 tab bar 列為未定。建議新開一張小票定案(選單、toolbar 或 tab bar 三選一)。
- 被擋:#3

**G9 「已釘選」群組與列上的釘選、靜音圖示**(描述不同)
- 出處:S9;App Store 第 7 張
- 行為：釘選的聊天集中在最上方的「已釘選」群組(依釘選時間排序),不會因為狀態改變而跳到別組;釘選、靜音的列在標題後顯示小圖示(不只靠顏色)。各組標題顯示數量。
- 目前票:#11 寫三組、#19 只寫「可釘選、靜音」。改寫 #11 的分組為四組，或在 #19 驗收補上。
- 被擋:#11

**G10 第一次使用的滑動提示**
- 出處:S8、S14、S15
- 行為：列表底部一行「左右滑可釘選、靜音、重新命名或關閉」,直到使用者第一次真的滑開動作為止。
- 放哪:#19
- 被擋:#19

**G11 對話 header 的資訊**
- 出處:S3、S5、S10、S11、S12;官網 callout 1
- 行為:header 標題下一行以「·」串接：非選取主機時的主機名、workspace 名稱(不同於標題時)、pane 聊天時的 agent 名、模型(例如「Opus 5」)、effort(例如「high effort」)、資料夾、狀態字(online／working／需要你／離線／重新連線)與狀態點;寧可少一段也不截斷第一段，VoiceOver 念完整內容。`/model`、`/effort` 改過之後要立刻反映。
- 放哪:#12
- 被擋:#12

**G12 Header 的重新載入與停止**
- 出處:S3、S10(重新載入);S12、S15(停止)
- 行為:agent 不在 working 時 header 有「重新載入」(清掉這個聊天的快取並重讀);working 時換成「停止」:點一下送一個 Esc,約 3 秒內沒停就提示「再點一次，或長按強制結束」;長按確認後送 Ctrl-C。停止永遠不送給 blocked 的 agent。
- 放哪：重新載入放 #12;停止的位置與長按放 #13(#13 已有「可送出中斷」)
- 被擋:#12、#13

**G13 工作中指示與即時預覽**
- 出處:S12、S15
- 行為:agent working 時，對話底部顯示動畫指示 +「Working…」(有預覽文字時「撰寫中…」)+ 從出現起算的經過時間(12s、11m 43s);有從 pane 畫面擷取到真正的散文時，在上方以次要色顯示預覽;agent 不在 working 就消失。
- 放哪:#12
- 被擋:#12

**G15 Slash 選單的參數提示與挑選行為**
- 出處:S4;README「Every slash command…」;`.maestro` regression/slash-commands
- 行為：每列除了說明，還顯示參數提示(`[pr]`、`<path>`、`<optional …>`,淡色等寬)。輸入名稱後改成單一排名清單(名稱開頭符合 > 名稱包含 > 說明包含)。點選時：不需參數的直接送出;需要參數的填入 `/name `,並在游標後淡淡顯示要填什麼;有副作用的(`/compact`、`/clear`、`/init`…)只填入不送出。
- 放哪:#15
- 被擋:#15

**G16 Slash 指令開出的原生面板**
- 出處:S11;App Store 第 4 張
- 行為:`/model`、`/effort` 這類會在終端機開面板的指令，送出後在聊天內顯示原生卡片：標題、說明、選項列(目前使用中打勾、游標所在列高亮)、effort 左右調整、面板自己的動作鈕(設為預設、只用於此 session、取消)。點選項時 app 送方向鍵移動游標，不送數字。
- 放哪:#15(把「面板用方向鍵操作」展開成可見的 UI 描述)
- 被擋:#15、#12

**G17 Codex 等 agent 的 slash 選單**
- 出處:README「Codex chats get Codex's own menu.」
- 行為:Codex(以及 Grok、Antigravity)聊天打 `/` 時，顯示那個 agent 自己的指令清單;Pi／OMP 沒有選單。
- 放哪:#24(Codex)、#25(其他)
- 被擋:#15

**G18 主機編輯器的 herdr 路徑與 herdr session 欄位**
- 出處:S13
- 行為：新增／編輯主機時可填 herdr 執行檔路徑(空白 = `herdr`)與具名 herdr session(空白 = 預設;說明「除非這台機器跑不只一個 herdr session,否則留空」)。主機清單上，設了具名 session 的主機要附註 session 名稱。
- 放哪:#7;#2 故事 1 也要補
- 被擋:#7

**G19 終端機按鍵列的符號鍵**(描述不同)
- 出處:S6
- 行為：按鍵列除了 Esc、Tab、Ctrl、Alt、方向鍵、Home／End,還有 `/`、`-`、`|`、`~` 這些在 iOS 軟體鍵盤上要切頁才打得到的符號;貼上與收起鍵盤是列尾獨立的兩顆鈕。
- 放哪:#20(按鍵清單補四個符號;DESIGN.md「終端機」一節的按鍵清單也一併更新)
- 被擋:#20

**G20 終端機 header 的連線狀態字**
- 出處:S6
- 行為:header 標題(程式名 · 資料夾)下顯示狀態點與文字：連線中…／已連線／連線中斷／已結束(exit N);中斷時給「重新連線」,被其他 client 佔用時給「接管」。
- 放哪:#20
- 被擋:#20

**G21 貼上圖片與圖片泡泡**
- 出處:README「Type like on a Mac」「Show it, don't describe it」;S12、S15
- 行為：接實體鍵盤時 Command-V 把剪貼簿裡的圖片加成附件(剪貼簿只有圖片、沒有文字時才這樣);剪貼簿有圖時「加入圖片」先問「相簿／貼上圖片」。泡泡內的圖片點開全螢幕。
- 放哪:#16
- 被擋:#16、#13

**G22 輸入列的「收起鍵盤」鈕**
- 出處:S4
- 行為：輸入列聚焦時多一顆鈕，收起鍵盤但保留草稿、不送出(軟體鍵盤的 Return 是換行，沒有別的方式收鍵盤)。
- 放哪:#13
- 被擋:#13

**G23 iPad 的版面圖浮動卡**
- 出處:S7;README「Spaces」
- 行為:iPad 上版面圖不是 sheet,而是浮在列表旁的卡片：游標停在版面圖按鈕上就出現、移開就消失;點按鈕則釘住，按「關閉」、點背景或 Esc 才關。
- 放哪:#19(或 #31)
- 被擋:#19、#31

**G24 「You should know」的列表提示與動作**
- 出處:README「What you should know, from the side」;`.maestro` regression/you-should-know
- 行為：列表標題下一行「✦ N 則註記」;該聊天的輸入列上方顯示註記，動作有「深入了解」「早就知道」「在聊天中討論」(把註記放進輸入框)、「略過」,以及從列表跳到所屬聊天的「前往」。
- 目前票:#23 只寫「顯示註記並可標記已讀」,動作比截圖與 README 少。改寫 #23。
- 被擋:#23

**G25 Workflow 畫面的 phase 與 agent 列表**
- 出處:README「…or a workflow to see each phase and each agent in it」;`.maestro` regression/subagents
- 行為：打開 workflow 卡看到摘要與各 phase,每個 phase 列出其中的 agent(狀態、tokens、工具呼叫數、正在做什麼或結果預覽),每個 agent 可再打開它自己的對話。
- 放哪:#17(驗收補一條)
- 被擋:#17

### 3.3 缺口統計

共 **25 個缺口**(G1–G25)。其中「描述不同」4 個(G4、G9、G19、G24),其餘為無票或只有部分涵蓋。

### 3.4 待確認(不計入缺口)

- **對話 header 的錘子扳手圖示鈕**(S3、S5、S10–S15):README 與網站都沒說明它做什麼。可能是工具串展開的開關或聊天層級的設定;若要對應，需另外確認(不讀程式碼的話，只能在 TestFlight／App Store 版實際操作)。
- **對話中的日期分隔**(S19「Today 12:06」、官網範例):只出現在舊版宣傳圖，新版截圖的訊息都在同一天，看不出是否仍存在。

---

## 4. 刻意不做，或已由決策取代的項目

| herdrchat 的元素 | 出處 | Drover 的決策 | 依據 |
|---|---|---|---|
| App 內的深淺色設定(系統／淺色／深色) | spec F15;README 沒有 | 不做，跟隨系統 | #2 Out of Scope「app 內的深淺色設定(跟隨系統)」;`DESIGN.md`「顏色」一節;#32 驗收「不提供 app 內深淺色設定」 |
| 主機主題檔 `~/.herdrchat/theme.json`、「Copy prompt for an agent」、「Reload theme」 | README「Theming」 | 不讀 herdrchat 的主題檔;改為經同意後套用主機 herdr 的配色 | #2 Out of Scope「讀取 herdrchat 既有的主題檔或與 herdrchat 共用主機上的資料」;#23 驗收「不讀 herdrchat 的主題檔」 |
| GitHub 給星卡(使用 3 天後出現一次) | spec F19;`.maestro` regression/welcome | 改用系統 `requestReview` 評分 | #2 故事 114;#34 |
| 紫色 tint、Catppuccin 狀態色、深色卡片列 | 全部截圖 | 品牌紅三值、系統 grouped list | `DESIGN.md`「選定方向」「顏色」;ADR-0008 |
| Agent 文字全寬、不是泡泡 | S3、S10 | Agent 用系統次要背景的標準泡泡 | `DESIGN.md`「畫面重點 › 對話」 |
| iPad 兩欄(列表 + 對話) | S5、S6、S14、S15 | 三欄 `NavigationSplitView`(主機與 workspace → Agent 列表 → 對話) | #2 故事 105 與「UI 與設計」;#31 |
| iPad 上終端機開在列表旁的詳細欄 | S6、README「Terminal」 | 終端機全螢幕;iPad 可開在新視窗 | `DESIGN.md`「方向 A」「終端機」;#20;#31 |
| 推播由主機上的 watcher 直接用使用者自己的 APNs key 發送、「沒有 relay」 | 官網 FAQ、README | 主機外掛 + Drover 後台轉送，屬 Drover Chat Plus 訂閱功能 | ADR-0004、ADR-0007;#2「推播(Drover Chat Plus)」;#29 |
| 「No HerdrChat account」 | README、官網 | 聊天與終端機免登入;推播與主機同步需要會員 | ADR-0007;#2 故事 90;#27 |
| 新主機預設密碼認證;支援 RSA | S13、spec F1.2 | 預設 Secure Enclave 金鑰，另有 Tailscale SSH;不支援 RSA | ADR-0003;#2 Out of Scope「RSA 金鑰與 SFTP」;#7、#8 |
| Android(實驗性) | README | 不做(只預留可攜核心) | #2 Out of Scope;ADR-0006 |
| 分組可收合、舊版 tab bar、agent 泡泡與單行工具呼叫 | S8、S17、S18 | herdrchat 自己後來已改掉(群組永遠展開、改用「⋯」選單、工具串摘要),不需對應;入口的問題見 G8 | spec F2.2;S1、S10 |
