# Heeler 行為研究(對照 #130)

- 查詢日期：2026-11-18
- 來源:https://github.com/ZingerLittleBee/Heeler,commit [`9315069f27a5670f2861e0d76f2fbb97575b56f2`](https://github.com/ZingerLittleBee/Heeler/commit/9315069f27a5670f2861e0d76f2fbb97575b56f2)(2026-11-17)。以下行號都指這個 commit。
- 授權:Apache License 2.0([LICENSE][license])。
- **Clean-room 聲明**:比照 ADR-0001 的精神，本筆記只用自己的話描述 Heeler 的**行為與做法**,不貼它的程式碼、不沿用它的型別名稱與模組結構;要參考細節時看這裡的來源連結(檔案路徑與行號),不要把它的實作搬進 Purrdr。數字(上限、間隔)是 Heeler 的設定值，列出來是為了理解它的取捨，不是 Purrdr 的規格。

## 1. Heeler 是什麼

- 獨立的 iOS(iPhone／iPad)app,定位是 herdr 的行動端用戶端與 coding agent 主控台：在手機上看多台主機上的 Agent(依「需要你」排序)、開即時終端機、以原生訊息閱讀並回覆對話(Chat)。已上架 App Store(「Heeler for herdr」)與 TestFlight。([README][readme] 開頭與 Features)
- 與 herdr 的關係：獨立第三方用戶端，不改 herdr;主機端前提只有 SSH 與正在跑的 herdr。除了 herdr TUI,也支援 Herdr 桌面 app／headless herdr-core 與 tmux 3.3+ 三種「Server Kind」。([README][readme]「How it connects」)
- 平台與技術棧:SwiftUI、Swift 6 strict concurrency、iOS 18+;SSH 是 repo 內的 local package,包 libssh2 與 OpenSSL(pin 版本、提交 XCFramework);終端機以 libghostty 繪製。另有 Cloudflare Worker 的推播 relay(`relay/`,端對端加密)、Node 的 herdr plugin 與 Host Helper(`plugin/`,配對、通知、用量)。([CLAUDE.md][claudemd]「Architecture」、[ADR 0011][adr11])
  - 與 Purrdr 的差異：它用 OpenSSL;Purrdr 因出口合規只用系統加密(見 AGENTS.md「出口合規」),這部分不能照搬。
- 授權：Apache-2.0。

## 2. 對話紀錄的讀取與即時更新(#130 的主要問題)

### 2.1 讀取方式：輪詢，經 SFTP

- 對話紀錄以 **SFTP 唯讀**讀主機上 Agent 程式自己寫的檔案(Claude Code 的 project JSONL、Codex rollout、Pi、Grok Build、Antigravity),共用主機既有的 SSH 連線，主機上不裝任何東西。OpenCode 例外：讀它的 SQLite(每次輪詢一個 exec)。herdr 只負責 Agent 身分、狀態、`agent_session`(用來找到對話紀錄)與送出。([ADR 0024][adr24-intro] 第 7–27 行)
- **是輪詢，不是 tail -f 或事件**。每次輪詢先 stat 一次，檔案沒變就只花這一個 stat。([follower:189-214][f-poll]、測試名稱「an unchanged file costs one stat」[f-tests:56][f-tests])
- 節奏:Agent 在 Working／Blocked、背景工作還在跑、或變化／送出／狀態改變後 15 秒內，每 **1 秒**;其他時候每 **4 秒**。畫面隱藏時用閒置節奏。([ADR 0024][adr24-read] 第 366–372 行、[store:91-100][s-timing]、[store:1342-1351][s-pace]、[store:1252-1281][s-loop])
- 前提是主機有 SFTP subsystem;沒有時目前會一直重連(open issue [#596][i596])。

### 2.2 落後很多、一次寫入大量內容：分段追上，**不取代**

- 打開聊天時讀檔案**最後 1 MiB**(tail window),切掉視窗開頭不完整的那一行。([follower:17-48][f-limits]、[follower:116-160][f-open])
- 即時追蹤時，每次輪詢從游標往後讀，**單次輪詢最多 2 MiB**(每個 SFTP read 最多 256 KiB,各自在傳輸期限內)。讀到上限就把已完整的行交出去、記住位置;**剩下的留給下一次輪詢接著讀**。它不會因為落後太多而改讀新的 tail window,也不會取代畫面上的訊息。([follower:17-48][f-limits]、[follower:261-283][f-forward])
  - 下一次輪詢照一般節奏(工作中 1 秒),沒有「還有沒讀完就立刻再讀」的加速;「還有沒讀完」只拿來判斷送出確認、快取是否可信等。([engine:561-566][e-progress]、[store:1158-1162][s-unread]、[engine:770][e-save])
- **以完整行為單位，不切斷一行**:游標依實際收到的 bytes 前進(不信任主機回報的長度);一行要等到換行字元到了才交出，跨越讀取上限的半行留在 framer 裡，下一次輪詢補齊。([follower:3-12][f-doc]、[framer:31-42][framer-doc])
- **超大單行**:一行超過 8 MiB 時不整行放進記憶體，只留前 16 KiB 並記下真實長度，其餘略過到下一個換行;畫面上的工具輸出預覽本來就只解最多 40 行或 8 KiB,展開時再依該行的位移與長度重讀(最多 1 MiB)。([framer:39-42、101-115][framer-absorb]、[ADR 0024][adr24-tool] 第 416–420 行、[follower:390-400][f-line])

### 2.3 去重與保留已載入的舊頁

- 新行接到解析器既有的狀態後面(append),往上翻載入的舊頁從前面接上(prepend);每次都由解析器的完整狀態重新投影出整份訊息列表，所以即時追蹤不會丟掉舊頁。([engine:519-561][e-poll]、[engine:639-699][e-older])
- 訊息 id 來自 Agent 記錄本身(Claude Code 是每筆記錄的 uuid 加上種類前綴),同一 id 只加入一次;串流時 Claude Code 會把同一則回應的同一個 block 寫成多筆記錄，挑「目前分支」時同一個 (message id, block index) 只留一筆。([Claude 投影:1290-1300][c-add]、[分支挑選:311-345][c-dedup])
- 只顯示目前分支(依 `parentUuid` 走，rewind 掉的分支隱藏);compaction 之後的歷史仍保留在分隔線上方。([分支挑選:19-31][c-chain]、[ADR 0024][adr24-read] 第 366–373 行)
- 往上翻：接近頂端自動載入;每次請求一頁一頁往回讀(第一頁 512 KiB,單行放不下就加倍到 8 MiB),直到帶回「一個還沒顯示過的 turn 的開頭」或讀到檔頭，最多 32 MiB(Grok Build／Antigravity 自動載入時限 4 MiB)。每頁到了就先顯示，頁與頁之間也去讀 Agent 新寫的內容。往回讀時發現視窗前的 bytes 變了，就放棄並重開。([ADR 0024][adr24-older] 第 397–415 行、[follower:216-257][f-older])
- 本機快取：已顯示的訊息(含舊頁)最多每 10 秒存一次到裝置。重新打開時若檔案大小、開頭 4 KiB、游標前 64 bytes 都和快取相同，就**不重讀 1 MiB**,直接從快取續讀;檔案長大了就讀新的 tail window,並把快取中「位移在視窗之前、id 不在即時列表裡」的訊息接在上方——條件是快取的範圍和新視窗**沒有缺口**,有缺口就只顯示新視窗。([engine:751-790][e-save]、[engine:1313-1395][e-confirm]、[engine:1491-1560][e-join])

### 2.4 檔案被換掉、變小、session 改變

SFTP v3 沒有 inode、修改時間只到秒，所以它**以內容判斷身分**:開檔時記下檔案開頭 4 KiB,並一路記住游標前最後 64 bytes。([follower:3-12][f-doc]、[follower:285-309][f-reload])

| 情況 | 判斷 | 處理 |
|---|---|---|
| 檔案沒變 | stat 的大小等於游標、修改時間相同 | 什麼都不讀 |
| 大小相同但修改時間變了 | 重讀游標前 64 bytes 比對 | 相同就當沒變;不同視為改寫 |
| 有新內容 | 先重讀游標前 64 bytes,和記住的相同才往後讀 | 接上(2.2) |
| 檔案變小，或游標前 64 bytes 對不上 | 視為**原地改寫**或**換了檔案** | 重開 tail window;比對新舊檔頭(或程式自訂的身分欄位)判斷是同一段對話被改寫還是另一個檔案 |
| 檔案不見 | stat 回不存在 | 保留畫面上的內容，重新尋找(Claude `/cd`、Codex 封存會搬檔) |

([follower:189-214][f-poll]、[engine:519-561][e-poll];測試：原地變小保留身分、同名換檔、改寫後變大、同大小改寫 [f-tests:116-160][f-tests])

- 重開(reset)時：建一個新的解析器吃新的 tail window,再把快取中視窗之前的訊息接回上方(同 2.3 的無缺口條件);若檔頭顯示已是**另一段對話**,刪掉快取。位移可能已指向別的記錄時，遞增一個「版面世代」計數，讓送出確認之類依位移判斷的邏輯失效重算。([engine:1408-1446][e-start])
  - 注意：舊頁只靠快取接回;最近 10 秒內載入、還沒存檔的舊頁在 reset 時可能掉，往上翻會再讀。這是從程式推論，未找到對應測試或 issue。
- **session 改變**(herdr 回報不同的 `agent_session`,例如 Claude `/clear`):整個換一個對話引擎、對話世代遞增;畫面列表看到世代變了就整批重載、清掉展開狀態、**回到跟隨並捲到底**。Agent 閒置時至少每 5 秒重讀一次 Agent 紀錄，因為 `/clear` 等不會產生事件。([store:1750-1770][s-switch]、[timeline model:127-150][t-model]、[ADR 0024][adr24-read] 第 380–385 行)

### 2.5 捲動：內容被整批取代時

列表是 `UICollectionView`(cell 內放 SwiftUI)。([timeline:70-78][t-doc]、[ADR 0024][adr24-read] 第 389–392 行)

- **跟隨狀態**:離底部 24pt 以內算在底部;跟隨時每次版面更新都釘在底部。([follow latch:17-40][latch])
- **同一段對話的更新**(新增、舊頁、原地改寫):更新前記下畫面上可見的列與各自離可見頂端的距離;套用後找**第一個還存在的列**放回原位。都不存在(例如整批換掉)就**捲到底**。任何還原的位移都夾在 [最小, 最大] 捲動範圍內，所以不會停在內容之外。更新時先排版、還原，再排版、再還原一次(上方剛量好高度的列會推動下面)。([timeline:453-500][t-apply]、[timeline:1260-1287][t-capture]、[timeline:1298-1336][t-restore])
- **換了對話**(對話世代改變):整批 reload、重設跟隨、釘到底，見 2.4。([timeline:411-450][t-reset])
- 使用者正在拖曳或回彈超出邊界時，暫緩套用新列，放手後再套。([timeline:391-398][t-hold])
- 收合控制項出現時，接近底部會移到底，讓最新列不被蓋住;遠離底部則只保留留白讓最後一列能捲出來。([ADR 0024][adr24-collapse] 第 977–996 行)

### 2.6 對 #130 的對照

- Heeler 正好採用 #130 Implementation Decisions 的第一種做法：**畫面已有內容時分段接著讀**(每次輪詢 2 MiB 上限，下次從新游標繼續),「讀新視窗」只用在打開／重開／真正的斷層。
- 它的「真正的斷層」偵測(檔案變小、游標前 anchor 對不上、同大小但時間變)比單純比大小嚴格，對應 #130 的 R-B09／R-B15。
- 重建時捲動的保底是「找不到原本的列就捲到底、位移一律夾在範圍內」,對應 #130 的「不可留在內容之外」。
- 與 Purrdr 現況不同的前提：它經 SFTP 直接 range read,不需要主機腳本;Purrdr 走主機指令(`TranscriptCommand`),要分段就得在主機腳本加「從游標讀最多 N bytes 的完整行」的回應(#130 已寫到)。
- 未找到：Heeler 對「一次輪詢超過上限、下次接著讀」的直接單元測試(follower 測試的上限設很大);也未找到 VoiceOver 在大量新內容時的處理。

## 3. 連線方式與 Agent 狀態

- **macOS／Linux 的 herdr TUI**:經 SSH 的 `direct-streamlocal` channel 直接連主機上的 `herdr.sock`,講 herdr 的 JSON API(NDJSON);**每個 API 請求開一條 channel**(一次性),**一條長駐 channel 收事件串流**;互動終端機在 SSH PTY 上跑 `herdr agent attach --takeover`。主機禁止 stream-local forwarding 就在 preflight 失敗並說明，不退回 exec + socat。([README][readme]「How it connects」、[ADR 0011][adr11]、[compat:9-40][compat])
- **原生 Windows**:API 與事件改用 `herdr remote-api-bridge`,終端機用 `herdr terminal session control`(都是 SSH exec);這是平台分支，不是 Unix 失敗後的 fallback。([compat:9-16][compat]、[ADR 0018][adr18])
- **herdr-core**:一條 framed link(Unix 用 direct-streamlocal,Windows 用 `herdr-core connect` exec),連線時不會啟動 core。**tmux**:SSH exec 呼叫 tmux,inventory 用輪詢迴圈，終端機用 control mode。([CLAUDE.md][claudemd]「Architecture」)
- **Agent 狀態**:訂閱事件;每次訂閱 ack(含重新訂閱)後都要重新拿一次 `session.snapshot`,因為 herdr 0.9.0 的訂閱不重播訂閱前的事件;斷線用有上限的指數退避、無次數上限，需要使用者處理的錯誤則停止並顯示原因;事件 channel 以 herdr 的一般 RPC 當 ping(近期有流量就略過)。([EventsSession 註解][events])
- **session**:herdr 回報的 `agent_session` 給出 Claude Code session id、Codex thread id 等，Chat 依此找對話紀錄檔。([ADR 0024][adr24-intro] 第 18–26 行)

## 4. 其他值得參考的做法

- **需要你／問題卡(Blocked card)**:Agent 為 Blocked 時，以 `agent.read` 讀可見畫面(含 ANSI 顏色，用來分辨窄 pane 的殘留文字),配合對話紀錄中未完成的請求，畫成原生卡片;選項文字用程式自己的文字。回答前比對對話框指紋，變了就不送;對話框出現滿 150 ms 才按鍵(`agent.send_keys`),文字答案用 `pane.send_input`;以畫面變化或對話紀錄的工具結果確認，3 秒沒效果只顯示提示、不重送。herdr 對 Claude 的部分問題頁回報 idle,所以對話紀錄有未完成的 AskUserQuestion 時也讀畫面。([ADR 0024][adr24-blocked] 第 648–675 行)
- **送出前檢查**:送出前讀畫面，輸入框必須是空的、上面沒有會吃按鍵的東西，否則不送並說明原因;送出 3 秒後再讀畫面，框裡還有字就標「未送達」,絕不重送。會被程式當指令執行的草稿(開頭 `!`、控制字元、整句 `exit`／`:q` 等)一律不送。([ADR 0024][adr24-send] 第 515–573 行)
- **Slash**:開頭 `/` 必須是 `/` 選單裡的項目(主機上探測到的 skills,加上閒置時的 `/compact`);選單不提供互動或破壞性的程式指令;`user-invocable: false` 的 Claude skill 不列;Codex skill 以 `$name` 送。送出時補一個結尾空白，避免補完選單在 Enter 時還開著。([ADR 0024][adr24-send] 第 535–558 行)
- **建議提示詞(prompt suggestions)**:Heeler 沒有把它當功能;反而有 open issue 指出 Claude Code 開著 prompt suggestion 時，Heeler 找不到輸入框而拒絕送出([#540][i540])。Purrdr 做送出前畫面檢查時要把淡色建議文字當成空框(#121 相關)。
- **Stop**:Working 且草稿空白時 Send 變成 Stop(按程式的 Stop 鍵，例如 Esc;OpenCode 要兩次),之後等 Agent 狀態離開 Working 才恢復，3 秒後仍 Working 就說明。([ADR 0024][adr24-send] 第 578–590 行)
- **終端機**:libghostty 繪製、原生 scrollback 與慣性捲動(也驅動全螢幕 TUI)、長按選取、接管過期的終端機擁有者(`--takeover`);Chat 畫面不持有 attach、不改 pane 大小。([README][readme] Features、[ADR 0024][adr24-entry] 第 347–360 行)
- **對話開啟秒開**:連上主機後，Console 先替每個列出的 Agent 讀一次對話紀錄存進快取(Chat 隱藏時),Agent 狀態變了再讀。([ADR 0024][adr24-limits] 第 1068–1072 行)

[license]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/LICENSE
[readme]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/README.md
[claudemd]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/CLAUDE.md
[adr11]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0011-libssh2-direct-streamlocal-transport.md
[adr18]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0018-native-windows-hosts.md
[adr24-intro]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L5-L27
[adr24-entry]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L347-L362
[adr24-read]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L364-L393
[adr24-older]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L395-L418
[adr24-tool]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L416-L428
[adr24-collapse]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L977-L996
[adr24-send]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L515-L590
[adr24-blocked]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L648-L690
[adr24-limits]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0024-native-chat-from-agent-transcripts.md#L1055-L1075
[compat]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/agents/herdr-compatibility.md#L9-L40
[events]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/EventsSession.swift#L1-L80
[f-doc]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L3-L12
[f-limits]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L17-L48
[f-open]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L116-L160
[f-poll]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L189-L214
[f-older]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L216-L257
[f-forward]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L261-L283
[f-reload]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L285-L326
[f-line]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L390-L400
[f-tests]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Tests/HeelerTests/TranscriptFollowerTests.swift#L35-L160
[framer-doc]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/ChatLineFramer.swift#L31-L42
[framer-absorb]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/ChatLineFramer.swift#L101-L115
[e-poll]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L517-L561
[e-progress]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L563-L568
[e-older]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L639-L699
[e-save]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L750-L790
[e-confirm]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1313-L1395
[e-start]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1408-L1446
[e-join]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1489-L1560
[s-timing]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L90-L100
[s-unread]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L1158-L1162
[s-loop]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L1252-L1281
[s-pace]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L1318-L1352
[s-switch]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L1750-L1770
[c-add]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Claude/ClaudeTranscriptProjection.swift#L1288-L1300
[c-chain]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Claude/ClaudeChainResolver.swift#L19-L31
[c-dedup]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Claude/ClaudeChainResolver.swift#L311-L345
[t-doc]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L70-L78
[t-hold]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L387-L398
[t-reset]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L411-L450
[t-apply]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L453-L500
[t-capture]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L1260-L1287
[t-restore]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineController.swift#L1298-L1336
[t-model]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatTimelineModel.swift#L127-L150
[latch]: https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Timeline/ChatFollowLatch.swift#L17-L40
[i540]: https://github.com/ZingerLittleBee/Heeler/issues/540
[i596]: https://github.com/ZingerLittleBee/Heeler/issues/596
