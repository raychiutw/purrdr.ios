# 點進聊天時怎麼讀對話紀錄:Heeler、herdrchat、herdr 的做法(#656)

調查日期:2026-11-27。目的:替 #656 決定 SSH 點進聊天的讀取方式——
**A**:一個主機指令「定位 + 讀較大的檔尾」,由 Swift 解析器判斷夠不夠,不夠才往前補讀;
**B**:主機腳本用粗略規則(例如 grep `"type":"text"`)自己往前讀到有訊息為止,幾乎一定一次往返,但每種 Agent 方言要多維護一套近似的「可讀」規則。

## 版本基準

| 專案 | commit | 備註 |
|---|---|---|
| Heeler | [`6fa4fea`](https://github.com/ZingerLittleBee/Heeler/tree/6fa4fea759a6a7575c521c985d9891fe03d12df4)(2026-11-27) | `docs/research/heeler.md` 引用的是 `4db5ce0`／`9315069`;本文重新核對最新 commit |
| herdrchat | [`1913690`](https://github.com/cobanov/herdrchat/tree/1913690e6a918d6f8411914c5c881b457b6ca6bf)(2026-11-23) | `docs/research/herdrchat-behavior-spec.md` 依 `0ed5f50`;未讀 `legacy/` |
| herdr | [`e8d7d97`](https://github.com/herdrdev/herdr/tree/e8d7d9705a7a2c89cef4dd42079379f05685af87)(2026-11-20) | 文件看 `docs/next/website/src/content/docs/socket-api.mdx` |
| Purrdr | `origin/master` `7f54b7b` | 現況對照 |

以下連結縮寫:
- `H:` = `https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/`
- `C:` = `https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/`
- `R:` = `https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/`

## 比較表

| 問題 | Heeler | herdrchat | herdr | Purrdr 現況(SSH) |
|---|---|---|---|---|
| 1. 定位 | herdr 的 `agent_session` id → app 端用 SFTP stat 試 `<config>/projects/<key>/<id>.jsonl`,再讀檔頭驗證 session;有快取路徑時先驗快取路徑 | herdr 的 session id → app 端組出路徑(Claude 設定目錄每條連線問一次後快取),再一個 exec 探測大小;不在時另一個 exec 全專案找同名檔 | 只提供 `agent_session`(id;Pi／OMP 才有路徑),不讀對話紀錄 | `TranscriptCommand.locate` 一個 exec,印路徑與大小 |
| 2. 開啟讀多少 | 最後 **1 MiB**(原始 bytes) | 最後 **300 行**,主機端剝除圖片 base64 | — | 最後 **40 行,且不超過 64 KiB** |
| 3. 往返次數 | SFTP 請求:stat、讀檔頭、4 個 256 KiB 讀取(依序),同一條 SFTP 通道,沒有開 exec／shell 的成本 | 探測 1 個 exec + 視窗 1 個 exec(+ 追蹤串流 1 個) | — | snapshot + locate + window 3 個 exec,視窗沒訊息再加每頁 1 個(最多 25 頁) |
| 4. 誰判斷「夠不夠」 | **app 端解析器**:往前讀到「帶進一個沒看過的回合開頭」 | **沒有人**:只顯示尾端;往上翻時才「整頁都重複就再讀」 | — | app 端 `hasReadableMessage` |
| 5. 往前讀 | 每頁 512 KiB 起、加倍到 4 MiB,一次請求最多 32 MiB;列表不滿一畫面或接近頂端時自動要 | 每頁 200 行;使用者拖動過後接近頂端才讀;整頁重複最多連讀 6 頁 | — | 每頁 200 行;開啟時的補讀加倍到 1,600 行 |
| 6. 本機快取先顯示 | 有;大小、檔頭 4 KiB、游標前 64 bytes 都相同就不重讀 1 MiB;連上後在背景替每個 Agent 預讀 | 有(SQLite,開啟載入最新 150 則,每聊天最多 500 則);session 簽章相同才秒開 | — | 有(`restoreFromCache`) |
| 7. 傳輸 | 既有 SSH 連線上的 **SFTP**(libssh2);OpenCode 例外是每次一個 exec | 持久 SSH 連線上**每個指令一個 exec**,追蹤是長駐 `tail -f` exec | 本機 Unix socket(遠端經 `remote-api-bridge`) | 每個指令一個 exec;追蹤是長駐 exec 通道 |

## 一、Heeler(已核對到 `6fa4fea`)

### 已驗證事實

- **傳輸與分工**:對話紀錄以 SFTP 唯讀讀取,共用主機既有的 SSH 連線,主機上不裝任何東西;herdr 只提供 Agent 身分、狀態與 `agent_session`。([H:docs/adr/0024-native-chat-from-agent-transcripts.md#L5-L23](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L5-L23))每次輪詢都是 SFTP 請求,只有 OpenCode 每次一個 exec。([ADR 0024#L1161-L1164](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L1161-L1164))
- **定位(Claude)**:依 session id 在每個設定目錄的 `projects/<key>/<id>.jsonl` 逐一 stat,找到後讀檔頭驗證是同一個 session;長資料夾名以前綴列目錄(最多 100 筆)。([H:Sources/Heeler/Chat/Source/ClaudeTranscriptLocator.swift#L113-L200](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Source/ClaudeTranscriptLocator.swift#L113-L200))
- **有快取路徑時先走捷徑**:`fastLocateCachedFile` 只 stat 快取的路徑並讀檔頭 4 KiB 比對,成功就把 stat 與檔頭交給 `open`,不再搜尋(Codex 除外)。([H:Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1634-L1676](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1634-L1676)、[#L580-L614](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L580-L614))
- **開啟讀多少**:`tailWindow = 1 << 20`(1 MiB);單次讀取 `readChunk = 256 << 10`;每次輪詢最多 2 MiB;往前讀第一頁 `olderPage = 512 << 10`,搜尋時每頁最大 `olderSearchPage = 4 << 20`,一次請求最多 `olderSearch = 32 << 20`;檔頭 `headLength = 4 << 10`。([H:Sources/Heeler/Chat/Source/TranscriptFollower.swift#L19-L50](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L19-L50))`open` 從 `size - tailWindow` 讀到檔尾,丟掉開頭不完整的行。([#L128-L171](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L128-L171))ADR 也寫「opens on the last 1 MiB」。([ADR 0024#L365-L372](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L365-L372))
- **讀取是依序的 256 KiB 請求**:`ChatHostFiles.read` 以迴圈一塊一塊讀。([H:Sources/Heeler/Chat/Source/ChatHostFiles.swift#L91-L106](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Source/ChatHostFiles.swift#L91-L106))
- **誰判斷「夠不夠」:app 端**。往前讀的每次請求一頁一頁讀,直到「帶進一個畫面上沒有的回合開頭」(比較投影後第一個 turn 的 `firstEntryID`),或到檔頭、或讀滿 32 MiB;頁長每次加倍到上限。([H:ChatConversationEngine.swift#L735-L836](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L735-L836))ADR 的說法:頁的結尾落在回合中間只會增加被摺起的步驟,所以要讀到回合開頭。([ADR 0024#L397-L412](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L397-L412))
- **自動往前讀的時機**:使用者要求,或「時間軸的列不滿一個畫面」時自動要(`automatic`)。Grok Build、Antigravity 的自動搜尋限 4 MiB(`automaticOlderSearch = 4 << 20`),其他程式沒有上限。([H:Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L815-L829](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L815-L829)、[GrokTranscriptReducer.swift#L694](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Grok/GrokTranscriptReducer.swift#L694)、[AgyTranscriptReducer.swift#L1048](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Agy/AgyTranscriptReducer.swift#L1048))
- **快取**:解碼後的訊息與讀取游標存在 Caches(上限 300 MB、30 天),快取的對話立即開啟、離線可讀。([ADR 0024#L450-L455](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L450-L455))重開時檔案大小、檔頭、游標前 64 bytes 都相同就不重讀 1 MiB,直接從快取續讀。([ChatConversationEngine.swift#L1677-L1745](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift#L1677-L1745))
- **預讀**:每次連上後,Console 在聊天隱藏時替每個列出的 Agent 讀一次對話紀錄,Agent 狀態改變再讀,讓點進聊天時快取已就緒。([ADR 0024#L1165-L1170](https://github.com/ZingerLittleBee/Heeler/blob/6fa4fea759a6a7575c521c985d9891fe03d12df4/docs/adr/0024-native-chat-from-agent-transcripts.md#L1165-L1170))
- 與舊筆記相比:1 MiB 的 tail window、2 MiB 的每次輪詢上限、快取確認規則都沒變;新增或已有但舊筆記沒寫的是 32 MiB 的往前搜尋與「讀到回合開頭」的規則。

### 推論

- 1 MiB 開啟視窗之所以在 Heeler 可行,是因為 SFTP 讀取不必開 exec、也不必啟動 shell,4 塊 256 KiB 的成本主要是傳輸量。Purrdr 走 exec,每次往返的固定成本較高,所以「一次多讀一點」比 Heeler 更划算。
- Heeler 沒有主機端的「可讀」規則;因為它根本不在主機上跑腳本(SFTP 只能讀 bytes)。

## 二、herdrchat(`1913690`)

### 已驗證事實

- **傳輸**:所有事情都是主機上的 shell 指令;`HerdrTransport` 有 `exec`(一次性)、`streamLines`(長駐)、`duplex`。([C:src/lib/herdr/transport.ts#L1-L34](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/herdr/transport.ts#L1-L34))iOS 端每個 `exec` 在持久的 SSH 連線上開一個 exec 通道(Citadel `executeCommandStream`)。([C:modules/herdr-ssh/ios/SshConnection.swift#L297-L360](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/modules/herdr-ssh/ios/SshConnection.swift#L297-L360))
- **定位**:依 herdr 回報的 session id 在 app 端組出 `<claude dir>/projects/<cwd 轉的資料夾>/<id>.jsonl`;Claude 設定目錄每條連線只問一次並快取。([C:src/lib/transcript/store.ts#L87-L99](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L87-L99)、[#L131-L153](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L131-L153))接著一個 exec 探測(資料夾、檔案存在、可讀、`wc -c` 大小);Claude 檔案不在時再一個 exec 找 worktree 的同名檔。([store.ts#L471-L528](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L471-L528)、[C:src/features/thread/useTranscriptTails.ts#L191-L226](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useTranscriptTails.ts#L191-L226))
- **開啟讀多少**:`RECENT_LINES = 300`,註解寫「以行數不以 bytes:Claude 讀過的圖片是一行最多 1 MB 的 base64,byte 視窗會讓只有截圖的 session 開出十幾列」。([useTranscriptTails.ts#L17-L25](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useTranscriptTails.ts#L17-L25))主機腳本從終點往前取 4 MiB 的塊數換行,不夠就放大 4 倍,最後以 `sed` 把 ≥128 字元的 base64 字串與 data URL 換成 `""` 再傳回;註解實測 30 MB 的對話紀錄 200 行從 6.2 MB 降到 196 KB。([store.ts#L580-L610](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L580-L610)、[#L903-L946](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L903-L946))
- **往返次數**:定位在 app 端(設定目錄已快取時 0 次)、探測 1 個 exec、視窗 1 個 exec(`recent` 帶入探測的大小,不再探測),之後開長駐 `tail -f`。([store.ts#L541-L561](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/lib/transcript/store.ts#L541-L561)、[useTranscriptTails.ts#L236-L260](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useTranscriptTails.ts#L236-L260))
- **誰判斷「夠不夠」:沒有人**。開啟就是 300 行,沒有「沒訊息就往前讀」的邏輯。往前讀只在使用者拖動過列表後、接近頂端時觸發;註解說「短視窗不主動補讀,否則開啟時畫面會移動」。([C:src/features/thread/ThreadMessages.tsx#L87-L106](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/ThreadMessages.tsx#L87-L106))
- **往前讀**:每頁 `OLDER_LINES = 200`;整頁都是已顯示的訊息時最多連讀 `OLDER_EMPTY_PAGES = 6` 頁;失敗 2 秒內不再讀。([C:src/features/thread/useThreadHistory.ts#L10-L28](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useThreadHistory.ts#L10-L28)、[#L130-L160](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useThreadHistory.ts#L130-L160))
- **快取**:SQLite,開啟載入最新 `SEED_MESSAGE_LIMIT = 150` 則,每聊天最多 500 則。([C:src/state/threadCache.ts#L20-L35](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/state/threadCache.ts#L20-L35)、[#L67](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/state/threadCache.ts#L67))列表給的 session 簽章與快取相同就先顯示快取。([C:src/features/thread/useSessionBinding.ts#L78](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useSessionBinding.ts#L78))游標落後 ≤ 64 KiB(`CATCH_UP_BYTES`)且畫面有東西時從游標串流補上,否則重讀 300 行視窗。([useTranscriptTails.ts#L47](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useTranscriptTails.ts#L47)、[#L236-L246](https://github.com/cobanov/herdrchat/blob/1913690e6a918d6f8411914c5c881b457b6ca6bf/src/features/thread/useTranscriptTails.ts#L236-L246))

### 推論

- herdrchat 用「行數 + 主機端剝圖」代替「位元組上限」,300 行在 Claude 的 tool-heavy 尾端通常仍含可讀訊息,所以它不需要「沒訊息就補讀」。但 300 行全是 `api-request-blob`／工具步驟時,它會顯示只有工具串的畫面,沒有補救。

## 三、herdr(`e8d7d97`)

### 已驗證事實

- socket API 的方法清單沒有任何讀對話紀錄的方法;`pane.read`／`agent.read` 讀的是終端機畫面(`visible`／`recent`／`recent-unwrapped`／`detection`)。([R:docs/next/website/src/content/docs/socket-api.mdx#L106-L109](https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/next/website/src/content/docs/socket-api.mdx#L106-L109)、[#L843-L856](https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/next/website/src/content/docs/socket-api.mdx#L843-L856))
- 它只暴露唯讀的 `agent_session`(`source`、`agent`、`kind`、`value`)。([socket-api.mdx#L708-L721](https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/docs/next/website/src/content/docs/socket-api.mdx#L708-L721))
- herdr 自己的 Claude hook 會把 Claude 給的 `transcript_path` 以 `agent_session_path` 回報([R:src/integration/assets/claude/herdr-agent-state.sh#L61-L80](https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/src/integration/assets/claude/herdr-agent-state.sh#L61-L80)),但伺服器只對 `pi`／`omp` 保留路徑,Claude 只留 id。([R:src/agent_resume.rs#L116-L132](https://github.com/herdrdev/herdr/blob/e8d7d9705a7a2c89cef4dd42079379f05685af87/src/agent_resume.rs#L116-L132))
- 原始碼中 `transcript` 只出現在 hook 腳本、偵測規則(Claude 的「showing detailed transcript」畫面)與測試,沒有讀對話紀錄內容的程式。(`grep -rli transcript src` 的結果:`src/detect/*`、`src/integration/*`)

### 推論

- 沒辦法把讀取交給 herdr;定位仍要由 Purrdr 依 session id 推路徑(或搜尋)。若 herdr 日後把 Claude 的 `transcript_path` 也放進 `agent_session`,定位就能省掉 `find` 的備援;目前不行。

## 四、Purrdr 現況(`origin/master` `7f54b7b`)

- 開啟視窗預設 `openingLines = 40`、`openingMaxBytes = 64 << 10`(`src/PurrdrCore/TranscriptReader.swift` L140–141)。`maxBytes` 時只取終點往前那麼多 bytes 內的完整行,不放大區塊(`src/PurrdrCore/TranscriptCommand.swift` L62–99)。
- 流程:`transcripts.locate` → `openWindow` → `readEarlierUntilMessages`(`src/PurrdrAgentFeatures/ConversationModel.swift` L1080–1082、L1212–1240、L1244–1257);補讀每頁從 200 行加倍到 1,600 行,最多 25 頁(L1251、L1260、L1299)。
- 「可讀」判斷在 `hasReadableMessage(in:)`(L1273–1292),依解析後的 `TranscriptMessage.parts`,跨方言共用。
- 先例:列表預覽 `TranscriptCommand.previews` 已經是「定位 + 讀檔尾 48,000 bytes」合在一個腳本裡(L192–234),證明這種合併在 POSIX 與 Windows 方言都已有做法。

## 五、結論與建議

### 三個參考實作的共通點(已驗證)

1. **沒有任何一個在主機端判斷「可讀」**。Heeler 由 app 端的 reducer 判斷(讀到回合開頭),herdrchat 不判斷,herdr 根本不讀。B 方案在參考實作中沒有先例。
2. 開啟時讀的量都比 Purrdr 大得多:Heeler 1 MiB 原始 bytes;herdrchat 300 行(剝圖後通常數百 KB 以內)。Purrdr 的 40 行／64 KiB 是三者中最小的,#656 的實例(最後 64 KiB 只有 23 行、0 則可讀)正是這個上限造成。
3. 都有本機快取先顯示,Heeler 另外在背景預讀。

### 建議:採 A,加上兩個混合細節

**A(定位 + 大檔尾合成一個指令,app 判斷,不夠才補讀)**,理由:

- B 要為 Claude、Codex、Grok、Antigravity、Pi/OMP 各寫一套 grep 近似規則,而且要有 POSIX 與 PowerShell 兩份;與 `hasReadableMessage` 不一致時(例如 Claude 的 `<bash-input>`、委派卡、只有圖片的使用者訊息)會讀太多或太少,而且沒有參考實作這樣做。
- 單看往返數,A 只要把開啟視窗放大,多數情況就是一次:#656 的實例 1.4 MB 檔案,256 KiB–1 MiB 的尾端幾乎一定涵蓋最後一則 Agent 文字(推論,需以 #635 的 `OperationTiming` 與實際檔案量測確認)。

混合細節:

1. **開啟改「行數 + 位元組上限 + 剝圖」**,沿用 herdrchat 的論點(圖片行會讓純 byte 視窗變得很少行),但保留 Purrdr 為慢網路設的上限:建議 `lines = 300`、`maxBytes = 512 KiB`(原始 bytes;剝圖後實際傳輸量通常更小)。若慢網路量測吃緊,至少 256 KiB。
2. **補讀改用 bytes 加倍**,比照 Heeler:第一頁 512 KiB、加倍到每頁 4 MiB、單次開啟的補讀合計上限 32 MiB(或沿用現有 25 頁上限,兩者取先到者)。目前「200 行起、加倍到 1,600 行」在 tool-heavy 尾端仍可能多跑好幾輪往返。
3. 合併指令可以順便「在同一個腳本裡多讀一點」但**只用位元組預算,不用可讀規則**——也就是 A 的大視窗本身,不要做 B。

可抄的數字整理:

| 項目 | Heeler | herdrchat | 建議給 Purrdr |
|---|---|---|---|
| 開啟視窗 | 1 MiB | 300 行(剝圖) | 300 行且 ≤ 512 KiB 原始 bytes,剝圖 |
| 往前讀第一頁 | 512 KiB | 200 行 | 512 KiB |
| 往前讀單頁上限 | 4 MiB(搜尋時) | 200 行 | 4 MiB |
| 單次往前讀總上限 | 32 MiB(Grok/Agy 自動時 4 MiB) | 連續 6 頁全重複 | 32 MiB 或 25 頁 |
| 快取確認 | 大小 + 檔頭 4 KiB + 游標前 64 B | session 簽章 + 游標 | 已有,可加檔頭比對 |
| 落後多少改讀新視窗 | 每次輪詢 2 MiB | 64 KiB | 已有(#130) |

### 其他值得順便處理的往返(推論,未驗證效益)

- **snapshot 與定位並行或合併**:列表已給 `knownSessionID` 時,定位與讀檔尾不必等 snapshot 回來;Heeler 用快取的路徑直接 stat + 讀檔頭(`fastLocateCachedFile`)略過搜尋,herdrchat 也以列表傳來的 session 簽章先開快取。
- **走既有的長駐通道**:Purrdr 的 `SSHTranscriptFollower` 已是一條長駐 exec 通道、以請求行溝通;把「定位 + 讀視窗」做成這條通道的另一種請求,可省掉每次開 exec 與啟動 `sh` 的成本(這正是 Heeler 用 SFTP 的優勢)。需要先量測開 exec 的成本占多少。
- **背景預讀**:比照 Heeler 連上後替列表上的 Agent 預讀進快取,點進聊天時大多是快取命中、只需確認。Purrdr 的列表預覽已讀檔尾 48,000 bytes,可評估能否直接拿來種快取。
