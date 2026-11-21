# 聊天載入時的空白畫面(截至 2026-11-21)

> **結論**
> 1. #329 只處理了「畫面上**已經有訊息**時」的情況(重新載入、換 session、對話紀錄被換掉都保留舊內容加細進度條)。**畫面還沒有訊息時**,打開聊天仍是整區「Loading conversation…」轉圈，直到主機回完 3～5 個依序執行的請求。最常碰到的是**冷啟動後第一次打開**:對話快取只存在記憶體(`InMemoryConversationCache`),app 重開就沒了。
> 2. 等待最久的是開啟視窗：讀對話紀錄**最後 300 行**,沒有 byte 上限(主機腳本從 4 MiB 起往前找)。網路慢時這一步可能要好幾秒到幾十秒，整段時間畫面都是空的。視窗之前還會先等快照、**讀 Pane 畫面**(建議提示詞、提問、即時預覽)與定位，全部依序執行。
> 3. herdr 不提供對話內容(只回報 `agent_session`),但 Purrdr 自己手上已經有兩份更早可用的資料：
>    - **列表預覽**已經讀過每個 Agent 對話紀錄檔尾 48,000 bytes。
>    - **主機服務**的 `transcript.follow` 有 byte 上限，可以分段送。
>
>    herdrchat 與 Heeler 都用「**磁碟快取先顯示，再補新內容**」。Heeler 另外在連上主機後替每個列出的 Agent **預先讀好**對話紀錄，打開聊天時直接有內容。
> 4. 建議依效果與成本排序(§6):
>    1. 先讀對話紀錄，畫面讀取延後或並行(小改)。
>    2. 開啟視窗分兩段：先讀小視窗，再自動往上補(小～中)。
>    3. 對話快取寫到磁碟(中)。
>    4. 用列表預覽讀到的檔尾或背景預讀先填畫面(中)。
>    5. 空白時改用骨架佔位(小)。
>
>    建議開一張 spec 票，含前三項。

> 標記:**【程式】** 本 repo 檔案與行號(整合分支 `origin/integration/send-pipeline-observer` `a250681`);**【原始碼】** 第三方原始碼(herdrchat `f7e00c6`、Heeler `a8d3dd3`;ADR-0012 取消 clean-room 後可讀)與作者自己的 Tripline;**【文件】** 官方文件;**【估算】** 由程式推算、未實測;**【未查得】** 找不到一手來源。

---

## 1. 現況：打開聊天時畫面顯示什麼

### 1.1 畫面規則【程式】

- `ConversationView.content`:沒有任何訊息、回音、佇列、提問、面板或工作中指示時，顯示 `placeholder`(`src/PurrdrFeatures/ConversationView.swift:106-116`)。
- `placeholder` 在 `phase == .loading` 時是置中的 `ProgressView("Loading conversation…")`(`ConversationView.swift:355-359`)。其他 phase 是 `ContentUnavailableView`(等待 session、無法辨識、不支援、Agent 已結束、尚無訊息)。
- 有訊息時，讀取中只在頂端放細進度條(`isRefreshing`,`ConversationView.swift:194-201`;DESIGN.md「重新載入不清空」#329)。
- 對照：Agent 列表第一次載入已經改用 `redacted(.placeholder)` 骨架(DESIGN.md「載入中與離線」#221),聊天沒有。

### 1.2 各條路徑

| 路徑 | 資料回來前的畫面 | 依據【程式】 |
|---|---|---|
| **冷啟動後第一次打開**(或從推播、深層連結打開) | **整區轉圈**,直到 §2 的整串請求跑完 | 快取只在記憶體:`PurrdrApp.swift:42-43`(註解寫「持久化在之後的票」)、`HostsModel.swift:162` |
| 同一次執行中再打開(快取的 session 與列表相同) | 立刻顯示快取，接著從游標續讀 | `run()` → `reopen()` → `restoreFromCache()`(`ConversationModel.swift:574-590`、`607`)。要等 `.task` 啟動並跨一次 actor,所以第一個 frame 仍是轉圈，但時間極短 |
| 同一次執行中打開，但列表還沒有 session(`knownSessionID == nil`:列表還沒讀到快照、從推播打開) | 整區轉圈 | `restoreFromCache` 要求 `knownSessionID`(`:581`);`MergedAgentListModel.sessionID(of:)` 從列表快照取(`AgentListModel.swift:65-67`) |
| 重新可見(回到前景) | 原本的訊息還在(model 沒有被丟掉);落後超過 64 KiB 時讀新視窗**取代**,讀的期間舊內容留著 | `reopen()`、`read(_:)` 的 `.tooFarBehind`(`:767-769`) |
| 下拉重新載入／換 session／對話紀錄被換掉 | 舊內容留著，加頂端細進度條(#329) | `unbind(keepingDisplay:)`(`:1932-1946`);`reload()`(`:1881-1886`) |
| 上面那條，但新 session **還沒有檔案**、`ambiguous`、`compressed`,或 Agent **還沒回報 session** | 清空，改顯示空狀態或橫幅(合理：舊內容已經不屬於這個聊天) | `showReadFailure` 與 `poll()` 裡的 `clearDisplay()`(`:707`、`:835`、`:845`、`:852`) |
| 連不上主機 | 畫面空著時唯讀顯示同一 session 的快取；冷啟動沒有快取 → 空白加離線橫幅 | `showOffline()`(`:943-963`) |
| 往上翻 | 頂端一列轉圈，不遮擋 | `olderRow`(`ConversationView.swift:334-350`) |

- 另一種「看起來是空白」的情況：捲動位置被推出內容外(#185、#251 已修;#255、#315 仍開著)。這是捲動的問題，不是資料還沒回來，不在本筆記範圍。

### 1.3 為什麼第一次打開要等那麼久：`poll()` 全部依序執行【程式】

`run()` 的第一輪 `poll()`(`ConversationModel.swift:657-719`)依序 `await`:

1. **快照**。主機更新來源已訂閱時用它的(`liveSnapshot`,`:651-654`),否則自己讀 `session.snapshot`,失敗再重試一次(`:931-941`)。從列表打開通常已訂閱，從推播冷啟動通常沒有。
2. **`refreshPrompt`**:blocked、或 `agent.session == nil` 時讀一次 Pane 畫面(`:1379-1389`)。
3. **`readSuggestion`**:Claude 是 done／idle 時讀一次 `.ansi` 畫面找建議提示詞(`:1841-1848`、`awaitsNextPrompt` `:1834-1836`)。**最常見的「打開一個做完的 Claude」,第一輪一定會讀畫面。**
4. `refreshPanel`、`refreshLivePreview`、`readAgentsPaneIfNeeded`:同一輪已讀過畫面就沿用；working 時讀(`:1667-1679`、`:1908-1918`、`:724-740`)。
5. **定位** `transcripts.locate`(`:772`)。
6. **開啟視窗** `openWindow`:讀最後 `openLines = 300` 行(`:513`、`:863-876`)。

畫面在第 6 步完成後才出現第一則訊息。第 2～4 步讀畫面只為了提問卡、建議與預覽，卻擋在對話內容前面。

---

## 2. 網路慢時每一步要等多久

### 2.1 SSH 主機【程式】【估算】

- 每個 herdr 請求、每次讀對話紀錄都開一條新的 exec 通道(AGENTS.md「herdr client」;`SSHHostConnection.readTranscript` `src/PurrdrSSH/SSHHostConnection.swift:125-132`)。通道開啟加指令加回應，約 **2 個 RTT** 加傳輸時間。
- 開視窗的腳本從檔尾 4 MiB 起找 300 行，不夠就 ×4 再找(`TranscriptCommand.windowScript`,`src/PurrdrCore/TranscriptCommand.swift:146-173`)。回傳**整整 300 行**(圖片 base64 先剝掉)，**沒有 byte 上限**。期限是 `HostCommandDeadline.transfer(bytes: 4 MiB)`,約 100 秒(`SSHHostConnection.swift:207-209`、`HostCommandDeadline.swift:12-17`)。
- 行為規格說 Claude 的單行可達 0.3–1 MB(`docs/research/herdrchat-behavior-spec.md:943`;圖片剝掉後會小很多，但大的工具結果仍在)。
- 【估算】Tailscale 經行動網路 RTT 150–300 ms、可用頻寬 1 Mbps(約 125 KB/s):
  - 還沒連線：撥號加 SSH 握手加認證，約 1–2 秒。
  - 快照(約 13 KB)約 0.5 秒；讀畫面約 0.5 秒；定位約 0.5 秒。
  - 視窗 300 行若是 200 KB–2 MB,要 **2–16 秒**。
  - 合計約 **3–20 秒**整區轉圈，視窗佔大部分。**實際大小【未實測】**,要量。
- Windows 主機每個經 stdin 的腳本多送約 7.6 KB 的 stub 與腳本(`docs/research/polling-network-usage.md` §1),每一步再慢一點。

### 2.2 HTTPS 主機(主機服務)【程式】【估算】

- 第一個操作才撥號：TLS、WebSocket upgrade、`hello`,約 3–4 個 RTT(AGENTS.md「HTTPS 主機連線」)。
- 之後每一步是一個 WSS 請求、1 個 RTT 加傳輸:`agents.list` → `pane.read`(0.7.0 起)→ `transcript.locate` → `transcript.window`。
- `transcript.window` 也只有 `lines`,**沒有 byte 上限**(`vendor/purrdr-host/protocol/host-service.schema.json` 的 `TranscriptWindow`)。所以瓶頸與 SSH 相同：300 行的大小。

---

## 3. herdr 與主機服務能提供什麼

### 3.1 herdr【文件】

- herdr 沒有任何回傳對話內容的 API。對話內容要依 snapshot 的 `agent_session` 自己讀對話紀錄檔(`docs/research/allymote-herdr-communication.md:13`、`:71`)。
- Socket API 跟輸出有關的只有：
  - `pane.read`(source `visible`／`recent`／`recent-unwrapped`／`detection`,可帶 `lines`)。
  - `pane.wait_for_output`、`agent.read`(文件只列名稱)。
  - 事件 `pane.output_matched`。
- 沒有游標式的增量讀取，事件也不保證送達("Event history is not durable"),落後時要重讀狀態([herdr Socket API](https://herdr.dev/docs/socket-api))。
- 所以 herdr 能讓第一個畫面更快的，只有「**同一次請求裡一起拿畫面**」:herdrchat 把 `session.snapshot` 與 `pane.read` 合成一次 `callMany` 送出(herdrchat `src/lib/herdr/client.ts:200-219`)。Purrdr 讀畫面是另一個請求，見 §1.3。
- `pane.read` 的 `recent` 可以拿到終端機最近的輸出，但那是終端機畫面，不是解析過的訊息。只能當成「Agent 正在做什麼」的預覽(Purrdr 已用 `LivePreview` 這樣做)，不能取代對話。

### 3.2 主機服務協定(`vendor/purrdr-host/protocol/host-service.schema.json`,主機服務 0.7.0)【程式】

- `transcript.locate` 與 `transcript.window` 是兩個請求;`window` 只有 `lines`,沒有 byte 上限。
- `transcript.follow` 有 `limit`(每則 byte 上限，落後時分段送，#173)。它的 result 直接帶「`from` 之後已有的完整行」。
- `transcript.previews` 一次回多個對話紀錄的檔尾(`records` 是原始行),並帶版本(`unchanged`／`appended`／`whole`)。
- 要讓第一個畫面更快，協定可以做兩件事(要在 purrdr.host 改 schema):
  - `transcript.window` 加 `max_bytes`:從檔尾往前取，到 N 行或 M bytes 就停。
  - `transcript.locate` 加「一併回最後 N 行」:少一個 RTT。

### 3.3 列表已經讀過的資料【程式】

- 列表預覽每個 Agent 讀**檔尾 48,000 bytes**(`TranscriptCommand.previewBytes`,`src/PurrdrCore/TranscriptCommand.swift:318-319`)。
- 但 `AgentListModel` 只留下最後一則的 `MessagePreview`(`src/PurrdrAgentFeatures/AgentListModel.swift:14`、`:195-205`;`src/PurrdrCore/Agent.swift:125-139`),其他行解析完就丟了。
- 這 48 KB 通常夠顯示最後幾則訊息。

---

## 4. 其他 herdr 用戶端怎麼做【原始碼】

### 4.1 herdrchat(`cobanov/herdrchat` `f7e00c6c6b20d769ec286f4ec1a8b77f5a768580`)

- **磁碟快取，app 重開也秒開**。檔案開頭的說明是 "Disk-backed per-thread message cache, so reopening a chat — even after an app restart — shows history instantly instead of paying an SSH read."
  - SQLite,打開時取最新 150 則(`SEED_MESSAGE_LIMIT`),每個聊天最多保留 500 則。
  - 戳記是 session 簽章加解析器版本。
  - 來源:`src/state/threadCache.ts:8-21`、`:66-67`、`:136-149`。
- **在第一次輪詢之前就用快取**:列表傳來的 session 與快取相同時，立刻顯示快取並綁定，第一次輪詢直接讀尾端，「rather than through a loading state」(`src/features/thread/useSessionBinding.ts:66-84`)。
- **對話尾端不等畫面讀取**:每輪 `bind` 之後 `void startTails(...)`(不 await)，才 `await readQuestion(...)` 讀畫面(`src/features/thread/useAgentPoll.ts:174-180`)。
  - 畫面讀取也跟快照合成一個請求(`useAgentPoll.ts:158`、`client.ts:200-219`)。
  - 對照 Purrdr §1.3:讀畫面擋在讀對話紀錄前面。
- 開啟視窗同樣是 300 行(`src/features/thread/useTranscriptTails.ts:25`)。
- 載入中同樣是一條等待列加 "Loading the conversation…"(`src/features/thread/ThreadPlaceholders.tsx:100-105`)。但有磁碟快取，所以只有「從沒開過」的聊天會看到。

### 4.2 Heeler(`ZingerLittleBee/Heeler` `a8d3dd35d31ed436d636f3906ed9f491f5cc9d6b`)

- **開啟視窗以 byte 計**:讀檔尾 **1 MiB**(`tailWindow = 1 << 20`),切掉開頭不完整的行(`Sources/Heeler/Chat/Source/TranscriptFollower.swift:19`、`:116-146`)。之後的內容分段追上，單次輪詢最多 2 MiB(`:23`;另見 `docs/research/heeler.md` §2.2)。
  - 傳輸量有上限，所以慢網路下第一個畫面的等待有上限。
  - 代價是含大量工具結果時，畫面上可能只有幾則訊息。Heeler 靠自動往上讀補回來：每頁邊讀邊顯示，有上限(`docs/adr/0024-native-chat-from-agent-transcripts.md:398-410`)。
- **磁碟快取**:
  - 存解析過的訊息與游標，不存工具輸出(展開時再讀)。
  - 位置 `Caches`,Complete file protection,300 MB LRU,30 天沒用就刪。
  - "A cached conversation opens at once, stays readable offline"。
  - 來源:ADR 0024 `:448-455`;`Sources/Heeler/Chat/Cache/FileChatTranscriptCache.swift:5-6`、`:269`。
- **背景預讀**:"So that cached conversations open at once, after each connect the Console reads every listed Agent's transcript once, with its Chat hidden, and again when the Agent's status changes"(ADR 0024 `:1092-1097`)。打開聊天時快取通常已經是新的。

### 4.3 Tripline(作者自己的 app;Flutter `/Users/ray/Projects/trip-planner.flutter`、Web `/Users/ray/Projects/trip-planner`)

| 項目 | Flutter | Web |
|---|---|---|
| 第一頁 | 最新 **10 筆**(`_pageSize`,`lib/features/chat/chat_controller.dart:91`;`loadInitial` `:108-141`) | 最新 **5 筆**(`CHAT_PAGE_SIZE`,`src/hooks/useChatPagination.ts:21`),註解寫「先看到最新對話、需要往上才載歷史」 |
| 往上翻 | cursor `(createdAt, id)`,捲近頂端自動載(`chat_controller.dart:200-231`;`chat_screen.dart:341-348`) | cursor 分頁，失敗 2 秒 backoff(`useChatPagination.ts:217-260`) |
| 快取 | 無；provider 是 `autoDispose`,每次進畫面重抓(`chat_controller.dart:374-375`、`:96-100`) | 無；同一個行程內重試不清空，換行程才清(`useChatPagination.ts:150-176`) |
| 第一次載入的畫面 | 置中 `CircularProgressIndicator`(`chat_screen.dart:528-533`) | 「載入歷史對話…」文字(`src/pages/ChatPage.tsx:844-848`) |
| 更新時 | `refreshLatest` **不清空**、不進載入狀態，把最新一頁合併回去，保留樂觀送出的暫存列，失敗靜默(`chat_controller.dart:150-197`) | 回到底部時 `refreshLatest`,只在送出鈕旁顯示小轉圈或重試鈕(`useChatPagination.ts:286-329`;`ChatPage.tsx:1005-1012`) |
| 送出 | 樂觀更新：先放暫存列，POST 回來再換真的(`chat_controller.dart:233-290`) | 同 |

- Tripline 讓第一個畫面快的方法是**第一頁很小**:伺服器以筆數分頁、每筆大小有限。慢網路下仍會轉圈，但時間短。
- 「更新不清空、合併」就是 Purrdr #329 的做法。

---

## 5. 平台指南與其他聊天 app【文件】

- **Apple HIG — Loading**:
  - "Show something as soon as possible. If you make people wait for loading to complete before displaying anything, they can interpret the lack of content as a problem with your app … consider showing placeholder text, graphics, or animations as content loads, replacing these elements as content becomes available."
  - 頁尾："The best content-loading experience finishes before people become aware of it."
  - 來源:[HIG Loading](https://developer.apple.com/design/human-interface-guidelines/loading),以 DocC JSON 讀取，2025-06-09 版。
- **Apple — Reducing your app's launch time**:"Defer synchronization of the data model with a network service until the app is running, if it makes sense to show stale content to the user while the content is being refreshed … Register a background task to fetch updates from the network service, to reduce both the staleness of data on launch"([文件](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time))。也就是先顯示舊內容，再同步。
- **SwiftUI `redacted(reason: .placeholder)`**:"Text and images will be automatically masked to appear as generic placeholders, though maintaining their original size and shape. Use this to create a placeholder UI without directly exposing placeholder data to users."([RedactionReasons.placeholder](https://developer.apple.com/documentation/swiftui/redactionreasons/placeholder))。Purrdr 的列表已經在用(#221)。
- **Facebook Messenger(Project LightSpeed)**:"All the caching, filtering, transactions, and queries are all done in SQLite. The UI merely reflects the tables in the database."新版 iOS app "twice as fast to start"([Engineering at Meta, 2020-03-02](https://engineering.fb.com/2020/03/02/data-infrastructure/messenger/))。UI 讀本機資料庫，網路只負責同步進資料庫。
- **Discord iOS**:打開聊天時把訊息載入與 cache restore 當成同一條路徑最佳化("Our message load/cache restore actions — which directly result in processing and rendering our chat messages — resulted in a 500ms on an iPhone XS")([Discord blog](https://discord.com/blog/how-discord-achieves-native-ios-performance-with-react-native))。
- 主流 AI 聊天 app(ChatGPT、Claude)的本機快取策略:**【未查得】**,找不到官方工程文章，不引用。
- Apple Messages 的載入實作沒有公開文件:**【未查得】**。

---

## 6. 建議(依效果與成本排序)

1. **先讀對話紀錄，畫面讀取延後或並行**(效果中高，成本小)
   - `poll()` 第一輪把 `read(target)` 移到 `refreshPrompt`、`readSuggestion`、`refreshLivePreview` 之前，或用 `async let` 並行。
   - 畫面讀取的結果(提問卡、建議、預覽)本來就是附加在對話下方的卡片，晚一點出現不影響閱讀。
   - 省下 1 個請求(SSH 一條 exec 通道，約 0.5 秒【估算】)。這是 herdrchat 的順序(§4.1)。
   - 要注意：提問卡判定 `agentStatus = .blocked` 的時機不能倒退。測試以 `FakeHostConnection` 斷言請求順序。
2. **開啟視窗分兩段：先小視窗，再自動往上補**(效果高，成本小～中)
   - 第一次先讀約 30–50 行，或加 byte 上限(例如 256 KiB),畫面出來後立刻用現有的 `loadOlder()` 補到 300 行。
   - SSH 只要改 `openLines` 加一個自動往上補的步驟；byte 上限要改 `windowScript`。HTTPS 要 purrdr.host 在 `transcript.window` 加 `max_bytes`(§3.2)。
   - Heeler 用 1 MiB 上限加自動往上讀(§4.2)。Tripline 用小的第一頁(§4.3)。
   - 要先在真主機量 300 行的實際 byte 數，決定門檻。
3. **對話快取寫到磁碟**(效果最高，冷啟動也秒開；成本中)
   - `ConversationCache` 已經是 protocol,`CachedConversation` 已經是 `Codable`(`src/PurrdrAgentFeatures/ConversationCache.swift:7-14`、`:36`)。加一個 Caches 底下、每個聊天一個 JSON 檔的實作就能換上，不需要 SwiftData。
   - 要處理：
     - 檔案保護(Complete,比照 Heeler)與不進備份。
     - 刪除主機時清掉(`removeAll(chatKeyPrefix:)` 已有)。
     - 隱私權頁說明對話內容會存在裝置上(Heeler 有寫進 PRIVACY)。
     - 寫入節流：現在每次追蹤事件都 `saveCache()`(`ConversationModel.swift:817`)。
   - 行為規格 F5.2 本來就是持久快取(`docs/research/herdrchat-behavior-spec.md:298-307`)。
4. **用已經讀到的檔尾先填畫面**(效果中高，成本中)
   - 做法 a:列表預覽的 48 KB 檔尾除了最後一則，也保留最後 N 則解析過的訊息(或原始行)。打開聊天時當成**暫時內容**顯示(不寫快取、沒有游標)，視窗讀回來再換上。
   - 做法 b:比照 Heeler,連上主機後替列出的 Agent 預讀並寫進 3 的快取。
   - 兩者都要守住流量預算(`docs/research/polling-network-usage.md`)。做法 a 不增加流量。
   - 做法 a 的難點：預覽是 SSH 腳本與 `transcript.previews` 的輸出格式，要多保留資料；換成正式視窗時捲動位置要穩定。
5. **空白時改用骨架佔位**(效果小，成本小)
   - `phase == .loading` 時以 `redacted(.placeholder)` 畫 3–4 個泡泡骨架(對 VoiceOver 隱藏)，取代置中轉圈。與列表(#221)一致，符合 HIG「show something as soon as possible」。
   - 只改觀感，不縮短等待，所以排最後。做了 1～4 之後，它只在從沒開過、又沒有預覽的聊天出現。

**要不要開票**:建議開一張 spec(「聊天第一個畫面更早出現」)，含 1、2、3。

- 1 和 2 是 SSH 與 HTTPS 共用的小改動，可以先做。
- 3 是獨立的一張(持久化，含隱私權說明)。
- 4 等 1～3 上線後量過再決定。
- 2 的 HTTPS 部分(`max_bytes`)要在 purrdr.host 開對應的票。
- 5 可以併進 1 的票順手做。
- 開票前先在真主機量兩件事:300 行視窗的 byte 數，以及 SSH／HTTPS 各步驟的時間(可加在 `scripts/host-poll-repro/`)。
