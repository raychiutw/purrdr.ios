# herdrchat 行為規格(clean-room 前半段)

> 本文件描述 herdrchat「做了什麼、使用者看到什麼、規則是什麼、為什麼」,供 Drover Chat 團隊**不看 herdrchat 原始碼**即可從零以 SwiftUI 重寫原生 iOS app。

## 0. 檔頭

### 0.1 Clean-room 原則

- 本文是 clean-room 流程的**前半段**(規格撰寫)。後半段(實作)只能依據本文、herdr 官方文件與在真實主機上的實測,**不得**閱讀或複製 herdrchat 原始碼(含 git 歷史中的 `legacy/` SwiftUI 版)。依據:`docs/adr/0001-clean-room-from-herdrchat.md`。
- 本文**不貼任何 herdrchat 程式碼片段**,也不用它的檔名、型別名、函式名或模組結構描述設計。出處欄的「檔案路徑:行號」只供回查,正文一律是我們自己的敘述。
- herdrchat 的 UI 英文文案**不逐字照抄**,只描述其意義(實作時自行撰寫繁中文案)。
- 下列屬於 herdr 或各 agent 的**公開介面**,可原樣寫出:herdr CLI 指令與旗標、socket method 名稱、JSON 欄位、事件名稱、錯誤碼;Claude Code/Codex/Grok/Antigravity/Pi/OMP 的對話紀錄檔路徑與欄位;SSH/xterm 協定位元組;Unix/PowerShell 標準工具名稱。
- 詞彙以 `/Users/ray/Projects/drover-chat.ios/GLOSSARY.md` 為準:**主機、連線方式、Agent、Agent 狀態、對話紀錄、Pane 終端機、登入 Shell、推播中繼、主機外掛、推播配對**;herdr 自身概念(Workspace／Tab／Pane)沿用英文。

### 0.2 素材與版本

| 素材 | 版本 |
|---|---|
| herdrchat | commit `0ed5f50caaaba5c915401e4a43b182d322b6af44`(2026-11-14),674 個 commit 全部讀過訊息 |
| herdr 原始碼與文件 | commit `ee5bfb5041bb3e4a49d591c72308aae3c81ecdde`(2026-10-29),`Cargo.toml` 0.9.5;文件 `docs/versions/0.9.5/website/src/content/docs/` |
| 本機 herdr | `herdr 0.9.5`,protocol 22,schema_version 1(2026-11-15 以唯讀指令實測) |
| 本機 Claude Code | 2.1.325(只檢查對話紀錄檔路徑與 record 種類,未讀內容) |
| 先前研究 | `/Users/ray/Projects/research/herdrchat-ios-chat-terminal.md`(只當地圖;關鍵事實已回原始碼重驗) |

### 0.3 出處寫法與標記

- 不加前綴的路徑 = herdrchat repo 相對路徑,行號以 `0ed5f50` 為準。
- `herdr:` 前綴 = herdr repo;`herdr:docs/X.mdx` = `herdr:docs/versions/0.9.5/website/src/content/docs/X.mdx`。
- `commit abc1234` = herdrchat commit;`#NN` = herdrchat issue/PR;`herdr#NNNN` = herdr issue/PR。
- 【實測】= 本次在本機 herdr 0.9.5 以唯讀指令驗證過。
- 【未實測】= 只依原始碼、fixture 或官方文件,沒有在真機上跑過(本機只有 Claude Code,其他 agent 一律屬此類)。
- 【推論】= 我的判斷,不是來源的說法。
- 【需換做法】= 因 Drover Chat 的約束(零安裝、無 python3 bridge、swift-nio-ssh、Windows)必須和 herdrchat 不同,詳見 §11。

### 0.4 Drover Chat 的約束(規格必須能支撐)

原生 SwiftUI、iOS 26+、iPhone+iPad、上架 App Store;主機端零安裝,只靠 SSH + herdr 0.9.5 內建指令(含 `herdr remote-api-bridge`),不用 python3 bridge,不相容 0.9.5 以前;主機 OS 涵蓋 macOS、Linux、Windows(OpenSSH,預設 shell 可能是 cmd 或 PowerShell);連線方式為 Tailscale SSH(`none` 認證,可能遇到 check mode)與 OpenSSH;SSH 函式庫 apple/swift-nio-ssh(無 SFTP、無 RSA);支援 herdrchat 支援的全部 agent;全部功能都要做;推播改為主機外掛 → 推播中繼。

### 0.5 目錄

0. 檔頭(本節)
1. 系統總覽
2. 功能清單(F1 主機管理 … F21 Demo 模式)
3. 與 herdr 的協定互動(版本、指令通則、remote-api-bridge、method 表、snapshot、送 prompt 三態、事件對帳、錯誤碼、Windows 方言)
4. 各 agent 的對話紀錄(Claude Code、Codex、Grok、Antigravity、Pi/OMP、subagent/workflow、增量讀取、畫面擷取)
5. Blocked 狀態:偵測、選項、回答
6. 終端機(三種目標、PTY 繞路、接管、尺寸/輸入/手勢/剪貼簿、生命週期、`terminal session control`)
7. 連線生命週期
8. 安全
9. 推播(何時推、內容、推播配對、中繼、主機外掛要點)
10. 踩過的雷(規則 + 理由 + 出處)
11. 因約束必須換做法的地方(含 Unix → Windows 對照)
12. 常數總表
13. 未知與不確定之處、需要人類決策的開放問題

---

## 1. 系統總覽

### 1.1 一句話

手機以 SSH 登入使用者自己的電腦(主機),在主機上執行 herdr 指令操作 workspace/agent,並直接讀取各 agent 寫在主機上的對話紀錄檔,把它們呈現成聊天畫面;另外能把 herdr 的 Pane(或一般登入 Shell)開成終端機。沒有自家後端;唯一的自營伺服器是推播中繼。

### 1.2 資料流

```
iPhone/iPad
 ├─ 每台主機一條長駐 SSH 連線(lazy 建立、所有畫面共用)
 │   ├─ exec:herdr CLI、shell 小指令(探測檔案、讀視窗、上傳圖片…)
 │   ├─ exec + 持續 stdin:herdr socket 請求(經 remote-api-bridge)
 │   ├─ exec 長駐串流:events.subscribe(Agent 狀態等事件)
 │   ├─ exec 長駐串流:追蹤對話紀錄檔尾端(tail -f 的等效)
 │   └─ 終端機通道:Pane 終端機 / 登入 Shell
 └─ APNs ← 推播中繼(自營)← 主機外掛(herdr plugin,Agent 狀態改變時)
```

出處:`src/lib/herdr/transport.ts:3-43`、`src/lib/herdr/socket.ts:6-41`、`CLAUDE.md:175-189`。

### 1.3 herdrchat 的定位與我們的差異摘要

| 面向 | herdrchat | Drover Chat(依約束) |
|---|---|---|
| UI | React Native/Expo,原生 SSH 與終端機模組 | SwiftUI |
| SSH | Citadel(swift-nio-ssh fork),支援 RSA,無 `none` 認證 | apple/swift-nio-ssh,無 RSA、無 SFTP,支援 `none` |
| socket 存取 | python3 bridge 為主,`remote-api-bridge` 次之,都沒有就退回 CLI 輪詢 | 只用 `remote-api-bridge` |
| 主機 shell | 一律 POSIX sh;Windows 要求改用 Git Bash | 必須同時支援 POSIX 與 Windows(cmd/PowerShell) |
| 終端機 | PTY shell + 打字 exec + marker 過濾;`herdr agent/terminal attach` | 可用 exec+PTY 或 `terminal session control`(§6) |
| 推播 | 主機上的 python watcher 常駐服務 | herdr plugin + 自營中繼 |

---
## 2. 功能清單

每個功能以「使用者看得到的功能」為單位,依序寫:行為、狀態、錯誤處理、邊界情況、出處。數字(時間、上限)一併列出;§12 有常數總表。

### F1 主機管理

**F1.1 主機清單(Hosts 表單)**
- 以 sheet 呈現,有「完成」與「新增」。每張卡片顯示:裝置圖示、名稱、`user@host:port`,若設定了具名 herdr session 則附註 session 名稱;目前選取的主機打勾。Demo 主機固定排最後,說明為「範例對話,不連任何機器」。
- 點卡片 = 選取該主機並持久化,關閉所有 sheet 回到聊天列表。
- 卡片動作(Demo 沒有):編輯、圖示、移除。
- 移除:破壞性確認(說明會刪除此裝置上的金鑰與快取對話,主機本身不受影響)。順序:先**不等待地**請該主機刪除本裝置的推播配對檔(否則主機離線時 sheet 卡 20 秒)→ 刪 Keychain 祕密 → 刪資料列與該主機所有設定 → 選取改為第一台剩餘主機或 Demo 並**持久化**(否則重啟後選到已刪的主機,#90)。傳輸層在清理嘗試完成後才關閉。
- 空狀態:提示新增一台跑 herdr 的機器,說明走 SSH、不對外暴露。
- 出處:`src/features/servers/HostsScreen.tsx:64-104`、`src/state/connections.ts:168-215`、commit 5406d48、f9c5f78。

**F1.2 主機編輯器**
- 欄位:名稱(必填)、主機位址(必填,placeholder 示意 Tailscale IP 或名稱)、埠(預設 22,1–65535)、使用者名稱(必填)、認證方式(密碼/私鑰,新主機預設密碼)、密碼(安全欄位)、私鑰(多行等寬;輸入且失焦後折成「OpenSSH 私鑰,N 行」摘要,只能「取代」不能再顯示)、passphrase(新主機 placeholder「無」,編輯時「不變」)、herdr 路徑(預設 `herdr`,空白視為 `herdr`)、herdr session(空白或 `default` = 不設定)。
- 祕密欄位編輯時留空 = 保留原值;換新私鑰時 passphrase 跟著新私鑰(留空 = 無)。
- **儲存前必須通過一次即時連線測試**:依序 ping(`herdr status server`)→ 讀 snapshot → 偵測 socket 能否使用。任何欄位變更都讓測試失效。成功訊息含 herdr 版本;若此主機沒有即時事件管道,附註「改用輪詢,更新會晚幾秒」。
- 測試失敗時依錯誤碼給恢復按鈕(見 §7.6 恢復對照表),例如「herdr 未安裝」→ 確認後安裝(顯示精確指令與主機/使用者)。
- 測試用獨立的暫時連線(不污染正式連線快取),測完即拆。
- 有未儲存變更按取消 → 確認放棄。
- 儲存失敗(例如 Keychain 寫入被拒 -34018)必須留在編輯器並說明原因,不能「按了沒反應」(commit d692c1e)。
- Host key 相關 UI 見 §8.2。
- 出處:`src/features/servers/ServerEditScreen.tsx`、`HostFields.tsx`、`useHostForm.ts`、`KeyField.tsx:81-92`、`src/state/connections.ts:356-394`。

**F1.3 主機選取與多主機**
- 有一台「選取中」的主機:新聊天開在它上面、它決定 App 主題、它的 herdr 版本顯示在設定。
- 聊天列表合併所有已存主機(Demo 除外)的列:選取中主機的列在前,其餘依主機排序。每列帶主機身分;**列的身分 = 主機 id + workspace id**,因為 workspace id 在每台主機都會重複(`w1`)。
- 選了 Demo 時只顯示 Demo;Demo 永遠不混入其他主機的列表(App Review 與 e2e 只看到 Demo)。
- 其他主機的失敗只在列表下方顯示一行提示(主機名:錯誤),其列保持最後一次看到的樣子;其他主機第一次輪詢成功前不顯示其列、也沒有骨架。
- 任何列上的動作(重新命名、關閉、開 shell、靜音)都在**該列所屬主機**上執行。
- 下拉重新整理會刷新**所有**主機。
- 切換選取主機時整個列表重建(載入狀態、事件串流、搜尋字都重置)。
- 出處:`src/features/chats/useHostChats.ts:11-143`、`HostFeeds.tsx`、`HostNotices.tsx`、`listedChat.ts:4-53`。

**F1.4 裝置圖示**
- 每台主機可選一個圖示(桌機、筆電、Mac mini、伺服器、螢幕、開發板、遊戲機、家、雲、終端機,或無)。存於本機設定,只影響此手機。設定後取代該主機聊天列的 agent 頭像,讓多台主機一眼可辨。
- 出處:`src/features/devices/chooseDeviceIcon.ts`、`src/state/deviceIcons.ts`。

### F2 聊天列表

**F2.1 兩種檢視**
- 大標題是目前檢視名(Spaces / Agents),點標題跳出選單切換(目前那個以文字勾號標示,因系統 sheet 不畫勾);切換後列表捲回頂端,選擇持久化;未知或缺值一律回到 Spaces。副標題是選取主機名,點了開主機清單。
- **Spaces 檢視**:每個 herdr workspace 一張卡。
  - **聊天卡**:workspace 只有一個可讀 agent 且沒有其他 pane → 卡片即該 agent 的聊天。例外:agent 還原失敗(無 pane 但有 restore error)仍是聊天卡,顯示還原失敗訊息,點了仍可看對話。
  - **空間卡**:其他情況(兩個以上 agent、agent+shell、只有 shell)→ 卡片代表 workspace 本身(標題 = workspace label,另一主機時前綴「主機 ·」),下面以內縮「軌道」列出每個可讀 agent 的列,再列出每個非聊天 pane 的終端機列;點卡片本體開版面圖(F4),不是聊天。
  - 為什麼有空間卡:舊設計把終端機掛在 agent 卡下,看起來像終端機屬於那個 agent(commit 7132c60)。
- **Agents 檢視**:跨所有主機、所有 workspace,每個可讀 agent 一列平鋪。單一 agent 的 workspace,其列就是 workspace 聊天(與 Spaces 的卡片共用同一個 chat key、已讀標記、釘選);多 agent workspace 的每個 agent 開自己的聊天。沒有可讀 agent 的 workspace 不出現;無法讀取的 agent(opencode、Copilot 等)以終端機列出現在其狀態所屬群組;沒有 shell 列。同一 workspace 中沒有自己標題的 agent 附序號「第 2/2 個」。
- 出處:`src/lib/listModes.ts:22-90`、`src/features/chats/chatGroups.ts:39-71`、`agentRows.ts:40-90`、`src/features/terminal/listRows.ts:40-141`。

**F2.2 分組與排序**
- 群組順序:**已釘選、需要你、執行中、閒置**。群組永遠展開(可收合會讓列表跳動,commit 7f10a03)。「需要你」用注意色。
- 釘選優先於狀態(否則一被問問題就跳走,不叫釘選)。其餘:`blocked` → 需要你;`working` → 執行中;其他(`idle`、`done`、`unknown`)→ 閒置。
- 排序:釘選依釘選時間(舊在前);需要你/執行中依主機順序(workspace `number`);閒置依最後訊息時間新→舊,無時間者最後。
- 多 agent workspace 的狀態取最急迫者:blocked > working > herdr 自報狀態。
- **`input_pending` 覆寫**:agent 非 working 但 `input_pending=true`(例如 Claude 首次啟動的「信任此資料夾?」選單,herdr 回報為 idle)→ 視為 `blocked`,出現在「需要你」(commit 4abefa0)。
- 列表**不**保持「第一個可見列」錨定:新出現在頂端的群組(剛釘選、剛需要你)必須在捲動位置 0 時可見。
- 出處:`chatGroups.ts:5-123`、`src/features/chats/useWorkspaces.ts:546-606`、`ChatsList.tsx:395-400`。

**F2.3 搜尋**
- 有列時才出現搜尋欄(不自動大寫、不自動校正、有清除鈕)。不分大小寫子字串比對。workspace 比對:label、workspace id、主機名;agent 比對:herdr kind **與**顯示名(搜「Antigravity」要找得到 herdr 叫 `agy` 的,commit 1e272c0)、cwd、session 標題、herdr 名稱。
- 空間卡命中時:若命中 workspace 自身文字 → 顯示全部 agent 列;若命中 agent 文字 → 只顯示命中的 agent(都不個別命中則全顯示)。
- 無結果:Agents 檢視且查詢為空且全是 shell-only workspace → 說明「此主機沒有 workspace 在跑 agent,Spaces 列出全部」並給「切到 Spaces」;其他 → 「沒有符合的聊天,試試別的名稱、agent 或資料夾」。
- 出處:`chatGroups.ts:93-114`、`ChatsList.tsx:435-447`。

**F2.4 列內容**
- **標題**(最多兩行)取第一個非空者:① herdr agent 名稱(`herdr agent rename` 設的 `name`);② **人取的** workspace label(= 不等於任何 pane 資料夾最後一段的 label,不分大小寫);③ session 標題(排除預設終端機標題與 resume 指令、看起來像 session id 的字串);④ workspace label;⑤ workspace id。多 agent 的 workspace 列不用 session 標題,用 label。
- 預設終端機標題(不能當聊天標題):Claude 的「Claude Code」/`claude`、`codex`、`grok`、`omp`、`agy`;Codex 標題沒有「 | 」者;resume 指令;含 UUID 片段者(commit 8d224ae)。
- **Session 標題來源**(snapshot 欄位):Claude 用 `title`,舊版退 `terminal_title_stripped`(`terminal_title` 前面有狀態符號,不用);Codex 反過來:`title` 是被截斷的第一個 prompt,真正的名稱是 `terminal_title_stripped` 去掉結尾「 | 資料夾」;Grok 取 `terminal_title_stripped` 中「 - grok」前一段,並去掉前導 spinner 與「Action Required」字樣,只有 `grok` 時無標題。出處:`src/lib/herdr/models.ts:367-398`。
- **副標題**(一行等寬,以「 · 」連接):其他主機時主機名;workspace label(若標題不是它且不是已顯示的資料夾段);序號;agent 顯示名(無 agent 為「終端機」);cwd 最後兩段。多 agent workspace 列:「主機 · N 個 agent · Claude, Codex · 共同資料夾」。
- **預覽行**:blocked 時顯示「等待你的輸入」(注意色);否則有預覽則顯示(使用者自己的訊息前綴「你:」);否則狀態字。workspace 有還原錯誤時以紅字顯示該錯誤(兩行)取代預覽。預覽行高度永遠保留。
- **右欄**:狀態記號;working 時下方顯示「現在」;否則預覽時間:今天 → 依裝置地區的時:分;前一曆日 → 「昨天」;7 天內 → 星期縮寫;更早 → 月/日。
- 邊框:blocked 時注意色;iPad 選取中時 tint 色。
- 無障礙標籤串接:標題、已釘選、已靜音、副標題、狀態、未讀、錯誤或預覽。
- 出處:`src/features/chats/ChatRow.tsx:24-136`、`rowText.ts:15-141`、`src/lib/chatTitle.ts:29-137`。

**F2.5 狀態記號(對應 herdr 側欄的語意)**
- blocked = 驚嘆號圈;working = 轉圈(減少動態效果時改靜態符號);**done = 實心圓 = 已完成且未讀**;idle = 空心圓 = 已讀;unknown = 灰色空心圓。規則:未讀的回覆顯示為 done、已讀的顯示為 idle,不論 herdr 最後回報什麼。
- 顏色(Catppuccin 淺/深):working #DF8E1D/#F9E2AF;blocked #D20F39/#F38BA8;done #179299/#94E2D5;idle #40A02B/#A6E3A1。
- 出處:`src/lib/statusMark.ts:12-16`、`src/theme/tokens.ts:784-787`。

**F2.6 未讀(推導值,永不存旗標)**
- 只持久化「某 chat key 最後開啟時間 + 當時的 session 簽章」。
- 不算未讀:沒有預覽;預覽是使用者自己的;預覽沒有時間戳(永遠清不掉的點比沒有點更糟)。
- 算未讀:從未開啟;標記的簽章 ≠ 目前簽章(slot 被回收);預覽時間 > 開啟時間。
- 多 agent:某 agent 必須**同時**對自己的標記與 workspace 合併對話的標記都未讀才算未讀;比對合併標記時,若此 agent 的簽章是該標記簽章(逗號分隔集合)的成員,就用標記的簽章比,否則用 workspace 目前簽章。理由:讀合併對話等於讀了它的那一份;兄弟 agent 加入或離開不應讓它重亮;回收 pane 裡的新 session 不是成員,仍算未讀(commit 2cba57f)。
- iPad 上目前開在旁邊的聊天永遠不算未讀。
- 已讀標記在進入與離開對話時各寫一次;簽章為 null 時不寫(否則會讓下一個用這個 slot 的聊天被靜音)。
- 出處:`src/lib/unread.ts:1-50`、`src/features/chats/chatUnread.ts:33-94`、`src/features/thread/useReadMarker.ts`。

**F2.7 滑動、長按、無障礙動作**
- 往右滑(leading):釘選/取消釘選、靜音/取消靜音(只在有 session 簽章時提供;靜音需主機存在)。列表是根畫面,沒有返回手勢邊緣,所以 leading 動作安全。
- 往左滑(trailing):「Workspace」(重新命名,圖示為鉛筆;不叫「重新命名」是因為 session 標題的列已不顯示它要改的 label,commit 1829756)、「關閉」(破壞性)。
- 動作面板寬 76pt、開啟門檻 38pt;面板開啟時一次選擇觸覺回饋;執行動作前先關面板。
- **被回收重用的列必須瞬間歸位**,不可動畫關閉(否則關閉聊天後出現空白帶,或別的聊天的列帶著打開的「重新命名/關閉」出現在拇指下,commit 902f1a3)。
- 長按(中等觸覺):以列標題為題的動作表:釘選、靜音通知、(可開終端機且 herdr ≥0.8 時)新終端機分頁、分割終端機、重新命名 workspace…、關閉聊天(破壞性)、取消。動作表規則:安全動作保持順序,破壞性在其下,取消最後。
- VoiceOver/Voice Control 動作與滑動相同。
- 首次提示:列表底部一行「左右滑可釘選、靜音、重新命名或關閉」配飄動箭頭,直到使用者第一次真的滑開面板為止(不是固定次數)。
- 出處:`SwipeableChatRow.tsx:85-178`、`useChatActions.ts:84-170`、`src/lib/actionSheet.ts:60-77`、commit 64b3249(#112)。

**F2.8 注意徽章(App 內)**
- 數字 = 「想要你處理」的 **workspace** 數(不是 agent 數):blocked 或未讀。目前開在旁邊的聊天排除(開的是 workspace 聊天 → 整個 workspace 不算;開的是其中一個 agent → 只算兄弟的 blocked)。
- 顯示位置:Chats 分頁徽章(無上限);Hosts 與設定 sheet 的「完成」旁(<1 不顯示,>99 顯示 99+,VoiceOver 念「N 個聊天需要你」)。
- 只有 >0 才畫徽章(空字串徽章在某些 iOS 仍佔一個點)。
- **不設 App 圖示徽章**;前景通知處理也不設徽章。
- 已知限制:手機上列表不在前景(推入聊天或切到其他分頁)時數字凍結在最後值。
- 出處:`src/features/chats/useAttentionBadge.ts`、`src/lib/attentionBadge.ts`、`app/(tabs)/_layout.tsx:27-48`、`app/_layout.tsx:15-25`。

**F2.9 載入、空、錯誤狀態**
- 沒有主機:提示新增,按鈕直接開新主機編輯器(實務上很少見,因為 Demo 一定存在且會被選取)。
- 第一次輪詢進行中:4 列會「呼吸」的骨架 + 「正在連線到 X…」;**4 秒**後補一句「比平常久,請確認手機能連到電腦:這裡的 Tailscale 已開、電腦醒著且在同一 tailnet」。依主機重新計時。
- 沒有列且選取主機失敗:全螢幕錯誤(標題與按鈕依恢復對照表,內文是錯誤訊息)——**無法連線的主機不是「沒有 workspace」**(commit 8de963a,#96)。
- 沒有列也沒有錯誤:「沒有 workspace,在 herdr 開的 workspace 會出現在這裡」+「開始聊天」。
- 兩種空畫面都能下拉重新整理(下拉時輕觸覺)。
- 有列但選取主機出錯:列上方橫幅 + 恢復動作(執行中顯示「處理中…」);host key 改變有專屬橫幅(§8.2)。
- 重新命名/關閉/靜音失敗:各自可關閉的橫幅(與連線錯誤分開,因為那是已結束的動作)。
- 列表底部依序:integration 橫幅(無錯誤時)、其他主機提示、Claude 用量(無錯誤時,F18)、滑動提示、一次性的 GitHub star 卡(F19)。**後到的橫幅放在列下方**,否則上方突然插入會把列推走,使用者點錯聊天。
- 出處:`ChatsList.tsx:283-447`、`SkeletonRows.tsx`、`src/lib/connecting.ts`。

**F2.10 Integration 提醒**
- 每個連線一次以 socket `integration.list` 詢問;只看本 app 能讀的 agent 的 integration(名稱用安裝時的名字,Antigravity 為 `antigravity-cli`,herdr 列表裡是 `antigravity_cli`):`state:"outdated"` → 過期;`state:"not_installed"` 且 `available:true` → 缺少。主機沒有 socket 或任何失敗 → 不顯示(這是建議,不是錯誤)。
- 橫幅:缺少 → 說明沒有它 agent 永遠不回報 session,聊天會一直等;過期 → 說明 herdr 升級後要更新;按鈕執行 `herdr integration install <name>`(逐一,180 秒),Codex 另裝啟動器(§11 需換做法),完成後再問一次。
- 出處:`src/lib/herdr/client.ts:504-532`、`src/features/chats/IntegrationBanner.tsx`、`useOutdatedIntegrations.ts:41-57`。

### F3 Workspace 管理

**F3.1 新聊天表單**
- Sheet,標題「新聊天」,左上「取消」(不用「完成」,因為讀起來像「開始」)。
- 工作目錄欄(等寬、不自動大寫):值的優先序 = 剛從資料夾瀏覽器挑的 > 手打的 > 此主機上次用的;手打會清掉挑選值。
- 「在主機上選資料夾」按鈕 → 遠端資料夾瀏覽器(F3.2)。
- 「新 worktree」開關:說明為建立 git worktree + 新分支,讓這個聊天不和同 repo 的其他聊天共用檔案。
- 名稱(選填,placeholder 表示預設用資料夾名)。
- Agent 分段控制:Claude Code、Codex、Grok、Antigravity、Pi、OMP。
- 權限模式(僅 Claude),依序:**完全存取**(`bypassPermissions`,預設,「從手機用最合適」)、自動模式(`auto`)、自動接受編輯(`acceptEdits`)、每次都問(`manual`)、只規劃(`plan`)。Codex 選項下附註「Codex 在你送出第一則訊息後才回報 session」。
- 底部固定:錯誤行(注意色)、「開始 <Agent>」(執行中「開始中…」;目錄空白時停用並提示)。
- 每台主機記住:上次目錄、agent、權限模式(只在 Claude 時寫)、worktree 開關;一次讀齊避免閃爍,**只有成功開始後才寫**。
- Demo 拒絕新建 workspace/worktree/tab/split,並說明要用自己的主機。
- 出處:`src/features/newChat/NewChatScreen.tsx`、`useNewChat.ts:64-124`、`src/lib/herdr/permissionMode.ts`。

**F3.2 開始聊天的主機互動(精確)**
1. **先在主機上解析資料夾**:把 `~` 與 `~/…` 展開成 `$HOME`,`cd` 進去並印出絕對路徑;失敗 → 「主機上沒有這個資料夾,請確認路徑或用『在主機上選資料夾』」。理由:herdr 對不存在的資料夾會**默默**改在 `~` 建 workspace,曾因此在家目錄以完全存取啟動 agent。出處:`client.ts:972-987,1456-1458`。
2. **建立 workspace**(60 秒):socket `workspace.create {cwd, label|null, focus:false}`;勾了 worktree 則 `worktree.create {cwd, label, focus:false}`。回應含 `workspace` 與 `root_pane{pane_id, workspace_id}`。`focus:false` 是為了不搶桌機焦點。
3. **在 root pane 啟動 agent**:`herdr agent start <name> --kind <kind> --pane <pane_id> --timeout 60000 [-- <agent 參數>]`。
   - `<name>`:workspace label 的 slug(NFKD 正規化、去組合符號、小寫、非英數合成 `-`、修剪、最長 40 字、空則 `chat`),讓桌機 `herdr agent list` 看到同名。出處:`src/lib/herdr/agentName.ts`。
   - `--kind` 用 herdr 的 kind:`claude`、`codex`、`grok`、`agy`、`pi`、`omp`【實測:`herdr agent start --help` 列出的 kind 含這些】。
   - 權限模式**必須放在 `--` 之後**(`-- --permission-mode <mode>`),只有 Claude 帶;只給 `--kind` 時 herdr 啟動裸 `claude`,權限模式遺失,每個工具呼叫都會停下來問(commit b92854b)。
   - 我方逾時 = herdr 逾時 + 60 秒,絕不能比 herdr 先放棄,否則 fallback 會在同一 pane 再啟動一個 agent。
   - `agent_not_ready` = agent 已起來但停在啟動問題(如資料夾信任)→ 視為成功,問題在聊天裡回答。
   - `agent_pane_busy` = pane 的 shell 還沒到提示字元 → 重試 4 次、間隔 750ms;**只有這個碼可重試**(逾時可能代表其實已啟動)。仍失敗才退回 `herdr pane run <pane> "<指令>"`。
   - herdr 0.9.5 下 `agent.start` 參數:`name`、`kind`、`pane_id`、`args[]`、`timeout_ms`(>3000 且 ≤300000)【實測 schema】。
4. **重試語意**:記住上一次建立的 workspace;同資料夾同 worktree 旗標重試 → 沿用,只重跑啟動;資料夾或旗標改了 → 先盡力關閉孤兒 workspace 再新建(#101)。
5. 成功:關閉所有 sheet,開新 workspace 的聊天(無 pane、無簽章)。
- 錯誤:`not_git_worktree` → 「此資料夾不在 git repo,無法建 worktree,請關掉新 worktree 或選 repo 內資料夾」。
- 出處:`client.ts:957-1170`、`useNewChat.ts`、commit 272b55b、0eee6ed、b92854b、421195d。

**F3.3 遠端資料夾瀏覽器(新聊天用)**
- 起點:傳入路徑(非空白)或主機家目錄(空回應視為 `/`)。
- 列出子資料夾:**排除隱藏資料夾**、跟隨 symlink 資料夾、依地區不分大小寫排序;即使列目錄命令因單一壞 symlink 回非零,只要有印出項目仍視為成功。
- **錯誤與空資料夾是不同狀態**(舊版把每個失敗都顯示成「這裡沒有子資料夾」,commit 4ebc67a):錯誤顯示橫幅 + 重試;空顯示「這裡沒有子資料夾」;載入中轉圈。初次載入也必須接住錯誤(否則永遠轉圈)。
- UI:上一層(在 `/` 或載入中停用)、目前路徑(等寬)、資料夾列、底部「使用這個資料夾」;值經共享狀態交回表單(**不能**用「返回後設路由參數」,那會套到正要離開的路由)。
- 出處:`src/features/newChat/FolderPickerScreen.tsx`、`client.ts:538-578`、`src/state/newChatDraft.ts`。

**F3.4 重新命名 workspace**
- 依內容高度的表單 sheet(固定 40% 高度會被鍵盤蓋住,commit 902f1a3);欄位預填 **workspace label**(不是列標題),自動聚焦全選;說明「這會改主機上的 workspace 名稱,herdr 也會顯示新名字」。
- 修剪後非空且不同於原值才可儲存。socket `workspace.rename {workspace_id, label}`(20 秒)。成功:成功觸覺、標記列表為髒、關閉;列表下次取得焦點**只在髒時**重抓(herdr 可能正規化或拒絕 label)。失敗:錯誤觸覺、錯誤顯示在 sheet。
- 出處:`src/features/chats/RenameChatScreen.tsx`、`src/state/chatEdits.ts`。

**F3.5 關閉 workspace(「關閉聊天」)**
- 破壞性確認:說明 workspace 內每個 tab、pane、程序都會停止;對話紀錄留在磁碟,但 agent 不再執行。列標題 ≠ label 時明說要關的是哪個 workspace。
- socket `workspace.close {workspace_id}`(60 秒)。之後:刪除此 workspace 及其所有 pane 子 key 的本地資料(訊息、游標、已讀、偏好,以**精確前綴**比對,不可用 SQL LIKE 因 `_` 是萬用字元)→ 若 iPad 詳細欄屬於它則清掉 → 重新整理。
- `workspace_group_close_required`:「這個 repo 的 worktree 聊天還開著,先關它們」(herdr 原訊息是叫你加 `--group`,對手機無意義)。schema 中 `workspace.close` 另有 `close_group` 參數【實測 schema】。
- 出處:`useChatActions.ts:84-111`、`src/state/threadCache.ts:248-269`、`src/lib/herdr/protocol.ts:284-288`。

**F3.6 新終端機分頁 / 分割終端機**
- 新分頁:`tab.create {workspace_id, focus:false}` → `root_pane`;分割:`pane.split {target_pane_id, direction:"right", focus:false}` → `pane`。分割目標:長按的 agent 列 > 聚焦的 agent > 第一個 agent > 第一個 shell pane;都沒有則改建分頁。之後開新 pane 的終端機並重新整理列表。都不移動桌機焦點。
- 出處:`useChatActions.ts:118-137`、`client.ts:1014-1033`。

**F3.7 排序**:App 內不能重排;順序依 herdr 的 workspace `number`;`workspace.moved`/`workspace.reordered` 事件觸發刷新。

### F4 Spaces 版面圖

- 資料:snapshot 的 `tabs`(`tab_id`、`label`、`number`)與 `layouts`(每個 tab:pane 矩形(格為單位)、`focused_pane_id`、`zoomed`、`splits`),加上 workspace 的 `active_tab_id`。
- 分頁清單:snapshot 的 tabs ∪ 只出現在 layout 的 tab(以 id 的 `:tN` 尾碼編號),依 number 排序;標題為 label,否則「分頁 N」;作用中分頁外框與標題強調。
- Pane 方塊:以該 tab 所有 pane 矩形的聯集正規化(去掉 herdr 側欄偏移);分頁形狀長寬比 = (欄 × 0.5)/列,限制在 0.9–2.4(字元格約高為寬的兩倍),缺值 1.6;2 個以上 tab 排兩欄。zoomed 的 tab 只畫聚焦 pane 並加放大鏡記號。
- Agent 方塊:標籤 = agent 顯示名,細節 = session 標題或 herdr 名稱;填色 = 該 agent 頭像色,blocked 時注意色。Shell 方塊:程式名(同終端機列規則);中性色。聚焦 pane 有 2pt tint 外環。
- herdr 未回報 layout → 「這台電腦的 herdr 沒有回報版面」。
- 點方塊:agent → 開該 agent 聊天(workspace 只有一個 agent 時開 workspace 聊天);shell → 開其終端機;只出現在 layout 的 pane → 停用。
- 手機:表單 sheet(依內容高,最多 80% 視窗高),顯示**開啟當下**的 snapshot(不即時更新);點方塊先記下目標並關 sheet,由聊天列表下次取得焦點時開一次(**不可在關 sheet 的同一 tick push**,commit 295d67f)。
- iPad:浮動玻璃卡(寬 340、最高 520pt)。游標停在版面按鈕 300ms 顯示、離開按鈕與卡片 200ms 隱藏;點按鈕或在卡上按下即「釘住」,釘住後點背景、Esc 或「關閉」才關;卡片放在列表欄旁(空間夠時)或欄內;量測後視窗尺寸變了就不畫。卡片內捲動視圖要讓第一下點擊穿透(即使鍵盤正被輸入框持有)。懸停需原生 hover 辨識(RN 的 hover 事件在 iOS 不觸發,commit 2d10d39)。
- 無障礙:每個 tab 念「名稱、作用中、N 個 pane」;每個方塊念「Claude、標題、狀態、已聚焦」與提示「開啟聊天/開啟終端機/無法開啟」。
- 出處:`src/lib/spaces/layout.ts:73-115`、`peek.ts`、`popover.ts`、`src/features/spaces/*`、`src/state/spaceLayout.ts`。

### F5 對話畫面(閱讀)

**F5.1 聊天的身分與綁定(核心規則)**
- 聊天有兩種:**workspace 聊天**(合併 workspace 內所有可讀 agent 的對話紀錄)與 **pane 聊天**(多 agent workspace 中單一 agent)。快取 key:前者 = workspace id;後者 = `workspace/pane`(共用會讓兩者互相 rebind 掉對方的快取)。草稿與已讀用同一 key。
- **聊天的身分是 agent 的 session,不是 workspace slot**:herdr 會回收 workspace id 與 pane id。
- **Session 簽章**:對每個有 session 參照的可讀 agent:Claude 用裸 session id;Pi/OMP 用 `agent:kind:URL 編碼的值`;其他用 `agent:id`;去重、排序、以逗號連接。沒有任何參照 → null。出處:`models.ts:149-161`。
- **Session 參照**:`agent_session.value` 非空且 `kind == "id"`;Pi/OMP 另接受 `kind == "path"`。路徑對 Claude/Codex/Grok 一律不接受。
- 每次狀態輪詢的綁定流程(出處 `src/features/thread/useSessionBinding.ts:90-171`):
  1. 有 agent 但都不可讀 → **不支援**狀態(「這個 agent 不支援聊天紀錄,請在主機終端機看」)。
  2. 已綁的 session 消失(簽章變 null)**且**(沒有 agent 剩下,或現在占著 slot 的是不同 pane)→ 停止追蹤、解除綁定、清歷史;若還有可讀 agent → **已被取代**狀態並**暫停送出**(#87:曾經舊對話留在畫面上,送出卻進了新 pane 的新 agent)。同一 session 換 pane(resume)保留對話。
  3. 有可讀 agent 但沒有 session id → **等待中**;**80 秒**後變**缺少**(實測新開 Claude 約 48 秒才回報)。第一次進入等待時以 `integration.list` 問一次:該 agent 的 integration 是 `not_installed` 且 `available` → 立刻**缺少**。任何 agent `blocked` 或 `input_pending`(如信任問題)期間 80 秒計時歸零(id 要等回答後才來)。
  4. 新的非 null 簽章 ≠ 已綁簽章(輪替,或回收 slot 中的新聊天)→ 停止追蹤、刪除簽章不符的快取與游標、重置歷史、綁定、載入。
- 發送在**不支援**與**已被取代**狀態被拒。
- **永不猜對話紀錄檔**:沒有 session id 就沒有東西可開,等待即可(輪詢約每 2 秒重試)。「資料夾裡最新的 .jsonl」會在兩個聊天共用同一資料夾時預覽到別人的 session——這是實際回報的 bug。出處:`CLAUDE.md:58-69`、commit eb5421d。

**F5.2 本地快取**
- 每則訊息存一列:主機、chat key、`session_sig`、訊息 id、序號、內容。**簽章戳 = session 簽章 + 解析器版本**:解析器改版使舊列像別的 session 一樣被丟棄(否則快取中的舊解析結果永遠不更新,例如背景 agent 卡永遠「執行中」)。
- 開啟時載入最新 **150** 則;每個聊天最多保留 **500** 則,超過在同一交易內修剪。
- 序號在交易**內**讀 max+1(在交易外讀會重號,#92);所有快取交易**依資料庫串行**(並行 BEGIN 交錯,第二個的 ROLLBACK 會撤銷第一個,commit 5f599ea)。
- **游標**:每個(主機、聊天、對話紀錄路徑)一個已消化的 byte offset。「重新載入」同時清訊息與游標(否則冷開時舊泡泡復活)。清訊息就要清游標。
- 往上翻的舊頁**永不寫入快取**(序號是 max+1,寫入後下次開啟舊訊息會排在最新之後)。
- 出處:`src/state/threadCache.ts`、`src/lib/transcript/cacheVersion.ts`。

**F5.3 開啟流程**
1. **快取秒開**:若列表傳來的簽章與快取戳完全相同 → 立刻顯示快取、綁定、結束載入;第一次輪詢直接進入追蹤。快取戳是別的 session 的不顯示也不刪,等主機確認 session 後才判斷(commit 7ad7482)。
2. 狀態輪詢 → 綁定 → 開始追蹤對話紀錄(§4)。
3. 讀取決策(§4.4):沒東西在畫面、或多於一個來源有新資料、或任一來源落差 >64KB → 讀最新 **300 行**的視窗並**取代**快取;單一來源且落差 ≤64KB 且畫面有東西 → 從游標串流補上;檔案沒變 → 直接用快取。
4. 檔案不存在(herdr 已回報 id 但 agent 還沒寫檔):有其他兄弟追蹤活著時,以 5 秒起、倍增至 60 秒的退避重試;都沒有活著時每次輪詢重試(#99)。
5. 讀不到(權限等)→ 「無法讀取這個聊天在主機上的對話紀錄:原因」。路徑解析失敗 → 該 agent 的「缺少」說明。
6. 串流失敗:第一次失敗立刻靜默重啟(通常是手機睡著);**連續第二次**才顯示「對話更新暫停,重新連線中」,header 狀態變「重新連線」(commit 6b93fae)。
7. 監看器:agent **working** 時追蹤 **90 秒**無輸出 → 中止讓下次輪詢重啟(半開 TCP 不會拋錯;閒置時沒輸出不代表什麼)。
8. 中止後才到的批次直接丟棄、不推進游標(否則舊 session 的行寫進新 session 快取,commit f50caab)。

**F5.4 往上翻舊歷史**
- 觸發:使用者在此列表版本**至少拖動過一次**之後,每次捲動事件(及拖動開始)距頂端 ≤1 個畫面高就讀上一頁(只在「進入門檻」時觸發的事件不夠:停在門檻內的讀者拿不到東西;使用者還沒捲之前不可自動翻頁,短視窗會從頂端開始)。
- 每頁 **200 行**,錨點是**第一個**開啟的對話紀錄的視窗起點。一次拉最多 **6** 頁完全重複的頁(從快取恢復時最初幾頁就是快取本身)。失敗靜默、**2 秒**內不再問。
- Codex 倒帶/分支的 rollout:翻到 byte 0 時改讀第一行指名的前身檔,從其繼承段落的結尾往回翻(§4.2.2)。
- 頂端固定一列:載入中轉圈 / 「對話開頭」/ 空白(保持底部錨定穩定)。
- 出處:`src/features/thread/useThreadHistory.ts:10-165`、`ThreadMessages.tsx:87-106`、`OlderHistory.tsx`。

**F5.5 狀態輪詢(驅動一切)**
- 間隔:快 = **2000ms × 輪詢倍率**(使用者設定 1/2/5);慢 = **30 秒**(事件串流活著且不需要快速)。需要快速的情況:agent working、blocked、正在監看 slash 面板、背景 agents 窗格最後一次有執行中列。
- 失敗退避:base × 2^失敗次數,上限 60 秒。`auth_failed`、`host_key_changed`、`credentials_missing`、`bad_key` → **暫停**直到使用者重新載入(OpenSSH 會對重複失敗登入的來源位址懲罰)。
- 關於此 workspace 的事件 → 250ms 後「踢」一次輪詢;輪詢進行中又被踢 → 設旗標,完成後立刻再跑一次(用計時器會被進行中輪詢的重排清掉,#88)。
- 只在畫面取得焦點且 App 在前景時執行;回前景立即輪詢。
- 每次輪詢(有 socket 時一次往返):`session.snapshot` + 上次需要的那個 pane 的 `pane.read {source:"visible", lines:40}` + 排隊中的 `pane.report_metadata`。agent 陣列逐欄位相同時保留舊物件(避免每次重繪所有列)。
- 輪詢失敗:錯誤顯示在橫幅,狀態「離線」;若畫面空且未綁定 → 唯讀顯示一次已存歷史(從列表開 → 只在快取戳等於列表簽章時;從連結開 → 任何快取)(#97、commit 589675a)。
- **指令預算**(測試釘住):每分鐘 agent working ≤60 個主機指令;閒置無事件 ≤30;閒置有事件 ≤2。
- 出處:`src/features/thread/useAgentPoll.ts`、`src/lib/poll.ts`、`src/features/thread/__tests__/useThread.budget.test.ts:86-90`。

**F5.6 佔位狀態(還沒有列時)優先序**
1 載入中;2 不支援;3 缺少(「無法識別這個聊天」:agent 沒回報 session,所以無法和同資料夾的其他對話區分;按鈕「在主機上安裝」執行 integration 安裝;註明 integration 在 session 開始時回報、正在跑的 agent 不會被此按鈕重啟;Codex 另說明 `/status` 與 resume 方式);4 已被取代(「這裡開始了新聊天,回報 session 後會出現」);5 等待中(Codex 附註新聊天要先送第一則訊息);6 無法發送(沒有 agent 在跑);7 agent working 或送出中(「agent 正在工作,回覆會出現在這裡」);8 其他(「還沒有訊息」)。
- 有列之後才掛上列表(底部錨定只作用在第一次渲染)。
- 主機已被刪除:「這個聊天的主機不在了」+「前往主機」「回到聊天」,**不顯示輸入框**(否則每次送出都默默失敗)。
- 出處:`src/features/thread/ThreadPlaceholders.tsx:27-201`、`ThreadScreen.tsx:257-334`。

**F5.7 Header**
- 標題:輪詢得到的標題優先於路由帶來的;都沒有時「聊天」,**永不顯示 `w7` 這類 id**(#113)。順序同 F2.4。
- 標題下一行(「 · 」連接,完整保留的片段優先,第一段一定保留,寧可少片段也不截斷):非選取主機時主機名;label(若 ≠ 標題);pane 聊天時 agent 名;模型名;「<effort> effort」;資料夾名(除非與 workspace 或標題重複)。VoiceOver 念完整內容。
- 模型/effort 來源:最後一則 assistant 訊息之後若有 `/model`、`/effort` 的本地指令輸出,以它為準(格式:「Set model to X …」「Kept model as X」「Set effort level to <level>」);否則用對話紀錄的中繼資料。模型顯示:去掉 `[…]` 尾碼與 `provider/` 前綴;`claude-opus-4-1-…` → 「Opus 4.1」;舊式 `claude-3-5-sonnet` → 「Sonnet 3.5」;非 Claude id 原樣。context 只顯示 token 數(**不顯示百分比**,因為對話紀錄沒有記錄 context 視窗大小;0 不顯示)。
- 狀態字與點:離線 / 重新連線 / working(打字點) / 需要你 / 完成 / 線上;離線與暫停時點變暗。合併優先序 blocked > working > done > unknown > idle。
- 按鈕:返回;終端機(可開時);working 時「停止」,否則「重新載入」。
- 重新載入:恢復已停止追蹤的 workflow、停止追蹤、清快取與游標、重置歷史、載入、重置退避、踢輪詢、捲到底。
- 橫幅:附件錯誤,其次是對話錯誤(優先序:動作錯誤 > 輪詢錯誤 > 追蹤錯誤);可關閉。
- 出處:`src/features/thread/ThreadHeader.tsx:169-260`、`src/lib/transcript/sessionMeta.ts:19-91`。

**F5.8 訊息呈現**
- 由對話紀錄轉成列的種類:**使用者**(有可讀文字或圖片才算;只含 tool result 的使用者行不產生列)、**agent 文字**(一則 assistant 訊息可被拆成多列)、**工具串**(連續的工具呼叫與 thinking 折成一列,遇到任何可讀內容結束)、**subagent 卡**(`Agent`/`Task` 工具)、**workflow 卡**(`Workflow` 工具)、**系統註記**(例如 slash 指令的輸出,置中膠囊)、**shell 交換**(`!` 指令)。
- 預設隱藏 sidechain 訊息(設定可開)。
- 工具結果配對:依 `tool_use_id`;沒有 id 的依先進先出配給沒 id 的呼叫。結果的錯誤旗標標示失敗。
- 工具串的列 key 以**最後一個**項目命名(往上翻頁會加在前面,key 會變就跳);折疊狀態 key 以**第一個**項目命名(串變長仍穩定)。
- 換輪次(使用者 ↔ 非使用者)時加大上間距;多 agent 的 workspace 聊天在換輪的 agent 列上方標示 agent 名。
- **工具串摘要**(大寫開頭,「 · 」連接):想了 N 次、跑了 N 個指令、編輯 N 個檔案(依路徑去重)、讀了 N 個檔案、搜尋 N 次、抓取 N 頁、更新待辦、問了 N 個問題、呼叫 N 個工具、N 個失敗。subagent/workflow 呼叫不計入。
- 工具分類(工具名小寫):指令 = bash、bashoutput、exec、exec_command、shell、local_shell、container.exec、write_stdin、run_terminal_command、run_command;編輯 = write、edit、multiedit、notebookedit、apply_patch、search_replace、edit_file;讀取 = read、read_file、view_file;搜尋 = grep、glob、find、ls、websearch、toolsearch、web_search、tool_search、list_dir、search_web;抓取 = webfetch、fetch、web_fetch;待辦 = todowrite、taskcreate、taskupdate、update_plan、todo;提問 = askuserquestion、ask_question;agent = agent、task;其他 = 工具。MCP 工具 `mcp__X__Y` 顯示為「X Y」。
- 工具串預設收合(設定「展開工具執行」可全開);收合時有失敗則顯示紅點;展開後每個呼叫一列(圖示、動詞、一行等寬細節),有結果者可點開看結果(最多 **12 行**,失敗染紅)。
- **使用者泡泡**右對齊 tint 色,最大寬度留約 18%(至少 44pt)空白;群組最後一個泡泡有尾角並顯示時間。**agent 文字不是泡泡**,全寬如文件。
- 長按(原生長按辨識 400ms;**不可用會吃掉觸控的按鈕元件**,否則表格與程式碼無法橫向捲動):動作表「複製訊息」(Markdown 全文)+ 每個非空程式碼區塊一列(只有一個時「只複製程式碼」;多個時「複製程式碼 · 語言:第一行」截 32 字,重複加「(n)」)。複製的程式碼去掉結尾換行、CRLF 轉 LF;**空的區塊不提供複製**(複製空字串會清空剪貼簿)。沒文字的訊息不開動作表。泡泡沒有點擊行為。
- 無障礙:「你的訊息/agent 訊息。內容,N 張圖,時間」+ 自訂動作。
- 出處:`src/lib/threadItems.ts`、`src/features/thread/ToolRun.tsx`、`src/components/Bubble.tsx`、`src/lib/messageCopy.ts`。

**F5.9 Shell `!` 交換(Claude)**
- Claude 把一行 `!cmd` 記成兩個連續 user turn:`<bash-input>cmd</bash-input>`,然後 `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>`。只和**同一份對話紀錄**的**下一行**配對;中間插入了該對話紀錄的其他行 → 視為中斷(「沒有記錄輸出」);合併對話的其他 agent 行不打斷配對。
- 輸出是 Claude HTML 跳脫過的:解除一次 `&lt;`、`&gt;`,最後 `&amp;`;指令本身不跳脫;`<persisted-output>` 內不跳脫、去掉其標籤;`(Bash completed with no output)` 視為空。截在 20,000 字並標註。
- 指令兩端修剪(Claude 不同版本前面有沒有空格不一定,**不可只去掉一個空格**)。
- 區塊:`$` + 指令(等寬粗體)+ 時間;stdout,其次 stderr(注意色)。狀態:最後一行是此指令 → 「執行中」;空 → 「無輸出」;未記錄 → 「沒有記錄輸出」;否則「N 行輸出」。超過 **16 行**折疊,有 stderr 時折疊行數的一半保留給 stderr(否則 build 錯誤被進度輸出蓋掉)。長按:複製輸出 / 複製指令。
- 出處:`src/lib/threadItems.ts:186-220`、`src/features/thread/ShellRun.tsx`、`CLAUDE.md:91-100`、commit 2cee5e8。

**F5.10 Markdown**
- 區塊:段落、標題 1–6、項目清單(`- * +`)、編號清單(`1.`/`1)`,保留起始號)、引用、水平線、圍欄程式碼(3 個以上反引號或波浪號;只有同字元、長度 ≥ 開頭、且該行沒有其他內容的才關閉,#108)、GFM 表格。不認得的當段落。
- 表格:短列補齊、多的格併回最後一格、`\|` 是字面、程式碼內的 `|` 不分格、依 `:--`/`:-:`/`--:` 對齊、逐欄渲染以對齊、寬於螢幕時在自己的容器內橫捲(頁面永不橫捲)。
- 程式碼區塊:頂列語言 + 複製鈕(44pt,不蓋程式碼,空區塊無),複製後勾號 1.5 秒(勾號綁複製的文字,避免回收列誤顯示);**永不換行**、可選取。
- 行內:連結(網址可含一層成對括號)、`code`、粗體、斜體(識別字中的底線是字面);裸 `https://` 與 `<https://…>` 自動連結(結尾標點不算);粗斜體內的 code 與連結保持其種類;不成對分隔符消失。
- **只有 http/https 且有主機的連結可點**;其他 scheme 與相對路徑當純文字。開啟失敗提示。
- 行內程式碼**沒有底色**(iOS 換行時底色會畫成一條)。
- 出處:`src/lib/markdown.ts`、`src/components/Markdown.tsx`、commit 2c38fd9、3e58d0b、2e9f584。

**F5.11 即時預覽(working 時)**
- 條件:agent working 或送出中,且沒有問題在等。
- 列表底部顯示:預覽文字(次要色)+ 工作指示(3×3 點陣動畫、「工作中…」或有預覽時「撰寫中…」、自出現起的經過時間「12s/11m 43s/1h 5m」)。
- 來源:主要 pane 的 visible 畫面 40 行,擷取規則見 §4.7。只有找到真正的散文才顯示(錯的預覽會被當成 agent 的回答)。agent 不在 working 時清除。
- 出處:`src/features/thread/LivePreviewBubble.tsx`、`useAgentPoll.ts:209-229`。

**F5.12 捲動規則**
- 兩種模式:**跟隨尾端**、**閱讀中**。由單一純函式決定:使用者捲動後距尾端 ≤48pt → 跟隨,否則閱讀;內容/視窗/控制列尺寸改變、回到前景/取得焦點 → 跟隨中才捲到底;開啟、送出、點「跳到最新」、重新載入 → 變跟隨並捲到底。
- **只有使用者自己的捲動**(手指按下到拖動或慣性結束)會改變模式;排版造成的捲動事件只量測不改模式(否則排版位移會讓沒動的讀者停在離底一截的地方,commit 30a9817)。
- 列表內建自動捲動關閉(它會把距底 1/5 畫面內的人拉走,與上述規則打架);追蹤重啟時「延續視窗」而不是重建列表(重建會在讀者閱讀中把他丟到底)。
- 跳到最新按鈕:閱讀中且距底 >48pt 且有列才出現;agent working 或送出中時強調「有新訊息」。
- 出處:`src/lib/threadScroll.ts`、`src/features/thread/useThreadScroll.ts`、`JumpToBottom.tsx`、`CLAUDE.md:102-109`。

**F5.13 VoiceOver 公告與在場回報**
- 公告(載入中與首次開啟不公告):變成 blocked → 「<Agent> 需要你:<問題>」;新的 assistant 文字訊息(非 sidechain)→ 「<Agent> 回覆了」。
- **在場回報**:聊天可見時每 **20 秒**排隊一次 `pane.report_metadata {pane_id, source, tokens:{phone:"on", model:<顯示名>}, ttl_ms:45000, seq}`,讓桌機 herdr 側欄能顯示「手機正在看、用什麼模型」。模型未知時省略該 token(空 token 在側欄是空欄)。隨下一次輪詢批次送出,5 秒內沒被帶走就單獨送。`seq = max(上次+1, 現在毫秒)`:herdr 忽略不大於上次的 seq(即使過了 TTL),從 0 起算會在每次重開後隱形(commit ca94901)。純裝飾,失敗不影響任何事。
- herdr 規則:`source` ≤80 字、只能英數與 `:._-`;token 名 `^[A-Za-z0-9_-]{1,32}$`、最多 16 個;值上限 80 字;`ttl_ms` 1–86400000;同一 pane 一生最多接受 32 個帶 seq 的不同 source【herdr:docs/socket-api.mdx:656-690、實測 schema】。
- 出處:`src/lib/announce.ts`、`src/features/thread/useReportPresence.ts`、`client.ts:871-938`。

### F6 送出 prompt

**F6.1 輸入框**
- 浮在列表底部的控制區,由上而下:slash 面板(有開且沒在 blocked)、`/` 指令選單、shell 提示、blocked 列、You-should-know 註記、背景 agents 列、輸入框。
- 輸入框:玻璃材質、聚焦時邊框 tint;左邊「加入圖片」;多行(長到 **4 行**後內捲);**軟體鍵盤的 Return 永遠是換行**;聚焦時有「收起鍵盤」(不送出、保留草稿);送出鈕 44pt(可送時實心箭頭,上傳中轉圈)。送出鈕貼齊最後一行。
- 可送 = 修剪後文字非空或有附件,且輸入框未停用。停用 = 送出中、無主機、無目標 pane、載入中、離線、狀態為不支援或已被取代。
- 鍵盤:控制區逐幀跟隨鍵盤;休息時底部 inset = max(安全區 − 鍵盤高, 16pt);iPad 浮動輔助列的空隙另計;slash 面板打開時收起鍵盤。
- 出處:`src/features/thread/Composer.tsx`、`ThreadControls.tsx`、`useThreadKeyboard.ts`、`src/lib/composerInset.ts`。

**F6.2 草稿**:記憶體中,key = 主機 + chat key;離開聊天保留、重開 App 不保留(#113);每份草稿記住打字時的 session 簽章,兩者都已知且不同時顯示空白(回收 slot),下一次按鍵覆寫;存空字串即刪除。出處:`src/state/drafts.ts`。

**F6.3 硬體鍵盤**
- **Command-Return** 永遠送出(可送時)。Shift-Return、Option-Return 在游標處換行(取代選取範圍)。設定「Return 送出」關 → Return 換行;開(預設)→ 可送時送出,不可送時**什麼都不做**(不送空、不插換行)。CJK 輸入法組字中不攔截 Return。
- 程式改寫草稿(選單挑選、送出、被拒恢復)時,游標保持與結尾的距離(否則 Shift-Return 會插在錯的位置,commit f90546b)。
- Command-V:剪貼簿**只有圖片沒有文字**且圖片未滿 4 張時才當附件;否則系統貼上(只檢查類型,避免觸發「允許貼上」提示)。
- 出處:`src/lib/composerKeys.ts`、commit e4b174e(#155)。

**F6.4 Shell 模式**:目標 agent 是 Claude 且草稿以 `!` 開頭 → 上方提示「這會在 agent 的 shell 執行,不會送給 Claude」;照打的內容送出,對話紀錄會記成 shell 交換(F5.9)。出處:`src/lib/shellMode.ts:12-14`。

**F6.5 送出流程**
- **立即拒絕**(回傳「未送出」,輸入框把草稿放回,#100):修剪後空且無圖;沒有目標 pane;已有送出進行中;載入中;不支援/已被取代;有圖但無連線。
- 輸入框樂觀清空,被拒才恢復;附件只在送出被接受時清。
- 送出前先切到跟隨尾端,讓回音落在視野內;清掉前一個動作警告。
- 圖片:先逐張上傳(F7),任何失敗 → 整則不送、橫幅說明、保留草稿與圖片。
- **樂觀回音**:立即顯示一則本地使用者訊息(唯一 id、文字 + 圖片、時間 = 現在)。
- Prompt 文字 = 打的文字 + 空一行 + 每張圖一行絕對路徑;只有圖片時就是路徑。
- **送出當下重新讀一次新鮮的 snapshot**(不可共用進行中的那份)重新決定目標 pane:可讀 agent 中聚焦者優先,其次第一個;沒有可讀 agent 才用任何 agent。重讀失敗用輪詢得到的 pane。理由:2 秒前的 pane id 可能已過時;只看「聚焦」曾把 Claude 聊天的訊息送進桌機聚焦的 opencode,回音永遠對不上(commit f7d1ab2、fb6655d)。
- **Slash 指令路徑**(Claude/Codex/Grok/Antigravity,且文字符合 `/字母開頭的名稱` 後接空白或結尾):**絕不等待、絕不補 Enter**:`agent.prompt {target, text}`(不帶 wait)。之後開始面板監看(F9.4)。只有 Claude 會在 **10 秒**內確認:回音被確認、或送出後看到面板、或 agent 變 working/blocked;都沒有 → 標記失敗「看不到指令執行,重送前請先看終端機」。理由:`/model` 這類本地指令永遠不會讓 agent「工作」,等待必逾時,舊版補的 Enter 會落在已打開的面板上選到某一列。
- **Prompt 路徑**:`agent.prompt {target:pane, text, wait:{until:["working","blocked"], timeout_ms:8000}}`,我方逾時 8 秒 + 20 秒。三態結果見 §3.6。依結果:
  - **已送達**:等回音確認即可。
  - **Codex 且非已送達**(或無法驗證):最多等 **5 秒**的對話紀錄回執;沒有 → 失敗「已送進 Codex,但對話紀錄尚未確認,重試前先看主機」;**永不重送**(Codex 在共用 app server 下可能沒有輸入框狀態可看)。
  - **停滯**:失敗「agent 沒接住,可能卡在某個提示,再試一次」。
  - **無法驗證且 agent 原本不在 working**:最多等 **3.5 秒**看是否變 working/blocked;沒有 → 新鮮地讀 pane 狀態,**只有主機明確回報 `idle` 或 `done` 才補一個 Enter**,再等 **2.5 秒**;變了 → 視為送達;未知 → 失敗「無法確認送達,訊息可能卡在終端機裡」。理由:補 Enter 進 `blocked` 的權限選單曾批准一個沒人看過的工具呼叫(#76)。agent 原本就在 working → 不等(prompt 只會排隊)。【herdr 0.9.5 下 socket 不會回 `written_to_pty`,此分支實務上只出現在舊版或 fork;保留為防禦。】
  - **傳輸層失敗**(連線中斷):最多等 **8 秒**的回執;沒有 → 「連線在送出時斷了,訊息可能已到,重送前先看聊天」(#83:舊版說「沒接住」導致重試送兩次)。
  - **`agent_blocked` / `agent_input_pending`**:「agent 正在等一個問題,先回答它再送」(什麼都沒送出)。
  - 其他錯誤:失敗 + 錯誤文字。
- 失敗泡泡下有「送出失敗,重試」(44pt)。重試送同樣文字與**已上傳的路徑**(不重傳);每則訊息同時最多一個重試在途(連點曾送兩次,#100)。
- 五種送達警告在任一回執確認任一回音時自動清除;也在關閉橫幅或下一次送出時清除;**輪詢成功不清它**(#82:警告 2 秒後消失,誘發重送)。
- 出處:`src/features/thread/useDelivery.ts`、`client.ts:617-788`。

**F6.6 回音與對話紀錄配對**
- 每則回音記住送出當下已存在的對話紀錄 id 集合;**只有更新的使用者行**能確認它(比對全部歷史曾讓第二個「again」在送出前就消失)。
- 配對 key = 文字(shell 行正規化為 `!` + 修剪後指令)+ **圖片張數**。每個到達只能確認一則回音。
- 比對前**去除圖片路徑**:Claude 把路徑行變成 `[Image #N]` 加 `[Image: source: /path]`;Codex 保留原行。去除後必須剛好等於使用者打的字(連續空行壓成一行、修剪)。只比文字曾讓純圖片訊息被任何空行或 tool result 確認。
- 未確認的回音依時間戳併入時間軸;沒有時間戳的到達沿用上一個已知時間。
- 出處:`src/lib/threadWindow.ts:84-104`、`src/lib/transcript/message.ts:118-130`、`src/lib/transcript/images.ts:16-45`、`CLAUDE.md:83-89`。

**F6.7 停止 / 強制結束**
- 停止鈕只在 working 時出現。目標 = working 的那個 agent,否則主要 pane;**永不是 blocked 的**(中斷可能把問題關掉)。
- 點一下:送 Esc 鍵(herdr 正式拼法 `esc`【herdr:docs/cli-reference.mdx:261-267】;herdrchat 先試 `Escape` 再試 `esc`),之後每 **500ms** 讀狀態、最多 **3 秒**,等它離開 working(讀不到狀態視為成功)。仍在 working → 「agent 還在工作,再點一次,或長按強制結束」。**只送一個 Esc**:第二個 Esc 會打開 Claude 的回溯選單。
- 長按:確認「強制結束 agent?Ctrl-C 可能結束 agent 程序與這個 session;對話留在主機但 agent 停止;單點停止只中斷這一輪」→ 送 `ctrl+c`(舊別名 `C-c`),不確認結果。
- 理由:主機會把不認得的鍵名當文字收下,「鍵被接受」不代表 agent 停了。
- 出處:`client.ts:826-880`、`src/features/thread/StopButton.tsx`、commit e7acb7f。

### F7 傳圖片

- 上限 **4 張**/則(滿了點按鈕提示)。剪貼簿有圖時,按鈕先問「相簿 / 貼上圖片」;否則直接開相簿(僅圖片、多選、剩餘張數、原始品質)。
- 手機端處理:長邊縮到 ≤**2048px**、重新編碼 **JPEG 品質 0.8**、在 App 文件夾留一份本地副本(供泡泡顯示)。
- 檔名:`<時間 base36>-<8 個 base36 亂數>.jpg`;只允許 `[A-Za-z0-9-]+\.(jpg|png)`。
- 縮圖:輸入框上方 64pt 方塊,可移除(上傳中停用);只有圖片也可送。
- **上傳(無 SFTP)**:經 SSH exec,把 base64 分段(herdrchat 每段 96KiB)寫進主機上傳資料夾的暫存檔,最後一個指令解碼成正式檔、刪暫存、刪掉 **7 天前**的舊上傳、印出絕對路徑;權限僅本人(umask 077)。回傳路徑必須是絕對路徑且以 `/<檔名>` 結尾,否則「主機把圖片存到意外的位置」。每個指令 20 秒。內容只以 base64 傳遞,任何登入 shell(fish 會改反斜線)都無法改變寫入結果。【需換做法:Drover Chat 改用 exec 的 stdin 傳 bytes,見 §11】
- 主機上傳位置:herdrchat 用 `~/.cache/herdrchat/uploads/`。【Drover Chat 需自訂自己的目錄名;Windows 需對應路徑,見 §8.4】
- Prompt 中:路徑各占一行(F6.5)。讀回時:Claude 的 `[Image: source: <path>]` 行與「上傳資料夾下的 `.jpg/.jpeg/.png/.heic/.webp` 路徑行」變成圖片段,`[Image #N]` 移除。泡泡依檔名找本地副本;找不到顯示「圖片」標籤(圖在主機上)。
- 泡泡圖片長邊 220pt,依比例;**每個 URI 記住比例**(回收列不會先方後跳,commit 08358da);點開全螢幕,點任一處關閉。
- 清理:主機端每次上傳順手刪 7 天前的;手機端副本只在「清除快取」或「清除所有資料」時刪。
- 出處:`src/features/thread/useAttachments.ts`、`attachments.ts`、`src/lib/attachments/upload.ts:1-90`、`src/components/BubbleImage.tsx`。

### F8 回答 Blocked(「需要你」)

偵測與解析規則見 §5;此處是 UI 與回答流程。
- Blocked 列(玻璃)出現在輸入框上方:
  - 權限細節(有解析到時):工具名(粗體)+ 來源;摘要;內容(指令或 diff,等寬、**橫捲不換行**、超過 8 行折疊、長按複製);附註(注意色);「X 後自動拒絕」——**直接用畫面上的字**,每次輪詢重讀,手機端不倒數。
  - 提示開頭已捲出 40 行讀取範圍時:「這個提示的開頭不在畫面上,請看終端機」,且不顯示標題。
  - 問題:驚嘆號 + 問題文字(沒解析到時「agent 在等」)。
  - 選項:每個一列全寬:編號(無編號的提示隱藏)、多選時勾選框、標籤。**編號 1–9 以外的選項顯示但停用**,並註明「9 以上的選項無法從這裡輸入,請在終端機回答」(#53:輸入「10」會讓 Claude 立刻執行「1」,接著的「0」和 Enter 又送出一個雜訊 turn;隱藏它則和終端機編號對不上)。
  - 多選另有「繼續」;只能關閉的提示(Codex 檔案選擇器)只有「關閉選擇器」;沒解析到選項時通用鈕:確認、1、2、Esc。
- 按下後(防重複):記錄「回答進行中」(同時存在狀態與同步旗標,兩次快速點擊在重繪前就會到)、全部選項停用變暗(玻璃不可改透明度,用顏色)、被點的列轉圈、選擇觸覺;送出後在 **400ms 與 1200ms** 額外踢兩次輪詢(下一題常緊接著出現)。
- 每次輪詢判定:不再 blocked → 已送達(清除);畫面上的提示簽章不同 → 被取代(清除,新問題不繼承鎖);同一提示超過期限 → 逾時,恢復選項並提示「回答可能沒送到,請檢查 agent」;其他 → 等待。期限 = max(**12 秒**, 3 × 輪詢間隔)(commit 934da83)。送出失敗 → 立即清除並顯示錯誤。
- Blocked 期間維持快速輪詢(多題 AskUserQuestion 整個過程都是 `blocked`,沒有事件,commit ab62529)。
- 出處:`src/features/thread/BlockedBar.tsx`、`PromptDetails.tsx`、`useBlockedPrompt.ts:65-187`、`src/lib/transcript/blockedPrompt.ts:137-149,697-760`。

### F9 Slash 指令

**F9.1 哪個 agent 有選單**:目標 agent 為 Claude、Codex、Grok、Antigravity 才有;Pi/OMP 沒有。Codex、Grok、Antigravity 用固定清單(Codex 0.157 的 `/` 選單,對過其執行檔字串);Claude = 主機上執行檔讀出的內建指令(讀不到時用某一版的靜態清單)+ 專案指令 + 使用者指令 + plugin 指令。去重優先序:內建 > 專案 > 使用者 > plugin > 內建技能。分段:內建、技能、指令、Plugins。出處:`src/lib/slashCommands/catalogue.ts`、`builtins.ts`。

**F9.2 在主機上發現指令**(Claude)
- 內建指令:找到 `claude` 執行檔(必須是絕對路徑的檔案,不是 alias/函式),以大小與修改時間當簽章;和手機已知的相同就跳過;否則對執行檔做兩次有上限的字串搜尋(指令字面值、技能名稱表),主機端強制 **12 秒**期限(有 `timeout` 用它,沒有則用 perl alarm 或背景看門狗——因為 App 放棄的通道不會停止背後的命令);失敗或逾時 → 保留舊清單,同一執行檔 **6 小時**內不再試。
- 使用者檔案:`${CLAUDE_CONFIG_DIR:-~/.claude}/commands/**/*.md`(深度 ≤3;`foo/bar.md` 成為 `/foo:bar`)、`skills/*/SKILL.md`。Plugins:讀 `plugins/installed_plugins.json`(前 256KB),取 `installPath`(最多 50 個)與各 plugin 的 `.claude-plugin/plugin.json` 名稱,讀其 `commands/` 與 `skills/`;命名空間取自 manifest 而非資料夾名。專案:`<cwd>/.claude/commands`、`<cwd>/.claude/skills`。
- 上限:每資料夾 200 檔;每檔只讀前 4096 bytes 的 frontmatter(用能處理 YAML block scalar `>-` 的方式讀描述);整個檔案階段一個 **5 秒**期限(在字串搜尋之後);被截斷的資料夾回報為截斷,手機保留該來源舊清單;總輸出上限 2MB;exec 20 秒。
- 排程:列表輪詢中每台主機最多每 **10 分鐘**一次(含最多 8 個開著的 Claude 聊天的專案資料夾),下拉重新整理會立即;聊天第一次開某資料夾時,在第一個視窗載入完 **1.5 秒後**掃一次該資料夾(每連線一次,空結果也算掃過)。永不等待它、每連線同時最多一個。結果持久化(每主機最多 30 個專案資料夾)。
- 歷史教訓:第一版在每次開聊天時掃描、plugin 深度 6,讓不相關的指令排隊逾時,被整個 revert(commit b704ec8)。
- 出處:`src/lib/slashCommands/discover.ts`、`src/lib/herdr/timeouts.ts:71-125`、commit df3e4d3、220714f、5121845。

**F9.3 選單與挑選**
- 選單只在草稿**恰好**是 `/` 加 `[\w:-]*`、後面沒東西時出現(空白結束它)。只有 `/` → 全部、分段;有打名稱 → 單一排名清單(名稱前綴 > 名稱子字串 > 描述子字串,同分依分段與原順序)。列:`/name`、參數提示(等寬次要色)、描述(第二行)。高度 min(260pt, 視窗 30%),點擊不收鍵盤。
- 挑選:參數提示表示**必填**(以 `<` 開頭且不含 optional)→ 填入 `/name `,在游標後以淡字顯示提示;**有副作用或破壞性**的指令(exit、quit、logout、restart、stop、clear、delete、archive、home、commit、pr、commit-push-pr、compact、init、new,或描述含 commit/push/reset/delete/overwrite)→ 只填入、不送出(送出要使用者自己按);其他 → 立即送出(被拒則恢復原文字)。`[model]`、`<optional …>` 屬選填參數 → 直接送。
- 出處:`src/lib/slashCommands/filter.ts`、`pick.ts`。

**F9.4 指令面板(模型選擇、effort 滑桿、資訊面板)**
- 面板打開時 herdr 狀態仍是 `idle`(面板對 herdr 不可見),所以送出 slash 指令後主動監看 **8 秒**:400ms 與 1200ms 各讀一次畫面並踢輪詢;監看或面板開著時,每次輪詢讀主要 pane visible 40 行(只限 Claude/Codex、沒有問題在等、agent 不在 working)。輪詢開始時也看一次(面板可能是桌機開的)。
- 面板列:標題、附註(最多 180pt 可捲)、選項單選列(最多 240pt;標籤、細節、「使用中」打勾、游標列高亮)、可選的層級滑桿(分段控制)、可選的 ←/→ 調整、動作鈕(從面板自己的提示行解析,例如「設為預設」「只用於此 session」「取消」;Esc 最後且中性)。
- 送鍵:點選項 → 從高亮列送 `down`/`up` × 差距(只移動游標,與終端機一致);點滑桿層級 → `right`/`left` × 差距;動作 → 它自己的鍵(`enter`、`s`、`esc`…)。**永不送數字**:在模型選擇器中數字會直接選定**並存成預設**。沒有高亮列或目前層級時停用。
- 送鍵後:忙碌、300ms 後重讀面板並把監看延長 8 秒(面板可能接著出確認畫面);讀不到面板或 agent 開始工作/blocked 時關閉。
- Codex 面板以頁尾「Press enter to confirm or esc to go back」辨識。
- 出處:`src/features/thread/usePaneOverlay.ts`、`CommandPanelBar.tsx`、`src/lib/transcript/paneOverlay.ts`。

### F10 Subagent 與 workflow 卡片、背景 agents 列

- **Subagent 卡**(`Agent`/`Task` 工具):標題 = 呼叫輸入的 `description`(否則「Agent」);說明行 = `subagent_type · 模型` 與「1m 6s · 21.5k tokens · 6 個工具呼叫」;狀態圖示:執行中轉圈 / 完成勾 / 失敗驚嘆(注意色)。點本體展開結果(最多 24 行,可選取;折疊狀態與工具串共用設定);箭頭開 subagent 畫面(沒有 session 資料夾或沒有呼叫 id 時停用)。數字格式:「<1s / 48s / 1m 6s / 1h 2m」、「940 / 21.5k / 1.2M tokens」。
- **狀態判定**(從主對話紀錄):前景 agent 在其 tool_result 到達前都是執行中,之後完成(錯誤則失敗),時長 = 結果時間 − 呼叫時間。背景 agent 與所有 workflow 的結果以「Async agent launched」/「Workflow launched」開頭(含 `agentId: X` 或 `Run ID: wf_…`),要等之後的 task notification(依呼叫 id 或 agent 的 task id 對應,以**最新**一則為準)才結束;之後若有 `SendMessage` 結果含 `"resumedAgentId"`,又變回執行中直到下一次回報。回報內容優先取 hand-back 訊息,否則通知中的 result/summary。狀態 failed/killed/error/cancelled = 失敗。通知與 hand-back **只從 harness 寫的行解析**(使用者貼上的同樣區塊仍是使用者訊息,commit 10b7fe8)。格式見 §4.2.1。
- **Subagent 畫面**(唯讀):依呼叫 id 在 meta 中找到檔案(§4.6;**絕不用最新的檔**,兩個 agent 可在同一毫秒啟動);執行中每 2 秒重試尋找;以同樣的視窗(300 行)+ 追蹤 + 舊頁(200 行)讀;停止時做一次最後補讀。結束偵測:執行中每 **3 秒**在父對話紀錄中搜尋指名此呼叫/agent 的行(內容 checksum 沒變只回一行),用和卡片相同的規則判斷——因為父聊天被蓋住時停止輪詢,卡片學不到結束(commit 1f1548f)。標題、副標(類型 · 模型)、狀態;內容如主對話(含巢狀卡、永遠顯示 sidechain);沒有輸入框。空狀態:執行中且找不到 → 「啟動中」;結束後找不到 → 「不在這台主機」。
- **Workflow 卡/畫面**:執行檔出現前,名稱取自呼叫的腳本 meta 區塊(`meta = { name, description }`,寬鬆比對)或 `scriptPath …/<name>-wf_<run>.js`,否則「Workflow」。執行檔只在**結束時**寫入,所以執行中讀 journal(§4.6)。讀取以 checksum 比對,沒變不下載內容;每個 run 同時一個讀取在途(卡片與畫面共用);讀到寫一半的 JSON → 保留上次成功解析**與舊 checksum**(下次會再讀)。執行中每 **3 秒**輪詢(卡片在執行中或展開時;畫面永遠);App 輪詢暫停時也暫停。結束條件:執行檔狀態不是 running/pending/queued/started/null;或對話紀錄說結束 → 再讀一次停止;或「仍說執行中但 **30 分鐘**沒變化」→ 停止追蹤並標示「不再追蹤 · 重新載入可再檢查」。卡片:狀態、「3 個 agent 中 2 個完成」或「N 個 agent」、時長、tokens、摘要、展開後依 phase 列 agent;結果只在非執行中時顯示。畫面:摘要、各 phase(標題、細節、agent 列含 tokens、工具數、目前在做什麼/結果預覽/錯誤)、記錄框;每個 agent 列可開其對話紀錄。兩種畫面在 iPad 上推疊在分割之上,不取代聊天。
- **背景 agents 列**(Claude 才有):從同一次 visible 畫面讀取解析 Claude 的背景 agents 窗格(§4.8)。working 時每次輪詢讀;閒置時只在上次有窗格、面板監看中、或 working 後第一次閒置時讀(一輪可能在兩次輪詢之間開始背景 agent 並結束,commit e0d34ce);問題開著時沿用上次。有執行中列時維持快速輪詢(herdr 在背景 agent 執行時回報 idle,commit 0a3b0d7)。收合摘要:「N 個 agent 工作中 · 最長經過時間」;**全部完成且沒有藏在折疊下的列**才說「N 個 agent 完成」;「N 完成 · M 失敗」;有隱藏列加「另外 K 個在終端機」。展開列:狀態、種類(Fork/General/自訂類型名)、任務、經過時間 · tokens;經過時間每秒前進(畫面值 + 讀取後經過),完成列停止。任務文字與某 subagent 卡描述完全相同的列可點開其對話紀錄。折疊狀態每聊天每 session、不持久化。
- 出處:`src/lib/threadItems.ts:425-499`、`src/features/thread/SubagentCard.tsx`、`SubagentScreen.tsx`、`WorkflowCard.tsx`、`WorkflowScreen.tsx`、`useWorkflowRun.ts`、`useDelegationEnd.ts`、`useAgentPath.ts`、`src/lib/subagents/*`、`AgentsBar.tsx`。

### F11 多 agent 的 workspace

- Workspace 聊天合併所有可讀 agent 的對話紀錄(各自的視窗依時間戳合併排序;只有一份時保持主機順序),每則訊息標上 agent 名;送出給聚焦的可讀 agent;沒有 session 標題,用 label。
- 每個 agent 也能開成自己的 pane 聊天,有自己的快取 key、草稿、已讀;header 行標示 agent 名。
- 對話紀錄追蹤以 **session** 為 key,**絕不以 cwd**(兩個 agent 在同一資料夾會撞成一個,第二個永遠不串流);同一 workspace 的追蹤一起啟動、一起重啟(一個斷了全部重啟,以免互相覆寫視窗的一半)。
- 出處:`src/features/thread/useTranscriptTails.ts:153-347`、`CLAUDE.md:79-81`。

### F12 Pane 終端機

規格細節見 §6。使用者可見行為:
- 入口:聊天 header 的終端機鈕、列表的終端機列、版面圖的 shell 方塊、新分頁/分割後。
- 畫面:header 在終端機上方(不浮在上面,保住程式第一列):返回(iPad:「關閉」或「回到 <聊天>」)、標題、狀態行(非選取主機時主機名 · 標籤 · 狀態點)。狀態字:連線中… / 已連線 / 未連線 / 連線中斷 / 已掛斷(背景) / 已斷線 / 已結束(或「已結束,exit N」)。
- 橫幅與動作:連線中斷、背景掛斷 → 「重新連線以接續 pane 目前狀態」+ 重新連線;被拒(已有其他 client)→ 「接管」;herdr 找不到 → 說明;無法建構指令 → 說明且**不提供重新連線**(永遠不會成功)。
- 字型大小、捏合縮放、accessory bar、手勢、剪貼簿、連結規則見 §6。
- Demo:回音 shell + 錄製的畫面。

### F13 登入 Shell、Computers 分頁、檔案瀏覽

- **Computers 分頁**:標題「Computers」(副標 = 選取主機,點開主機清單);每台主機一列(名稱、`user@address`、「檔案」與「終端機」兩鈕;Demo 只在選取時出現);頁尾說明檔案走同一條 SSH、每檔上限 25MB、終端機開的是登入 shell。空狀態引導新增主機。
- **登入 Shell**:開主機使用者的預設 shell(登入模式),**沒有 herdr pane**,標題 = 主機名;iPad 上也是推疊(不放進分割詳細欄)。【Windows 需不同做法,§6.6】
- **檔案瀏覽器**:列出資料夾(含隱藏檔;第一行必須是絕對路徑,否則「主機回應的不是資料夾清單」;解析長格式清單取類型、大小、日期、名稱;symlink 名稱截掉「 -> 」之後;資料夾在前再依名稱)。標題 = 資料夾最後一段,副標 = 主機;「+」上傳到這裡、重新載入;「Computers」與「上一層」;空資料夾提示。
  - 下載(上限 **25MB**):確認是檔案且大小在上限內,以 base64 傳回,存到 App 快取後開系統分享表。錯誤:不是檔案、太大、主機傳回的內容損壞。
  - 上傳:文件挑選器、檢查大小,分段寫入暫存檔後解碼;**已有同名檔案則拒絕、永不覆寫**;檔名不可含 `/` 或 NUL、不可為 `.`/`..`。
- 出處:`src/features/devices/ComputersScreen.tsx`、`src/features/files/FolderBrowser.tsx`、`src/lib/files/remoteFiles.ts`、`src/lib/terminal/command.ts:105`。

### F14 推播(App 端)

主機端規則見 §9。
- **權限只在使用者打開「通知」開關時請求**;其他路徑(啟動、關閉、靜音發布)只讀現有權限、永不跳系統對話框(從備份還原的設定可能說「開」但 iOS 從沒問過,舊版會在啟動甚至關閉時跳框,commit e6cd54c)。「暫時授權」視為已授權。
- 取 token 失敗(模擬器、缺 entitlement)→ 「此裝置不支援」並在畫面上顯示原始錯誤(TestFlight 沒有 console)。
- **推播配對的建立**:打開開關 → 對**選取主機**寫入本裝置的配對資料,成功提示「已在 X 註冊」;之後**每次啟動與每次 APNs token 輪替**(開關為開時)→ 對所有非 Demo 主機**並行、盡力**寫入(序列寫時三台離線主機要花約一分鐘)。
- **靜音**某聊天 → 改寫該主機上本裝置配對資料的靜音清單(session 值);因為 iOS 在 App 能攔截前就顯示推播,靜音只能在主機端生效。
- **關閉** → 並行刪除每台主機上本裝置的配對資料,以及**欄位精確等於**目前 token 的舊檔(不是子字串比對;其他裝置的不動)。移除主機 → 該主機上不等待地刪除;清除所有資料 → 並行最多 4 秒。
- 裝置 id:16 個 hex 亂數,首次產生後持久化(舊版每次啟動換 id,造成重複檔與重複推播,commit b424316);只允許 `[A-Za-z0-9-]`(會被拼進路徑)。
- Demo 選取或沒有主機時打開 → 「先選你自己的主機,Demo 無法發送通知」;權限被拒 → 說明並提供「打開 iOS 設定」。
- **點通知的路由**:payload 帶 `workspace`(必要)、`label`、`connection`(此裝置對該主機的連線 id)、`session`。等主機清單載入完才處理(冷啟動才不會綁到空主機,commit 14de072);以通知 request id 去重(冷啟動會收到兩次,commit 7a70dec);選 `connection` 指定的主機(否則選取主機),必要時切換並持久化;有 `session` 時讀一次新鮮 snapshot,若該 workspace 已沒有這個 session 的 agent → 回到聊天列表(slot 可能已換人,#91),問不到主機則照常開;開 workspace 聊天,標題用 `label`。手機:先 dismiss 到根再推入(否則推到 sheet 下面,commit 8c97cce);iPad:設為分割詳細欄。
- **前景推播**:以橫幅、通知中心、聲音呈現,不設徽章。(herdrchat 不在主機端抑制「正在看這個聊天」的推播;git 歷史另有一條「前景時除了開著的那個聊天都顯示」的規則,見 R-N3。)
- 出處:`src/features/notifications/*`、`app/_layout.tsx:15-25`、`src/features/chats/navigation.ts:17-50`。

### F15 設定

- Sheet,「完成」旁顯示注意數。分區:連線、外觀、對話、通知、儲存、支援、關於、危險區。iPad 為左欄分區清單 + 右欄內容;手機堆疊。深層連結可指定分區:畫面捲到該分區並脈動高亮一次(減少動態時改成停留淡出),只消耗一次。
- **連線**:目前主機卡(頭像、名稱、`user@host:port`,點開主機清單);「測試連線」(ping + snapshot,成功顯示 herdr 版本,失敗顯示恢復標題與錯誤 +「檢視主機設定」)。
- **外觀**:系統/淺色/深色,並推到 UIKit 層(動作表、鍵盤、tab bar 跟著變,commit 54257b4);主機主題區(F16)。
- **對話**:展開工具執行(預設關)、Subagent 訊息(預設關)、觸覺(預設開)、Return 送出(預設開,附說明);「檢查更新頻率」:經常/較少/很少 = 輪詢 ×1/×2/×5(說明每次檢查都是一次 SSH 往返);儲存值限制在提供的集合內(0 或 NaN 會讓迴圈空轉)。
- **通知**:開關「agent 需要我時通知」+ 主機外掛狀態列(F14、§9)。
- **儲存**:快取訊息數。
- **支援**:回報問題(GitHub issues)、說明、重看歡迎頁、給星、**複製診斷**:App 版本與 build、OS、主機數、herdr 版本、(可選)一行 agent 偵測摘要;**絕不含主機名、位址、使用者名稱**;偵測摘要取 `herdr agent explain <pane> --json` 的**白名單純量**(狀態、命中規則 id、可見阻擋/閒置/工作旗標),最多等 3 秒——原始 JSON 約 7KB,含帶使用者名稱的路徑與一段終端機畫面(commit 179a353)。
- **關於**:版本、build、主機 herdr 版本(無主機/輪詢前/未回報/版本號,不是最新時加警示)。版本落後時提供「更新 herdr」:確認後執行 `herdr update --handoff`;若伺服器版本沒變但安裝的執行檔較新 → socket `server.live_handoff {import_exe, expected_version}`;輪詢 snapshot 版本直到改變;仍沒變 → 「伺服器仍在跑舊版,無法交接,請在主機上重啟 herdr」。理由:單純 `herdr update` 只換執行檔,執行中的伺服器仍是舊版,而 snapshot 回報的是伺服器版本(commit a5bed77)。【Windows 不支援 live handoff,見 §11】隱私權政策與服務條款在外部瀏覽器開。
- **危險區**(額外間距與上框線):
  - 清除快取訊息:確認後清訊息、預覽、游標、本地圖片副本。
  - 清除所有資料:確認後 ① 並行請每台主機刪推播配對(≤4 秒)② 每台主機:關連線、**先刪 Keychain 祕密**、再刪其他、最後刪資料列(祕密刪失敗則保留該主機列,避免留下無法觸及的孤兒祕密)③ 清快取與圖片副本、清選取與通知設定;部分失敗時說明哪台沒刪掉。Keychain 項目可能在解除安裝後殘留,隱私權頁面提醒先清除再刪 App。
- 出處:`src/features/settings/*`、`src/lib/herdr/version.ts`、`src/features/settings/reset.ts:49-105`。

### F16 主機主題

- 主機上一個 JSON 檔決定 App 配色(herdrchat:`~/.herdrchat/theme.json`)。所有鍵可選:`name`(≤40 字)、`accent`、`light`、`dark`(調色盤鍵物件)、`avatars`(顏色陣列)。調色盤 27 個語意鍵(tint、label、背景、泡泡、分隔線…),顏色格式只接受 `#RGB`、`#RRGGBB`、`#RRGGBBAA`、`rgb()`、`rgba()`。
- 讀取:一次往返——不存在 / 不是一般檔案(FIFO、裝置、目錄、指向 `/dev/zero` 的 symlink)/ 不可讀 各有標記;否則印出前 65,537 bytes 的 checksum 當版本,版本與手機相同就停;超過 64KB 回「太大」;否則傳內容(≤64KB)。用 checksum 而非 mtime(一秒內兩次寫入會漏,commit c2538ef)。輸出異常 = 檢查失敗,保留目前主題。
- 頻率:只對選取主機、只在「使用主機主題」開時,隨列表輪詢:第一次、之後最多每 10 秒、下拉重新整理與回前景;不等待、不報錯。每主機同時一個檢查;主機被移除後回來的答案丟棄。
- 持久化原始檔與版本(不是解析結果),啟動時先解析已存主題,離線也能用主機配色開啟。
- 解析:每個方案每個鍵,明確值 > 從 accent 推導 > App 預設。accent 推導 tint、tint 淡色、tint 上的文字色(白色夠對比用白,否則該方案的 label…)、送出泡泡色(白字對比 ≥4.5 時加深)。合併後檢查文字/背景配對的對比 ≥4.5:1(或預設調色盤本身該配對的較低值),不及格的鍵丟棄(先丟文字再丟背景)並重檢;文字鍵與不透明表面拒絕 alpha;JSON 巢狀上限 64。每個問題產生一行說明(含 JSON 錯誤的行列)。未知鍵與壞顏色略過,其餘照用。
- 設定 UI:主題區**永遠以預設配色繪製**(任何主題都不能讓「關掉主題」變得不可讀);值:關 / 預設 / 預設(檔案無法使用)/ 名稱或「自訂」+ 「N 個顏色,M 個被忽略」;展開顯示檔案路徑、問題行、動作:重新讀取(成功要**用文字**說,因為觸覺可能關著)、「複製給 agent 的提示」(複製一段請 agent 改主題檔的文字,並**此時才**在主機上寫入 schema、README、範例檔,且只在不存在時寫)、「重設為預設」(把檔案改名為第一個空的 `.bak`/`.bak.N`,不覆寫舊備份,commit 2b100eb);開關「使用主機主題」(關 = 用 App 自己的顏色,不動主機上的檔)。
- 出處:`src/lib/theme/*`、`src/state/hostTheme.ts`、`src/features/settings/HostThemeSection.tsx`、`hostThemeSummary.ts`。

### F17 「You should know」註記(Claude 內建 plugin)

- Claude Code 有內建 plugin(預設關)由旁路 agent 每 session 提供一則註記,所有 session 共用一個 JSON store:`${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/store/cc-plugin-you-should-know_<marketplace>-<hash>.json`。key `sessions`(列:id、tag、view{kind、line、explanation/text/url、shownAt…})、`known`(最多 50 句已知)、兩個計數器。**寫回時保留所有未知鍵、列、欄位**。
- 偵測:每連線一次、之後每 10 分鐘找最新的可讀 store;讀:每 10 秒隨列表(以 checksum 判斷變動,上限 512KB);寫:**compare-and-swap**——新 JSON 以 base64 分段寫進暫存、跟隨 symlink(macOS 12.3 前沒有 `readlink -f`,手動迴圈最多 40 層)、解碼成暫存檔、比對 checksum 仍等於讀取時版本才換上;不符 → 重讀、重套、再試一次,第二次放棄(已知有小競態窗)。
- 動作:深入了解(有 explanation 時,換成「已解釋」view)、早就知道/了解(移除 view、句子加入 known(不分大小寫去重,最多 50)、重置計數)、略過、在聊天中討論(以 plugin 自己的草稿格式填入輸入框,再當作「早就知道」)、前往(開該註記所屬聊天)、開學習頁(http/https)。每個動作只在該列仍顯示同一 kind/line/shownAt 時生效。
- UI:聊天列表標題下一列「✦ 提醒 · 句子」或「N 則註記」;註記畫面依時間新→舊;聊天輸入框上方只顯示「該輸入框要送往的 session」的那則。註記畫面與聊天自行重讀(列表輪詢被蓋住時暫停)。只配對 Claude,以完整 session id 比對。
- 【需換做法:會寫主機上的檔案,見 §11】
- 出處:`src/lib/youShouldKnow/*`、`src/features/youShouldKnow/*`。

### F18 Claude 方案用量(5 小時 / 每週)

- Claude Code 只把 `rate_limits.five_hour` 與 `.seven_day`(`used_percentage`、`resets_at`)傳給 status line 命令。herdrchat 在**每台主機取得使用者同意後**,把 `~/.claude/settings.json` 的 `statusLine.command` 換成一支包裝腳本:先把輸入存成用量檔(原子寫入),再把同一份輸入交給使用者原本的 status line(原設定另存在不會被快取清理的位置)。
- 安裝兩次往返:讀設定與原設定 → 只在 `settings.json` checksum 未變時寫;設定不是合法 JSON → 拒絕並說明;跟隨 symlink;包裝腳本永不被存成「原本的」;關閉時還原原設定,或刪除安裝時才建立的設定檔。
- UI(列表底部):同意前「顯示 Claude 用量」+ 確認(說明會改什麼、以哪個使用者);同意後「5h」「Week」兩列:剩餘%(預設)或已用%、進度條、重置時間;擷取超過 10 分鐘註明「截至 X」;已過重置時間的視窗不顯示;點擊可切換%或關閉。約每 5 秒(前景、可見時)讀一次;數值不持久化、同意持久化;移除主機清除同意。Demo 用範例資料。
- 【需換做法:修改使用者主機上的 Claude 設定,與零安裝衝突,見 §11】
- 出處:`src/lib/usage/*`、`src/state/usage.ts`、`src/features/chats/UsageFooter.tsx`。

### F19 歡迎頁與給星

- 歡迎頁:App 載入完、尚未看過、且沒有任何非 Demo 主機時顯示一次(更新 App 且已有主機的人不會看到);設定可重開。四頁:介紹(支援的 agent)、開始前需要(電腦可 SSH、herdr、agent、建議 Tailscale + 設定指南連結)、運作方式三步、準備好(「新增你的電腦」開新主機編輯器;「先逛 Demo」直接關閉,Demo 已被選取)。可略過、下一頁、完成;換頁選擇觸覺。
- 給星:在**真實主機**(非 Demo)上使用的不同本地日數累計到 3 天、且沒問過 → 列表出現一次性卡片;任一回答都記為已問。
- 出處:`src/lib/welcome.ts`、`src/features/welcome/*`。

### F20 iPad、鍵盤、無障礙、觸覺、外觀

- **分割裝置**(iPad,及摺疊 iPhone):聊天或終端機是「選取」,顯示在列表旁的詳細欄,不推入。寬 ≥640pt 兩欄;側欄 280pt(<768)/320pt(≥768);各欄各自的安全區。詳細欄:選取的聊天(主機/workspace/pane 改變時重建)、或終端機、或寬時空狀態「選一個對話」、窄時列表本身。一次只有一個詳細(聊天換終端機會記住被換掉的聊天,返回時恢復);詳細只在其主機仍在列表時顯示;workspace 被關掉時清掉相關詳細。選取高亮依主機 + chat key;空間卡本身不高亮。iPad 上終端機開啟後自動取得焦點(硬體鍵盤免先點),手機不這樣做(避免叫出軟體鍵盤)。
- **鍵盤**:Esc 關閉釘住的版面卡並把焦點還給原持有者;列表拖動時收鍵盤、鍵盤開著也能點列;點列/終端機列/版面鈕先收鍵盤。
- **觸覺**:單一入口並尊重設定:選擇(開關、分頁、挑選)、輕(送出、確認)、中(破壞性意圖)、成功/錯誤(結果);捲動時永不觸覺。
- **動態字級**:所有文字縮放、行高跟著縮放;只有最大兩級標題上限 1.6×,內容永不設上限;空狀態在大字級時可捲;分段控制在 >1.5× 時改成直排單選列;只有頭像 emoji 不縮放。
- **VoiceOver**:F5.13 的公告;滑動動作也是無障礙動作;文字不用三級灰(對比 3.78:1);時間依裝置地區與 12/24 小時制。
- **減少動態 / 減少透明度**即時訂閱;玻璃在減少透明度時退回不透明色。
- **玻璃**:iOS 26 的 Liquid Glass 只在 API 確實存在時使用(某些 iOS 26 build 沒有,渲染會 crash),否則模糊,再否則實色;**永不把玻璃或其祖先設為透明度 0**(會關掉效果),淡出改用玻璃樣式動畫。貼邊的 chrome 用系統模糊材質,Liquid Glass 留給浮動控制項。
- **外觀選擇推到原生層**(視窗介面風格、玻璃、導覽背景、啟動畫面),避免白閃與不一致。
- **Scene 生命週期**:必須採用(iOS 27 SDK 下沒有 scene 的 App 會 crash,commit 8d8191f)。
- 出處:`src/lib/splitView.ts`、`src/components/AdaptiveColumns.tsx`、`src/components/Glass.tsx`、`src/components/haptics.ts`、`src/theme/tokens.ts:590-652`、`CLAUDE.md:114-117`。

### F21 Demo 模式

- **是什麼**:一個保留的「主機」(id `demo`),永遠存在、不持久化、沒有祕密、不能編輯或移除;以**假的傳輸層**實作——對真正 client 會送出的精確指令字串給出回應,所以每個畫面跑的都是正式程式路徑。
- **為什麼**:沒有主機時它就是選取主機——**App Review 的審核裝置唯一能連到的東西**(曾因審核說明描述了該 build 沒有的 demo 被退件,commit 83553cd、51af0a6);也是整個 UI 回歸測試的基礎(不需要真主機)。政策:Demo 演不出來的功能先加 Demo 情境。
- **行為**:回覆以「拉」的方式出現(下次讀取時若已到期就可見,沒有計時器);byte offset 是真的 UTF-8(範例含 emoji);回報 herdr 0.8.0 直到按「更新 herdr」變 0.9.5(可展示版本警告與更新流程);建立/重新命名/關閉/worktree/tab/split 一律以專用錯誤碼拒絕並說明;不能開通知、推播與外掛相關一律跳過。
- **範例 workspace**:一個 blocked 在 Bash 權限提示的 Claude;有已完成 subagent 與執行中 workflow 的 Claude(含一次 `! git status`);已完成的 Claude;以路徑回報的 OMP;有 130 天歷史與圖片的 Claude(測往上翻);兩個 agent + shell pane + 第二個 tab 跑 dev server 的 workspace;agent + shell;未命名的 Grok;不可讀的 opencode(終端機列);Antigravity。
- **預設回覆**:任何其他 prompt → agent 變 working,1.5 秒後回覆引用使用者的話並說明 Demo 什麼都沒執行。回答 blocked 提示選 1 → 繼續並成功;其他 → 暫停;Esc/Ctrl-C → 取消並 idle。
- **情境觸發語**(在任何 Demo 聊天輸入):兩段 AskUserQuestion(顏色、大小,逐題數字作答再到檢閱畫面);一段工具執行(測試失敗→讀檔→編輯→測試通過);Claude 的資料夾信任畫面(agent idle + input pending,回答前任何 prompt 都被 `agent_input_pending` 拒絕);Markdown 表格回覆(各種寬度、含 code 中的 `|`);含兩個程式碼區塊的回覆;寫入主題檔的 Write 工具呼叫(之後主題讀取會拿到它);建立 You-should-know store(僅 Claude);委派 subagent(對話紀錄逐步成長、畫面顯示背景 agents 窗格,僅 Claude);8 秒 thinking spinner 後回覆。`/model`、`/effort` 開面板(上下/左右移動、`s` 只用於此 session、Enter 存預設、Esc 取消);其他 slash 指令印「這是 demo 主機,什麼都沒做」;`! ls` 1 秒後印三個檔,其他 `!` 指令印 stderr。slash 發現結果、用量、終端機(回音 shell + 錄製的 zsh 畫面或 agent 輸入框)皆為假資料。
- 出處:`src/lib/demo/*`、`src/state/demoId.ts`、`CLAUDE.md:143-150`。
- 【推論】Drover Chat 必須有同等的 Demo,否則無法通過 App Review。

---
## 3. 與 herdr 的協定互動

### 3.1 版本要求

- **Drover Chat 只支援 herdr ≥ 0.9.5**(protocol 22)。herdrchat 支援 0.7.0 起並有大量版本分支;我們不需要 legacy 路徑(`pane run` 送 prompt、`--help` 探測、`agent wait --status` 舊旗標等一律不實作)。
- 判斷版本:`session.snapshot` 結果中的 `version`(如 `"0.9.5"`)與 `protocol`(22);`ping` 也回 `version`、`protocol` 與 `capabilities`【實測】。版本以數值比較(字串比較會讓 `0.10.0` < `0.8.0`,commit dce258c);容忍前導 `v` 與 build 尾碼;無法解析視為不支援。
- herdr 0.9.x 各版關鍵事實(說明 0.9.5 為何是底線):0.9.1 加入 `remote-api-bridge`;0.9.2 修正 socket 一次暫時錯誤後拒絕所有連線(herdr#4601)、事件串流落後時改回 `events_lost`(herdr#4225)、加入 `terminal.mouse`;0.9.5 讓 Claude 的問題在具名 session 中也回報 `blocked`(herdr#5192),Codex 改回由畫面偵測狀態且不再安裝 turn hook(herdr#5246)。出處:`herdr:CHANGELOG.md:1-120`、`src/lib/herdr/version.ts:31-38`。
- herdr 安裝後版本與伺服器版本可能不同(更新只換執行檔);UI 顯示的是**伺服器**版本。
- 對過舊主機:顯示「需要 herdr 0.9.5 以上」與更新引導(F15)。

### 3.2 在主機上執行指令的通則

- **每台主機一條 SSH 連線**,所有功能共用(§7.1)。
- **一律以 argv 思維組指令**:任何來自使用者或 herdr 回應的字串都要依目標 shell 的規則完整引號化。POSIX:單引號包住、內部單引號寫成 `'"'"'`(不用反斜線,因為 fish 在單引號內仍把 `\` 當特殊字元,而 sshd 會先把指令交給使用者的登入 shell);Windows:見 §3.9。herdr 路徑以 `~/` 開頭時,只把 `~/` 改成家目錄展開,其餘照樣引號(引號內的 `~` 不展開,導致 exit 127,#106)。
- **PATH 前綴(POSIX)**:非互動 SSH shell 不讀 profile,herdr 的安裝位置(`~/.local/bin`、Homebrew)常不在 PATH;`sh` 登入 shell 甚至可能只繼承到極少的 PATH(連 `ls`、`tail` 都找不到)。每個指令前綴明確 PATH:`$HOME/.local/bin`、`$HOME/bin`、`/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin`、`/bin`、`/usr/sbin`、`/sbin`,再接原 `$PATH`。出處:`src/lib/herdr/shell.ts:39-52`、commit f54a06d、c265894。
- **具名 session**:若主機設定了 herdr session 名稱(非空、非 `default`),每個指令與串流都在環境中設 `HERDR_SESSION=<name>`(綁在傳輸層,而不是每個呼叫點各自記得帶)。socket 路徑解析順序:`--session` > `HERDR_SOCKET_PATH` > `HERDR_SESSION` > 預設【herdr:docs/socket-api.mdx:632-650】。
- **指令長度上限**:sshd 把整個指令當成登入 shell 的**一個參數**,Linux 單一參數上限 128KiB(`MAX_ARG_STRLEN`);herdrchat 以引號化/編碼**之後**的最終指令計算,上限 126KiB,超過以專用錯誤拒絕(先檢查原始請求再編碼會在主機上才失敗,#105)。Windows 命令列上限約 32,767 字元。【我們走 stdin 傳請求時可避開大部分限制,§3.3】
- **完成標記**:Citadel 忽略 SSH `exit-signal`,被訊號殺死的指令回報 exit 0;herdrchat 在每個指令後接「成功才印出的固定標記」,exit 0 但沒有標記 = 傳輸失敗。主機腳本因此不可明確 `exit 0`(要自然結束)。【swift-nio-ssh 會遞送 `exit-signal`,Drover Chat 應直接處理 exit-status 與 exit-signal 兩種通道請求;是否保留標記見 §11】出處:`src/lib/herdr/doneMark.ts`、commit 02d6acd(#103)。
- **一行一個敘述**:以「; 」把多行腳本串成一行時曾產生 `do; [` 這種 bash/sh 語法錯誤(只有 zsh 容忍)。不要用可能不匹配的 glob(zsh 會中止整個指令),改用 `find`。
- **判斷結果靠 exit code,不比對 stderr 文字**(strerror 會依 LC_* 在地化,commit 1fc9dfa)。
- **非零 exit 是結果不是例外**:回傳 stdout、stderr、exit code;由邏輯層解讀。
- **錯誤 envelope 優先於 exit code**:herdr 失敗時在 stderr(或 stdout)印 `{"id":…,"error":{"code","message"}}` 並以非零結束;應先解析 envelope 再看 exit code。stdout 為空的成功(例如 send-keys)不檢查 envelope。

### 3.3 存取 herdr socket:`herdr remote-api-bridge`

- herdr 的 API 是 newline-delimited JSON:Unix 是 Unix domain socket,Windows 是 named pipe;一行一個請求,回應帶同一個 `id`;JSON 無效時錯誤回應 `id` 為空字串;只有 `events.subscribe` 會在第一個回應後保持連線【herdr:docs/socket-api.mdx:608-630】。手機無法直接開主機的本地 socket,所以需要主機上的中介。
- **Drover Chat 只用 herdr 內建的 `herdr remote-api-bridge`**(0.9.1 起):它連到目前 session 的 API socket,把 stdin 轉進 socket、把 socket 轉到 stdout。`herdr remote-api-bridge --check` 印出 `herdr-api-bridge-v1` 表示支援【實測】。出處:`herdr:src/remote.rs:15-38`、`herdr:src/platform/unix_common.rs:213-244`、`herdr:src/platform/windows.rs:344-375`。
- **【實測】行為(herdr 0.9.5 macOS)**:
  - **一個 bridge 程序只處理一個請求**:一次寫兩行請求,只回第一個(socket 是 single-shot)。
  - **stdin 結束(EOF)= client 離開**:對「需要等待」的請求(`agent.wait`、帶 `wait` 的 `agent.prompt`)若 stdin 立即 EOF,會**沒有任何輸出且 exit 0**;stdin 保持開啟則正常回傳(例:`agent.wait` 逾時回 `{"error":{"code":"timeout","message":"timed out waiting for agent status"}}`)。立即回覆的請求(`ping`)即使 stdin EOF 也會回。
  - `events.subscribe` 在 stdin EOF 時只回 `subscription_started` 就結束。
  - Windows 實作同樣在 stdin 上傳結束時停止轉發(`herdr:src/platform/windows.rs:344-375`)。
- **因此規則**:每個請求開一個 SSH exec 通道執行 `herdr remote-api-bridge`,把請求一行寫進 stdin,**不送 EOF**,讀到第一行回應(或對訂閱持續讀)後由我方關閉通道。swift-nio-ssh 可以在 exec 通道上保持 stdin 開啟,所以**不需要** herdrchat 的 FIFO + sleep 繞路(那是因為它的傳輸層無法對 exec 保持 stdin 開啟)。出處:`src/lib/herdr/socket.ts:612-632`(herdrchat 的繞路與其理由)、commit e51514d(#116)。
- **連不到 socket**:bridge 以 Rust 錯誤訊息「failed to connect to remote Herdr API socket …」結束 → 視為 `server_not_running`(herdr 沒在跑)。
- **通道數**:OpenSSH 預設每連線 `MaxSessions` 10;每個請求一個通道時,扇出(例如一次問很多 pane)要**批次**或限流;通道被拒只讓該請求失敗,不要重設整條連線(§7.3)。herdrchat 的作法:把同一批多個請求在一個 exec 內依序執行並以帶序號的分隔行框住每個回答(一個失敗不影響其他)。【我方可沿用「一個 exec 內依序跑多個 bridge」的思路,或維持一個長駐多工 bridge;herdr 的 socket 是 single-shot,所以多工需要主機端程式,零安裝下不可行 → 用批次或限制並行數】
- **Windows 呼叫方式**:herdr 自己對 Windows 遠端機器是以 PowerShell 啟動 bridge(`Start-Process -NoNewWindow -PassThru` 並等待結束、傳回 exit code),外層以 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <UTF-16LE base64>` 包裝,所以不論 OpenSSH 預設 shell 是 cmd 或 PowerShell 都能執行【herdr:src/remote/attach.rs:536-592、2944-2961】。【未實測】herdrchat 記錄 herdr 0.9.3 在 Windows Git Bash 下 bridge 通過 check 但不回應(herdr#5128);0.9.5 下以 PowerShell 方式是否正常需在 Windows 實測。

### 3.4 用到的 socket method 與 CLI 指令

除特別註明,參數/回應形狀皆以 `herdr api schema --json`(protocol 22)【實測】核對。所有 method 都可經 bridge 呼叫;CLI 欄是等價的 `herdr` 指令(同樣輸出 `{id,result}` envelope)。

| 用途 | socket method 與參數 | 回應重點 | CLI 等價 | 逾時(herdrchat) |
|---|---|---|---|---|
| 健康檢查 | `ping {}` | `{type:"pong", version, protocol, capabilities{…}}` | `herdr status server`(文字:`status`、`version`、`socket:` 路徑等) | 15s |
| 全量狀態 | `session.snapshot {}` | `{type, snapshot{…}}` 見 §3.5 | `herdr api snapshot` | 15s |
| workspace 列表(snapshot 缺 `workspaces` 時的後備) | `workspace.list {}` | `{workspaces[]}` | `herdr workspace list` | 15s |
| 讀 pane 畫面 | `pane.read {pane_id, source:"visible", lines:40}`(`source` ∈ visible/recent/recent_unwrapped/detection;`format` text/ansi;`strip_ansi` 預設 true) | `{read:{text,…}}` | `herdr pane read <pane> --source visible --lines 40` | 15s |
| 送 prompt | `agent.prompt {target, text, wait?:{until[], timeout_ms}}` | 成功 `{agent…}`;錯誤碼見 §3.6 | `herdr agent prompt <target> <text> --wait --until … --timeout <ms>` | 8s+20s |
| 等狀態 | `agent.wait {target, until[], timeout_ms}` | 成功或 `timeout` | `herdr agent wait <target> --until …` | ms+20s |
| 送按鍵 | `pane.send_keys {pane_id, keys[]}`;亦有 `agent.send_keys {target, keys}` | 空成功 | `herdr pane send-keys <pane> <key>…` | 20s |
| 送文字(含 Enter 原子提交) | `pane.send_input {pane_id, text?, keys?}`;`pane.send_text {pane_id,text}` | | `herdr pane run <pane> <cmd>` | 20s/60s |
| 啟動 agent | `agent.start {name, kind, pane_id, args[], timeout_ms}` | 成功 / `agent_not_ready` / `agent_pane_busy` | `herdr agent start <name> --kind <k> --pane <id> --timeout <ms> -- <args>` | t+60s |
| 建 workspace | `workspace.create {cwd, label, focus:false, env?}` | `{workspace, root_pane{pane_id, workspace_id}}` | `herdr workspace create --cwd … --no-focus [--label …]` | 60s |
| 建 worktree workspace | `worktree.create {cwd, label, focus:false, branch?, base?, path?, trust_repository?}` | 同上 | `herdr worktree create --cwd … --no-focus` | 60s |
| 新 tab | `tab.create {workspace_id, focus:false}` | `{root_pane}` | `herdr tab create --workspace <id> --no-focus` | 60s |
| 分割 | `pane.split {target_pane_id, direction:"right"\|"down", focus:false}` | `{pane}` | `herdr pane split <pane> --direction right --no-focus` | 60s |
| 重新命名 | `workspace.rename {workspace_id, label}` | | `herdr workspace rename <id> <label>` | 20s |
| 關閉 | `workspace.close {workspace_id, close_group?}` | | `herdr workspace close <id>` | 60s |
| 程序名 | `pane.process_info {pane_id}` | 前景程序資訊 | — | 15s |
| 在場回報 | `pane.report_metadata {pane_id, source, tokens, ttl_ms, seq}` | | `herdr pane report-metadata …` | 20s |
| Integration | `integration.list {}`;`integration.install {target}`(target 列舉含 `claude`、`codex`、`grok`、`pi`、`omp`、`antigravity_cli`…) | `{integrations[{target,label,state,available}]}` | `herdr integration install <name>`(CLI 名稱用 `antigravity-cli`) | 15s/180s |
| 偵測說明 | `agent.explain {target}` | 說明物件 | `herdr agent explain <target> --json` | 3s(診斷) |
| 伺服器交接 | `server.live_handoff {import_exe, expected_version, expected_protocol?}` | | `herdr server live-handoff --import-exe … --expected-version …` | 60s |
| 更新 | — | | `herdr update --handoff` | 180s |
| 啟動伺服器 | — | | `herdr server`(以背景、脫離 SSH 通道的方式;**不是**裸 `herdr`,那會開 TUI 且對具名 session 啟錯) | 60s + 10×1s 確認 |
| 事件 | `events.subscribe {subscriptions[]}` | 首行 `{type:"subscription_started"}`,之後事件行 | — | 開始 10s |
| 終端機 | — | | `herdr agent attach`、`herdr terminal attach`、`herdr terminal session control/observe`(§6) | 開始 20s |
| 安裝 herdr | — | | `curl -fsSL https://herdr.dev/install.sh \| sh`(**必須確認後才執行**,顯示精確指令與主機/使用者) | 180s |

- 鍵名:herdr key-combo 語法——可列印字元、`enter`、`tab`、`esc`(正式;`escape` 也接受)、`backspace`、`left`、`right`、`up`、`down`、`ctrl+c` 等修飾組合、`shift+tab`、`f1`、具名標點(`minus`、`plus`、`backtick`);舊式 `C-c` 是 `ctrl+c` 別名;herdr 會先驗證所有鍵再寫入任何 byte【herdr:docs/cli-reference.mdx:257-267、363】。不認得的鍵名會被拒(`unsupported key`,commit ab76376)。
- `pane run`/`agent.prompt` 會尊重 bracketed-paste 模式;macOS 上 `pane.send_input` 與 `agent.start` 會先檢查終端機的 canonical 輸入上限,超長整行拒絕【herdr:docs/socket-api.mdx:135-141】。
- 出處:`src/lib/herdr/client.ts`、【實測】`herdr api schema --json`、`herdr agent start --help`、`herdr agent prompt --help`、`herdr pane read --help`。

### 3.5 Snapshot 欄位(protocol 22)

【實測】本機 snapshot 頂層:`agents`、`panes`、`workspaces`、`tabs`、`layouts`、`focused_pane_id`、`focused_tab_id`、`focused_workspace_id`、`version`、`protocol`。外層 envelope `{id:"cli:api:snapshot", result:{type, snapshot}}`。

- **agents[]**(實測欄位):`agent`、`agent_session{agent, kind, source, value}`、`agent_status`、`completion_seq`、`cwd`、`focused`、`foreground_cwd`、`pane_id`、`revision`、`state_change_seq`、`tab_id`、`terminal_id`、`terminal_title`、`terminal_title_stripped`、`workspace_id`。視情況出現(herdrchat 讀):`title`(session 自己的標題)、`input_pending`、`name`(`herdr agent rename` 的名稱)。實測 Claude:`agent_session = {agent:"claude", kind:"id", source:"herdr:claude", value:<uuid>}`。
- **panes[]**:同上多數欄位 + `scroll{offset_from_bottom, max_offset_from_bottom, viewport_rows}`;schema 另有 `label`、`display_agent`、`state_labels`、`tokens`、`title`、`restore_error`。`restore_error` = 重啟後無法還原的原因(要顯示,不要讓列看起來空白)。
- **workspaces[]**:`workspace_id`、`label`、`number`、`agent_status`、`focused`、`active_tab_id`、`pane_count`、`tab_count`(schema 另有 `tokens`、`worktree`)。
- **tabs[]**:`tab_id`、`workspace_id`、`number`、`label`、`focused`、`pane_count`、`agent_status`。
- **layouts[]**:`workspace_id`、`tab_id`、`focused_pane_id`、`zoomed`、`area{x,y,width,height}`、`panes[{pane_id, focused, rect}]`、`splits[{id, direction, ratio, rect}]`。
- **ID 形狀**:workspace `w1`;tab `w1:t3`;pane `w1:pA`(後綴不是純數字);terminal `term_` + 十六進位【實測】。pane id 的 `:` 前即 workspace id。
- **`state_change_seq`**:herdr 在此 pane 最後一次狀態改變時的計數;下一次輪詢值不同 = 中間發生過改變(即使又回到同一狀態,例如一輪在兩次輪詢之間開始又結束)。**`completion_seq`**:只有「目前的閒置是完成的工作」才設為該轉換的 seq;啟動、還原、切換 session 都不設(herdr#4457)。實測:`done` 的 agent 有 completion_seq,`blocked`/`working` 為 null。
- **`input_pending`**:herdr 看到 pane 上有選單在等按鍵、但狀態仍是 `idle`(Claude 首次啟動的資料夾信任、slash 指令打開的面板);此時 `agent.prompt` 回 `agent_input_pending`。
- **解碼原則**:未知的狀態值 → `unknown`;未知欄位忽略;**欄位缺席 ≠ 空陣列**(缺 `workspaces` 才需要另外問 `workspace.list`,空陣列就是真的沒有);layout 等幾何資料缺席時容忍。JSON client 應忽略未知欄位、把不支援的 method 當一般錯誤【herdr:docs/socket-api.mdx:942-958】。
- 出處:`src/lib/herdr/models.ts`、【實測】`herdr api snapshot`(只檢查鍵與型別)。

### 3.6 送 prompt 的三態結果

以 `agent.prompt {target, text, wait:{until:["working","blocked"], timeout_ms:8000}}`:
- `until` 用 `working` 與 `blocked`:停下來問權限的 agent 也確實讀到了 prompt;**不可**用 `done`/`idle`(已在那些狀態的 agent 會立刻匹配,等於沒觀察到任何事)。
- herdr 規則:agent 已是 `blocked` → 回 `agent_blocked`,**不送任何輸入**;從非 working 狀態提交時,5000ms 內必須觀察到 working 或 blocked,否則 `agent_prompt_stalled`;呼叫端逾時先到 → `timeout`;它不追蹤個別輪次(agent 本來就在 working 時,那一輪的完成也可能滿足等待)【herdr:docs/cli-reference.mdx:359、`herdr agent prompt --help` 實測】。等待時間必須 ≥ 5000ms,否則可診斷的停滯會變成一般逾時;herdrchat 用 8000ms。
- **我方傳輸逾時必須長於 herdr 的等待**(8s + 20s),否則會放棄一個即將回答的等待並回報主機沒發生的失敗。
- 結果判定:
  - **已送達(delivered)**:成功回應(上游 herdr 只回 `{agent}`;有 `until` 時只在**觀察到**狀態後才回)。【fork 版會加 `delivery:"written_to_pty"` 表示只知道 bytes 寫進去 → 視為無法驗證;上游不會出現】
  - **停滯(stalled)**:herdr **自己的** `timeout` 錯誤或 `agent_prompt_stalled` → 文字還在輸入框裡。
  - **無法驗證(unverified)**:只在 fork 或極舊路徑出現。
  - **傳輸層逾時/中斷 ≠ 停滯**:錯誤必須帶「是傳輸層失敗」的旗標;傳輸層失敗代表**不知道有沒有送到**,不可重試,只能等對話紀錄回執(F6.5,#83)。
  - `agent_blocked`、`agent_input_pending` → 什麼都沒送,轉成「先回答問題」。
  - `invalid_request` 且訊息含 `unknown variant` → method 不存在、什麼都沒送(0.9.5 不會發生)。
- **socket 失敗不可改走 CLI 重試**:兩者到同一個伺服器,一邊拒絕另一邊也會拒絕;重試寫入是 prompt 重複送出的來源(`client.ts:1286-1297`)。
- Slash 指令不走三態(F6.5):`agent.prompt {target, text}` 不帶 wait。
- 出處:`src/lib/herdr/client.ts:617-788`、commit af647a6(#76)、1680a20(#83)、f7829d3。

### 3.7 `events.subscribe` 與 snapshot 對帳

- **訂閱清單**:
  - pane 範圍:每個 agent pane 一筆 `{type:"pane.agent_status_changed", pane_id}`(schema 規定 `pane_id` 必填,沒有萬用字元【實測 schema】;可另加 `agent_status` 過濾)。
  - 全主機(不帶 pane_id,每種一筆):`workspace.created`、`workspace.closed`、`workspace.renamed`、`workspace.updated`、`pane.agent_detected`、`pane.exited`。
  - Spaces 檢視另加版面事件:`tab.created`、`tab.closed`、`tab.renamed`、`tab.moved`、`pane.created`、`pane.closed`、`layout.updated`、`workspace.moved`、`workspace.reordered`。
  - **只能列 herdr 認得的事件型別**:任何一個未知型別(或不存在的 pane)會讓 herdr 拒絕整個請求並關閉連線(herdrchat #75:fork 才有的 `pane.turn_completed` 讓 App Store 版永遠連不上即時事件)【herdr:docs/socket-api.mdx:773-790】。
  - 完整可訂閱型別(protocol 22):workspace.created/updated/metadata_updated/renamed/moved/reordered/closed/focused、worktree.created/opened/removed、tab.created/closed/focused/renamed/moved、pane.created/closed/updated/focused/moved/exited/agent_detected/output_matched/agent_status_changed/scroll_changed、layout.updated【實測】。
- **串流格式**:第一行是 ack `{"id":…, "result":{"type":"subscription_started"}}`【實測】;之後每行一個事件 `{event:<名稱>, data:{…}}`(wire 上事件名用底線,例如 `pane_agent_status_changed`);`pane_agent_status_changed` 的 data 欄位:`agent`、`agent_status`、`display_agent`、`pane_id`、`state_labels`、`title`、`workspace_id`【實測 schema】。有些事件 id 在頂層,有些包在 `pane`/`workspace` 物件內(`workspace.created`/`updated`);workspace id 也可由 pane id 的 `:` 前段推得。
- **事件不重播**:訂閱開始前與斷線期間發生的事都看不到。因此:**串流一開始(收到 ack)就做一次全量重讀**;收到 `events_lost` 錯誤(讀太慢被伺服器踢掉)→ 視快取為過期、重新訂閱、重讀。
- **herdr 官方對帳程序**:開新訂閱、等 `subscription_started`、**一邊繼續讀事件一邊在另一個連線請求 `session.snapshot`**;以 snapshot **取代**快取;事件只當「失效訊號」觸發再讀一次;刷新要**串行**,讀取進行中又來事件就再讀一次。snapshot 與事件**沒有共同序號**,只保證單一訂閱條目內有序,所以**不可把緩衝的事件 payload 套在 snapshot 上**【herdr:docs/socket-api.mdx:791-817】。herdrchat 的做法與此一致:事件只「踢」輪詢(250ms 去抖),輪詢進行中被踢就完成後再跑一次。
- **pane 集合改變** → 必須關掉舊訂閱開新的(訂閱不可修改);集合不變(順序不同)不重開。
- **重連退避**:1 秒起倍增、上限 30 秒;第一行到達即視為「活著」並歸零失敗數。**在被接受前就結束的串流算失敗**(否則退避不會啟動,每秒重連一次、每次一個通道一個主機程序,#104)。
- **活著時的輪詢**:列表降到 30 秒一次的安全網輪詢;對話依需要維持 2 秒(working/blocked 等)。
- 事件的作用:任何事件 → 去抖 250ms 後刷新;非版面事件 → 強制讀該 pane 的預覽(未指名 pane 的 → 全部);版面事件**不讀**對話紀錄(桌機拖動調整大小每一步都送一個)。對話畫面只對「自己 workspace 的、或未指名 workspace 的」事件反應。
- 只有前景且畫面可見時才開訂閱(背景時 iOS 第一個殺的就是長駐 SSH 通道)。
- 出處:`src/lib/herdr/events.ts`、`src/features/useHostEvents.ts`、`src/lib/herdr/socket.ts:233-289`、commit 50d72f0、2012a87(#94)、e2dac36(#104)、f971a4b(#75)、2ecff2f。

### 3.8 錯誤碼與使用者意義

**herdr 回報且需特別處理的碼**:`agent_blocked`、`agent_not_ready`、`agent_input_pending`、`agent_not_found`(那個 pane 已沒有 agent)、`agent_pane_busy`、`agent_prompt_stalled`、`invalid_request`、`not_git_worktree`、`pane_not_found`(pane 不見了,可能在主機上被關掉)、`server_not_running`、`unknown_method`、`workspace_group_close_required`、`timeout`、`events_lost`、`not_found`、`workspace_not_found`。
- `server_not_running`:herdr 原文叫你「執行 `herdr`」——在手機上無用、對具名 session 還會啟錯;改說「這台主機的這個 session 沒有在跑 herdr,可從這裡啟動或在主機上啟動」並提供「在主機上啟動 herdr」。
- **未知碼保留 herdr 原文**(通常是對未預期失敗最精確的描述),不要壓成泛用道歉。
- **絕不把原始 JSON 給使用者看**。

**我方自訂的狀況碼**(語意,不必沿用名稱):request 太大、herdr 不是 herdr(路徑指到 Herdr Desktop 的 `herdr-core`:`status server` 回用法錯誤 → 「herdr 路徑跑的是別的程式」,恢復動作是改路徑而**不是**安裝,commit bc20877)、herdr 未安裝 / 不在 PATH / 不可執行(exit 127 時多一次往返診斷:先 `command -v`,再找 `~/.local/bin`、`~/bin`、`/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin`,分別回報「找不到,請安裝」「安裝在 X,請把 X 設為 herdr 路徑」「在 X 但不可執行,請 chmod」;使用者已明確填了路徑時不要叫他去改 PATH)、Windows shell 不相容(herdrchat 以 stderr 含「is not recognized as an internal or external command / the name of a cmdlet」辨識)、資料夾不存在、資料夾不可讀、對話紀錄缺席/不可讀/格式不符、session 參照無效/有歧義/被壓縮、伺服器啟動失敗、中斷未確認、訂閱提早結束。
- 出處:`src/lib/herdr/protocol.ts`、`client.ts:1318-1413`。

### 3.9 Windows 主機的指令方言【需換做法】【未實測】

herdrchat 不支援原生 Windows shell(要求使用者把 OpenSSH `DefaultShell` 設成 Git Bash 並 `DefaultShellCommandOption -c`;偵測到 cmd/PowerShell 的「is not recognized」就報錯)。Drover Chat 必須能在預設 cmd 或 PowerShell 下運作:
- **偵測主機 OS**:herdr 自己的遠端機器功能先試 Windows 探測——以 `powershell.exe -NoLogo -NoProfile -NonInteractive -Command` 執行一段在 cmd、PowerShell、POSIX shell 下展開結果不同的字串(`$env:OS|%OS%`),確認是原生 Windows 後再以編碼腳本印出 `herdr-windows:<arch>`;否則以 `/bin/sh` 跑 `uname -s`/`uname -m`。互動式設定時先探 Windows,避免 PowerShell 預設 shell 印出原始 `CommandNotFoundException`【herdr:src/remote/attach.rs:1724-1825】。Windows ARM64 為 best-effort(x64 模擬)。
- **執行指令**:一律包成 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <UTF-16LE 的 base64>`,腳本開頭設 `$ProgressPreference='SilentlyContinue'`(否則 PowerShell 會把「Preparing modules for first use」等進度序列化成 CLIXML 寫到 stderr)【herdr:src/remote/attach.rs:574-592】。這在 cmd 與 PowerShell 預設 shell 下都可用,也避開 OpenSSH for Windows 會以雙引號包裝指令而展開 `$`、反引號的問題【herdr:src/remote/attach.rs:559-571 的註解】。
- **啟動 herdr 子程序**:herdr 用 `Start-Process -FilePath herdr.exe -ArgumentList … -NoNewWindow -PassThru` 再等待並 `exit $process.ExitCode`(保留 handle 才能在 Windows PowerShell 5.1 拿到 exit code)。
- **編碼與換行**:輸出可能是 `\r\n` 與非 UTF-8 code page → 去 `\r`、強制 UTF-8(`[Console]::OutputEncoding`)。
- 對照表見 §11.2。

### 3.10 其他主機端 herdr 互動

- **啟動伺服器**:以脫離 SSH 通道的背景方式執行 `herdr server`(POSIX:nohup + 重導 + `&`;herdr 0.9.4 起 Linux/macOS 關掉啟動它的 shell 不再停止伺服器),之後每秒讀一次 snapshot、最多 10 次確認;herdr 拒絕第二個實例(「already running」)= 成功。失敗:「已啟動但沒起來,請在主機檢查 `herdr status server`」。【Windows 未實測】
- **更新 herdr**:F15。
- **安裝 integration**:`herdr integration install <name>`;0.9.5 輸出純文字(不是 envelope),非零 exit 才算失敗;只有輸出以 `{` 開頭才當 envelope 檢查。安裝成功後**不顯示成功訊息**(只在下次 session 開始時生效,畫面要等那時才會變)。
- **在 workspace 中呈現的 integration 版本需求**(原生 session 還原所需):Pi v2、OMP v3、Claude Code v6、Codex v5、Grok v2、Antigravity v1 等【herdr:docs/integrations.mdx:64】;Claude integration v10 只匹配 `startup/resume/clear/compact/fork` 五種 SessionStart 來源【herdr:docs/integrations.mdx:114】。

---

## 4. 各 agent 的對話紀錄

> 對話紀錄格式是各 agent 的**內部檔案**,不是公開 API,隨版本變動的風險由我們承擔。除 Claude Code 外皆【未實測】。

### 4.0 共同規則

- **Session id 來自 herdr**:snapshot 中 agent 的 `agent_session`(由該 agent 的 herdr integration 回報)。kind `id` → `value` 是原生 session id;kind `path` → `value` 是絕對檔案路徑(Pi/OMP 通常如此)。
- **永不猜檔**:沒有 session 參照 → 不開任何檔(也不預覽);沒有「最新檔案」這種 API。
- **ID 必須是安全字元**:session id 須符合 `^[A-Za-z0-9-]+$`;subagent/workflow id 須符合 `^[A-Za-z0-9_-]{1,128}$`;不符合就拒絕,**不是**把它引號化了事(防止注入與路徑穿越)。回報的路徑(agy/Pi/OMP)必須絕對、以 `.jsonl` 結尾、無 `..` 段、無 NUL/CR/LF。
- **家目錄與設定目錄**每連線問一次並快取(快取 promise;失敗不快取);**絕不以 `~` 代替**(被引號化後不會展開)。
- **Agent 表**(每個 agent 只描述一次):

| herdr kind | 顯示名 | 讀取器 | integration(`herdr integration install`) | 預設標題(不當聊天名) | 選單只按數字即回答 |
|---|---|---|---|---|---|
| `claude` | Claude | Claude JSONL | `claude` | `Claude Code`、`claude` | 是 |
| `codex` | Codex | Codex rollout | `codex` | `codex` | **否**(數字 + Enter) |
| `grok` | Grok | ACP log | `grok` | `grok` | 是 |
| `agy` | Antigravity | agy steps | **`antigravity-cli`**(herdr 列表中 target 為 `antigravity_cli`) | `agy` | 是 |
| `pi` | Pi | Pi/OMP journal | `pi` | — | 否 |
| `omp` | OMP | Pi/OMP journal | `omp` | `omp` | 否 |

  其他 herdr 0.9.5 偵測得到但**不可讀**的 agent(只顯示為終端機列):amp、cline、copilot、cursor、devin、droid、gemini、hermes、kilo、kimi、kiro、letta、maki、mastracode、muse、opencode、qodercli、qwen。出處:`src/lib/herdr/agents.ts:44-141`、`docs/adding-an-agent.md`。
- **共同訊息模型**:id、角色(user/assistant/system)、時間戳(毫秒或無)、agent 標籤(workspace 多 agent 時)、是否 sidechain、依序的片段:文字、thinking、工具呼叫(名稱、扁平化的輸入預覽、id)、工具結果(文字、對應呼叫 id、是否錯誤)、背景任務通知、hand-back、圖片(路徑;空路徑 = 有圖但來源不明)、shell 輸入、shell 輸出(stdout/stderr)。
- **上限**:工具輸入預覽 2,000 字;Claude 工具結果 4,000 字;shell 輸出 20,000 字。
- **每行解析一次**,同時產生「訊息」與「header 中繼資料(模型、effort、context token)」。無法解析的 JSON 行略過(通常是被截斷的尾行)。
- **格式分派**(依行的形狀):`type` 為 `response_item`/`event_msg`/`turn_context` → Codex;`type` 為 `message`/`model_change`/`thinking_level_change`/`branch_summary`/`compaction`/`reset_boundary` → Pi/OMP;`method` 為 `session/update` 或 `_x.ai/session/update` 且有 `params.update` → Grok;有數字 `step_index` 且 `type`、`source` 為字串 → agy;其他 → Claude。
- 出處:`src/lib/transcript/parser.ts:51-105,538-564`、`message.ts:10-88`。

### 4.1 Claude Code【本機已驗證路徑與 record 種類】

**位置**
- 設定目錄:`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`(只看得到非互動 SSH 環境中的變數)。
- 路徑:`<設定目錄>/projects/<cwd 轉成的資料夾名>/<session id>.jsonl`,cwd 用 herdr 回報的 pane `cwd`。
- **資料夾名規則**(Claude Code 2.1.280 的做法):把每個**不是** `[A-Za-z0-9]` 的 **UTF-16 code unit** 換成 `-`(emoji 是兩個 unit → `--`);結果超過 200 字時取前 200 字,加 `-` 與「原 cwd 的 32 位元 Java `hashCode` 取絕對值的 base36」。例:`/Users/x/Documents/obsidian/07_homelab` → `-Users-x-Documents-obsidian-07-homelab`。【實測:本機 `/Users/ray/Projects` → `-Users-ray-Projects`;含 `.` 的路徑出現 `--`】
- **Worktree 後備**:預期位置不存在時,在**所有**專案資料夾中找**完全相同檔名** `<id>.jsonl`(只會命中回報的那個 id,不是猜)。只有 Claude 用這個後備(#89)。
- Session 子資料夾(與 `.jsonl` 同名、去副檔名)裝 subagent 與 workflow(§4.6)【實測:`<session>/subagents/agent-<id>.jsonl` 與 `.meta.json` 存在】。

**格式**:JSONL,一行一個物件。entry 層用 camelCase、content block 用 snake_case。常見頂層欄位:`type`、`uuid`、`parentUuid`、`isSidechain`、`timestamp`(ISO)、`cwd`、`sessionId`、`version`、`message{role, content, model, usage, id, stop_reason}`、`isMeta`、`promptSource`、`origin{kind…}`、`promptId`、`isCompactSummary`、`isApiErrorMessage`、`effort`、`toolUseResult`、`attachment{…}`。【實測:Claude Code 2.1.325 還有 `api-request`、`api-request-blob`、`api-request-shape`、`atis-latch`、`cost-state`、`ai-title`、`last-prompt`、`mode`、`permission-mode`、`file-history-snapshot`、`system`、`attachment` 等 type → 只有 user/assistant(與下述 attachment)產生泡泡,其餘忽略】

範例(取自 fixture 意義):
```json
{"type":"user","uuid":"u1","timestamp":"2026-07-16T16:22:32.273Z","isSidechain":false,"message":{"role":"user","content":"run the tests"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"OK"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"swift test"}}]}}
{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"3 passed, 0 failed"}]}}
```

**解析**
- 只有 `type: user` 與 `type: assistant` 成為泡泡(加上下面的 queued attachment)。
- id:`uuid`;沒有時以**去除圖片後的**行文字算穩定雜湊(每次讀都要得到同一個 id,去重才有效)。**每個 content block 一個泡泡片段,不依 `message.id` 合併**。
- assistant content:字串 = 文字;陣列:`text` → 文字、`thinking`(欄位 `thinking`;空的隱藏)→ thinking、`tool_use{id,name,input}` → 工具呼叫;其他 block 忽略。
- user content:`text` 經清理;`image` 計數;`tool_result{tool_use_id, content(字串或含 .text 的 block), is_error}` → 工具結果。
- **Harness 行**(使用者沒打的):`isMeta`、`isCompactSummary`、`promptSource:"system"`、`origin.kind` 不是 `human`。永不成為使用者泡泡;只可能產生:背景任務通知訊息(文字含 `<task-notification>` 區塊)或 hand-back 訊息(`origin` 為 `{kind:"peer", handback:true, from, body}`,或文字含 `<agent-message from="<id>">…[Subagent hand-back]…</agent-message>`)。
- **使用者打的行**:不是 harness 且有 `promptId` 或 `origin.kind == "human"`。
- 使用者文字清理:解開 `<pasted_content id="N">…</pasted_content id="N">`(長貼上才對得上回音,#79);有 `<command-name>/x</command-name>` → 顯示「指令 + `<command-args>`」(例 `/review 42`);有 `<bash-input>` → `! <cmd>`;否則剝掉**開頭**的 harness 元素(標籤名含 `_` 或 `-`,或 `heartbeat`、`image`),但**使用者打的行**不剝 `task-notification` 與 `agent-message`(那是人貼上的);人打的 `<div>` 保留;只有 harness 的 turn 不顯示。
- **本地指令輸出**:整段文字恰好是一個 `<local-command-stdout>` 或 `<local-command-stderr>` → 系統註記(去 ANSI、去反引號、修剪、600 字截斷;空的不顯示);同時供 header 判斷模型與 effort(F5.7)。
- **Shell `!`**:F5.9。
- **排隊中的 prompt**:Claude 忙碌時送進來的 prompt **只**以 attachment 記錄,不會有 `user` 行:`type:"attachment"` 且 `attachment.type == "queued_command"`:`commandMode == "prompt"` → 使用者訊息(內容 `attachment.prompt`,`attachment.origin` 是 human 則為人打的);origin 是 harness → hand-back;`commandMode == "task-notification"` → 任務通知;時間戳退用 `attachment.timestamp`(#77:否則忙碌時送出的訊息永遠無法確認)。
- **錯誤**:API 錯誤、限流、「登入過期」是 `message.model == "<synthetic>"` 且/或 `isApiErrorMessage:true` 的 assistant 行 → 照常顯示,但**永不設定 header 模型或 context**(#80)。
- Compaction:`isCompactSummary` 的 user 行隱藏;`system` 行不產生內容。
- **Header 中繼資料**(只看 assistant 行):模型 = `message.model`;context = `usage.input_tokens + cache_creation_input_tokens + cache_read_input_tokens`(只加存在的數字;都沒有 → **null 而不是 0**,否則合併時會覆蓋真值);effort = 頂層 `effort`(符合 `^[a-z]{1,16}$`)。≤0 的 context 不顯示。
- 出處:`src/lib/transcript/parser.ts:107-489`、`harness.ts:27-182`、`sessionMeta.ts`、commit 72f13e6、7c63540、9c8fa4d。

### 4.2 Codex【未實測】

**位置**
- 在 `${CODEX_HOME:-$HOME/.codex}/sessions` 與 `…/archived_sessions` 下遞迴找檔名 `rollout-*-<id>.jsonl`、`rollout-*-<id>_*.jsonl`(以及 `.jsonl.zst` 版本),依日期分層,例如 `sessions/2026/09/14/rollout-2026-09-14T12-00-00-<id>.jsonl`。回傳路徑必須絕對、符合 `-<id>(_[A-Za-z0-9-]+)?\.jsonl(\.zst)?$`。
- 只找到 `.zst` → 「已壓縮,目前讀不了」(不是「不存在」;Codex 可壓縮 7 天未動的 rollout)。
- 恰好一個 `.jsonl` → 用它。**多個**(Codex 0.157 起倒帶會寫 `rollout-<ts>-<id>_<rolloutId>.jsonl` 並保留舊檔,或 sessions/archive 重複)→ 問 Codex 自己的狀態資料庫:對每個 `${CODEX_HOME}/state_*.sqlite` 以唯讀查 `select rollout_path from threads where id = '<id>'`,第一個等於候選之一的勝出;沒有 sqlite3 或 schema 不同 → 「有歧義」,**不開任何檔、不依新舊猜**。
- **驗證**:檔案第一行必須是 `{"type":"session_meta","payload":{"id":"<id>",…}}`;不符 → 不符錯誤(下次重試,header 可能只寫了一半)。
- 找到的路徑依連線與 id 快取;失敗不快取;之後探測為缺席就忘掉。

**格式**:JSONL,每行 `{timestamp, type, payload}`;type:`session_meta`、`response_item`、`event_msg`、`turn_context`、`compacted`。

**解析**
- **只有 `response_item` 成為泡泡**;`event_msg` 是同一輪的重複,永不渲染(只取 `token_count` 當中繼資料)。
- id:`codex:<timestamp 字串>:<行雜湊>`(跨視窗穩定,也區分稍後重複的相同 prompt)。
- payload 種類:
  - `message`:`role` 須為 user 或 assistant(`developer` 等略過);`channel:"analysis"` 略過(0.157 前);`phase`(commentary/partial_answer/final_answer)每種都顯示。content block:`input_text`、`output_text`、`text`、`summary_text` → 文字;`input_image` → 圖片。使用者文字清理:去掉 `# AGENTS.md instructions…`、整個 `<permissions instructions>…</permissions instructions>`、單一 `<send_user_message_question_reply>` 顯示其內容、剝開頭 harness 元素(`<environment_context>`、`<heartbeat>`、`<recommended_plugins>`、`<in-app-browser-context>`…)、移除 `<image …>` 參照。assistant 文字移除 `<oai-mem-citation>…</oai-mem-citation>`(含結尾未閉合的)。
  - `agent_message`(0.155,agent 對 agent)→ sidechain assistant 訊息「作者 → 收件者:文字」。
  - `function_call`/`custom_tool_call` → 工具呼叫(name、`arguments` 或 `input`、id = `call_id`);`local_shell_call` → `local_shell`({command: argv 以空白連接});`web_search_call` → `web_search`({query} 取自 action);`tool_search_call`/`tool_search_output`(「找到 N 個工具」,`status:"failed"` 為錯誤);`image_generation_call` → `image_generation`({prompt: revised_prompt})。
  - `function_call_output`/`custom_tool_call_output` → 工具結果(對應 `call_id`);**沒有錯誤旗標**,從文字判斷:修剪後以 `Script failed`、`failed to spawn`、`aborted by user` 開頭,或**第一個** `"exit_code": N`/`Process exited with code N`/`Exit code: N` 的 N ≠ 0。
  - `reasoning` → 只取 `summary[].text` 當 thinking;加密內容永不還原。
- **Header**:模型與 effort 取 `turn_context.payload.model`、`.effort`;context 取 `event_msg` 的 `token_count.info.last_token_usage.input_tokens`(**cached tokens 已包含在內,不可再加**)。開頭視窗沒有模型時,在主機上掃整個檔找最後一個 `turn_context` 行。
- **倒帶/分支的前史**:第一行 `payload.history_base = {thread_id, end_byte_offset, end_ordinal_exclusive}` 指出前身檔(以同樣方式搜尋 `rollout-*-<rolloutId>.jsonl` 或 `rollout-*_<rolloutId>.jsonl`,須恰好一個且不是目前檔);往上翻到 byte 0 時,從前身檔的 `end_byte_offset` 往回繼續。【這段依 Codex 0.163 原始碼寫成,herdrchat 也沒在真實倒帶 session 上跑過】
- **Session 回報**:需要 `herdr integration install codex` 且 Codex 信任 herdr 的 hook(`/hooks`),再退出並 resume;新聊天在第一則訊息後才回報 id。herdrchat 另裝了一個啟動器,把 pane 身分(`HERDR_ENV`、`HERDR_PANE_ID`、`HERDR_SOCKET_PATH`)以 `-c shell_environment_policy.set.*` 帶進 Codex 共用 app server(否則共用伺服器會失去 pane 身分)。【需換做法,§11】
- 出處:`src/lib/transcript/codex.ts`、`store.ts:192-372`、`harness.ts:200-278`、`docs/getting-started.md:28-56`、commit 187a16c、56b31e1、ac78f62。

### 4.3 Grok【未實測】

- **位置**:`${GROK_HOME:-~/.grok}/sessions/<編碼後的 cwd>/<id>/updates.jsonl`。cwd 編碼由 Grok 決定、可能改,所以以「深度剛好 2、名稱等於 id 的資料夾」尋找;0 個 = 缺席,>1 = 有歧義;資料夾須絕對、以 `/<id>` 結尾、無 NUL/CR/LF。
- **格式**:ACP `session/update` 通知的 JSONL,一行一個(Grok 會把每則訊息合併成一行)。
  ```json
  {"timestamp":1792073586,"method":"session/update","params":{"sessionId":"…","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"},"_meta":{"modelId":"grok-5","promptIndex":0}},"_meta":{"eventId":"ev-1","agentTimestampMs":1792073586001}}}
  ```
- **解析**:id = `acp:<params._meta.eventId>`(否則行雜湊);時間 = `params._meta.agentTimestampMs`,否則 `timestamp × 1000`。
  - `user_message_chunk` → 使用者訊息;`update._meta.syntheticPrompt` 或 `hideFromScrollback` 為真時略過(Grok 自己寫的 prompt)。
  - `agent_message_chunk` → 文字;`agent_thought_chunk` → thinking。
  - `tool_call` → 工具呼叫(名稱取 `_meta["x.ai/tool"].name`,否則 `title`;輸入 `rawInput`;id `toolCallId`)。
  - `tool_call_update` 只有 `status` 為 `completed`/`failed` 的那一筆是結果(failed = 錯誤);文字取每個 `{type:"content"}` block 的文字,`{type:"diff", path}` → 「已編輯 <path>」。之前的更新是進度,忽略。
  - 其他(turn 結束、計畫、模式、背景任務、記憶)忽略;content block 只有 `type:"text"` 帶文字。
  - Header:模型取任何 update 的 `_meta.modelId`(實務上 prompt 就有,第一輪即知);沒有 context 數。
  - 工具名歸類:`run_terminal_command` 指令、`read_file` 讀、`search_replace` 編輯、`grep`/`list_dir` 搜尋、`web_fetch` 抓取。
- 依 Grok 1.0.52 量測(8 個真實 session)。出處:`src/lib/transcript/acp.ts`、`store.ts:238-264`、commit a1b67ef。

### 4.4 Antigravity(`agy`)【未實測】

- **位置**:kind `id` → `$HOME/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`;kind `path` → 回報路徑(通過路徑檢查)。旁邊的 `transcript_full.jsonl` 保留完整工具輸出,刻意不用。不執行搜尋。agy 的 session id 在**第一個 prompt 送出後**才回報(hook 在 PreInvocation)【herdr:docs/integrations.mdx:316】。
- **格式**:JSONL,一行一個 step:`{step_index, source, type, status, created_at, content, thinking?, tool_calls?, input_tokens?, cache_read_tokens?, output_tokens?}`。
- **解析**:id = `agy:<created_at>:<step_index>`(來源自稱是捷徑:同聊天兩段對話可能撞號);時間 = `created_at`。
  - `USER_INPUT`:只有 `source == "USER_EXPLICIT"` 是人打的;顯示 `<USER_REQUEST>` 與 `</USER_REQUEST>` 之間的文字。任何 `USER_INPUT` 都可能切換模型:比對「setting `Model Selection` from … to X.」取 X。
  - `PLANNER_RESPONSE`:assistant 訊息(thinking、`content` 文字、每個 `tool_calls[i]` 一個工具呼叫,id `agy-<step_index>:<i>`);參數值是 JSON 字串需各自解析,去掉 `toolAction`,鍵改名 `CommandLine`→command、`Cwd`→cwd、`AbsolutePath`→file_path、`toolSummary`→description;context = `input_tokens + cache_read_tokens`。
  - `GENERIC`:工具結果;文字去掉開頭 `Created At: …`/`Completed At: …`,CRLF→LF;**對應到前一個 step 的呼叫**(`agy-<step_index−1>:0`)——依順序配對會在一個呼叫被中斷後讓之後每個輸出都配錯(commit 600d7d9)。
  - **待決**:一個 step 有多個呼叫時,herdrchat 註解說「後續輸出配給最舊的未完成呼叫」,但配對程式只對**沒有 id** 的呼叫做 FIFO,而 agy 呼叫都有 id → 實際上後續輸出沒配上。見 §13。
  - 工具名:`run_command` 指令、`view_file` 讀、`search_web` 搜尋、`edit_file` 編輯、`ask_question` 提問。
- 依 agy 1.3.6 量測。出處:`src/lib/transcript/agy.ts`、`store.ts:220-236`。

### 4.5 Pi 與 OMP(共用 journal)【未實測】

- **位置**:通常 integration 回報 kind `path`(含自訂 `--session-dir` 與 profile)→ 直接用(通過路徑檢查)。kind `id` → 精確檔名搜尋:在 `${PI_CODING_AGENT_DIR:-$HOME/${PI_CONFIG_DIR:-.omp}/agent}/sessions`、`$HOME/${PI_CONFIG_DIR:-.omp}/agent/sessions`、`…/profiles`、`$XDG_DATA_HOME/omp` 下找 `*_<id>.jsonl` 或 `<id>.jsonl`;0 = 缺席、>1 = 歧義。【待決:Pi 自己的預設家目錄只透過 `PI_CONFIG_DIR`/`PI_CODING_AGENT_DIR` 才會被搜尋】
- **讀前檢查 header**:讀前兩行;第一行可能是 `{"type":"title",…}`(OMP 固定寬度標題槽),則檢查第二行;該行必須是 `{"type":"session","id":"<非空>",…}`,若回報的是 id 則必須相等;否則不符(並忘掉快取的查找)。
- **格式**:append-only JSONL,entry `{type, id, parentId, timestamp(ISO), …}`;parentId 構成分支樹,但**依檔案順序**讀(不重建分支視圖)。
  ```json
  {"type":"session","version":3,"id":"…","timestamp":"…","cwd":"/home/demo/ledger"}
  {"type":"message","id":"o-2","message":{"role":"assistant","model":"anthropic/claude-sonnet-5","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"src/totals.ts"}}],"usage":{"input":100,"cacheRead":2000,"cacheWrite":40}}}
  {"type":"message","id":"o-3","message":{"role":"toolResult","toolCallId":"c1","toolName":"read","isError":false,"content":[{"type":"text","text":"…"}]}}
  {"type":"model_change","model":"openai/gpt-5.6"}
  {"type":"model_change","provider":"anthropic","modelId":"claude-opus-4-5"}
  {"type":"thinking_level_change","thinkingLevel":"low"}
  ```
- **解析**:id `omp:<entry id>`;時間 = `message.timestamp`(有限非負毫秒)否則 entry 的 ISO 時間。
  - `message` user:字串或 `text` block(以換行連接)+ `image` 計數;**不做** Claude 式 harness 清理。
  - assistant:`text`、`thinking`、`toolCall{id,name,arguments}`、`image`(路徑一律空);`redactedThinking` 與未知 block 略過。
  - `toolResult`:文字取 `text` block、對應 `toolCallId`、`isError` 照記錄。
  - `branch_summary`(有 `summary` 字串)→ 系統訊息「分支摘要」+ 內容;`compaction` → 「context 已壓縮」(不顯示摘要);`reset_boundary` → 「context 已重置」。其他忽略。
  - Header:模型取 assistant 的 `model` 或 `model_change.model ?? modelId`(顯示時去掉 provider 前綴);effort = `thinking_level_change.thinkingLevel`(`^[a-z][a-z0-9_-]{0,31}$`);context = `contextSnapshot.promptTokens`,否則(`stopReason` 不是 aborted/error 時)`usage.input + cacheRead + cacheWrite`,否則 null(中斷的輪次 usage 為 0 無意義)。模型/思考層級變更可能早於開頭視窗 → 缺時在主機上掃整檔找最後的 `model_change` 與 `thinking_level_change`。effort 與模型分別合併。
  - `pi --no-session` 不寫 journal。
- 出處:`src/lib/transcript/omp.ts`、`store.ts:374-442`、`docs/getting-started.md:88-120`。

### 4.6 Claude 的 subagent 與 workflow 檔案

- 以 session 資料夾(對話紀錄路徑去掉 `.jsonl`)為根(Claude Code 2.1.294 量測):
  - `<session>/subagents/agent-<agentId>.jsonl`(Claude 格式,行帶 `isSidechain`)與 `agent-<agentId>.meta.json`;
  - `<session>/workflows/<runId>.json`(**只在 run 結束時寫**);
  - `<session>/subagents/workflows/<runId>/agent-<id>.jsonl`;
  - `<session>/subagents/workflows/<runId>/journal.jsonl`(執行中持續附加)。
  - subagent 的 subagent 平放在**同一個**主 session 的 `subagents/` 下;subagent 對話紀錄的 session 資料夾是 `/subagents/` 之前的部分。
- **meta**:`{agentType, description, toolUseId, spawnDepth, requestShape, model, …}`(workflow agent 另有 `workflowPhase`、`worktreePath` 等);全部欄位可選。
- **找出某呼叫啟動的 subagent**:讀 `subagents/` 下所有 `agent-*.meta.json`(用 `find`,不用 glob),找內容含該 `toolUseId` 字串者,再確認解析後的 `toolUseId` **完全相等**;**絕不用最新檔**(兩個 agent 可在同一毫秒啟動)。找不到 = 啟動中(執行中每 2 秒重試;已結束只找一次)。找到後依連線快取。
- **變動偵測不重讀**:先印檔案 checksum,與上次相同則不印內容。
- **委派是否結束**:在父對話紀錄中搜尋含呼叫 id(與 agent id)的行,同樣以 checksum 避免重傳,再用與卡片相同規則解析。
- **任務通知**(harness user turn,或 `commandMode:"task-notification"` 的 queued attachment):
  `<task-notification><task-id>…</task-id><tool-use-id>…</tool-use-id><output-file>…</output-file><status>completed</status><summary>…</summary><result>…</result><usage><subagent_tokens>83189</subagent_tokens><tool_uses>23</tool_uses><duration_ms>428124</duration_ms></usage></task-notification>`
  需同時有 `tool-use-id` 與 `status`;tokens 取 `subagent_tokens` 或 `total_tokens`;status 為 failed/killed/error/cancelled = 失敗。
- **Hand-back(2.1.294 起)**:報告以 peer 訊息到達(`origin {kind:"peer", from:"<agentId>", handback:true, body:"[Subagent hand-back] … The report follows:\n  <縮排兩格的報告>"}`,或文字中的 `<agent-message from="<id>">…</agent-message>`);此時通知的 result 只說「已以訊息交付」。報告 = 「The report follows:」之後去掉兩格縮排的文字。
- **Workflow run 檔**(寬鬆解析;寫一半的檔保留上次結果):`workflowName`、`summary`、`status`(running/pending/queued/started/null 都算執行中)、`phases[{title,detail}]`、`logs[]`、`durationMs`、`agentCount`、`totalTokens`、`workflowProgress[]`(`{type:"workflow_phase", index, title}`、`{type:"workflow_agent", index, label, phaseIndex, phaseTitle, agentId, model, state, startedAt, durationMs, tokens, toolCalls, lastToolName, lastToolSummary, resultPreview, error}`;state done/completed/cached = 完成,error/failed/killed = 失敗,其他執行中)。
- **Journal**:`{"type":"launched"}`、`{"type":"started","agentId","label","phase"}`、`{"type":"result","agentId","result",…}`;phase 依首次出現順序分組;有 result 即完成(有 error 為失敗);撕裂的最後一行略過。
- 出處:`src/lib/subagents/*`、`src/lib/__tests__/fixtures/subagents/*`、commit 17e2398、1f1548f、10b7fe8。

### 4.7 增量讀取規則

**位元組游標**
- **游標是檔案的 UTF-8 byte 數**,由主機計算或由收到的原始 bytes 計算;**絕不用 UTF-16 長度**(含 emoji 或非拉丁文字時會漂移,默默跳過訊息)。對有損解碼(錯誤 bytes 變 U+FFFD,3 bytes)後的長度加總也會讓游標超過真正位置、下一行遺失(commit badf15a、2bdc7f9)——游標必須來自主機回報的大小或原始 byte 計數。
- 【推論】swift-nio-ssh 拿到的是原始 bytes,可直接以 byte 計數推進游標,不需要 herdrchat 的「主機 awk 為每行加 byte 長度前綴」技巧;但若要在主機上剝除圖片(下述),仍需要主機回報每行原始長度。

**探測檔案(三態)**:依序檢查資料夾存在 → 資料夾可搜尋(`-x`)→ 檔案存在 → 檔案可讀 → 印出大小。各自不同 exit code:缺席(資料夾或檔案不在)= 正常(剛拿到 id、agent 還沒寫檔),靜默重試;不可搜尋/不可讀 = 「未知」並回報(曾把權限錯誤當缺席,對話永遠在等,#23、#46)。

**開啟:讀最後 N 行(主機上剝除圖片)**
- 開啟讀最後 **300 行**(約 100 則訊息);往上每頁 **200 行**。以**行**計不以 byte 計:Claude 把讀過的每張圖以 base64 內嵌兩次,單行可達 0.3–1MB,384KB 的 byte 視窗只能開出十幾列(commit d14e4d4)。
- 主機上的視窗讀取(行為描述):給定檔案、結束 byte `e`、行數 `n`:從 `e` 往前取一塊(4MB 起),數換行;塊未到檔頭且行數不足就把塊放大 4 倍再數;視窗結束 = 塊內最後一個換行之後(**正在寫的未完成行留給追蹤**);視窗開始 = 讓視窗剛好含 `n` 行的位置;先印「開始 結束」兩個 byte 位置,再印該範圍內容並**把圖片資料換成空字串**:任何長度 ≥128 的 base64 字元引號字串、以及 `"data:…;base64,…"` 字串 → `""`(200 行由 6.2MB 變 196KB)。被剝除的行仍是一行,所以位置範圍仍正確。
- 開啟視窗以**剛探測到的大小**為上限(agent 同時在寫也不會變成無上限的補讀);回傳訊息、起點(往上翻的錨點)、終點(追蹤起點)。回應格式不對或範圍不合理 → 「對話紀錄改變」,重試。
- 效能教訓:不要對管線用 `tail`(BSD tail 約 60MB/s,30MB 對話紀錄每頁 2 秒);以 seek(`dd … count=0` 移動共用檔案位置再 `head -c`)+ `head`/`wc` 計數(0.2 秒)。busybox 的 grep 沒有 `-b`。`head -n 0` 在 BSD 是錯誤。腳本一律以 `sh` 執行(登入 shell 可能是 zsh/fish)。
- 讀取失敗:保留快取、重試有上限的讀取;**永不退回從 byte 0 追蹤**。

**即時追蹤**
- 從游標開始 follow 檔案(POSIX:`tail -c +<游標+1> -f`),逐行送回;herdrchat 在主機上用 awk(C locale)為每行印出「原始 byte 長度 TAB 剝除圖片後的行」並逐行 flush,使游標精確、MB 級的圖片行只傳不到 10KB。awk 可攜性:Debian/Ubuntu 預設的 mawk 會緩衝管線輸入(必須偵測 mawk 才加 `-Winteractive`,macOS awk 拒絕此旗標);舊 mawk 不支援 `{128}` 這種區間正規式(commit bc0afd4、2bdc7f9)。
- **只送完整的行**:以 `\n` 切分,不依 chunk 邊界(chunk 邊界常落在行中,破壞 JSON);結束時沖出尾端殘行。
- 手機端以 **100ms** 批次:一個交易寫訊息、**之後**才寫游標(最後一行結尾)、一次 UI 重建。
- **串流必須在通道關閉時停止主機程序**:sshd 在子程序仍在時保持 session,安靜的 `tail -f` 永遠不寫所以永遠不知道通道關了——每個被留下的追蹤在主機上跑了好幾小時(#4)。herdrchat 的做法:把 stdin 留給一個看門程序,讀到 EOF 就殺掉命令的葉子程序;**開始時不可對串流送 EOF**。【需換做法:Windows 沒有對應工具,見 §11】

**從游標恢復**
- 重開時探測大小並與游標比較(F5.3 第 3 點):相等 → 用快取;單一來源落後 ≤**64KB** 且畫面有東西 → 從游標串流;否則讀新的 300 行視窗並取代快取(**永不逐行重播大量積壓**:11MB 的落差花了好幾分鐘,#66;兩個來源的積壓交錯會亂序)。
- **在主機回報的行邊界恢復**:問主機「游標前一個 byte 所在行的開頭位置」(只讀游標前 64KB,整段 `LC_ALL=C`——BSD `cut` 遇到被切斷的多 byte 字元會停在「Illegal byte sequence」;塊內完全沒換行才退回讀整個前綴);結果必須 0 ≤ 結果 < 游標。問不到才退回游標 − 4096 bytes,重疊以訊息 id 去重(#109、commit be0d864)。

**往上翻**:F5.4;同樣的視窗讀取,`end = 目前視窗起點`、200 行;`起點 ≤ 0` 即到頂。

**監看器與失敗**:F5.3 第 6–8 點。

**快取**:家目錄、Claude 設定目錄、已定位的路徑依連線快取(快取 promise、失敗不快取、缺席結果丟掉以便重試)。訊息快取帶「解析器版本 + session 簽章」戳。

**Header 初值**:每個綁定的 session 一次:讀檔尾 1MB、在主機上剝圖、再截最後 256KB(先剝再截:以截圖結尾的聊天否則整個視窗只有一張圖,commit bc6ff87),從尾往前找第一個有模型的與第一個有 context 的中繼資料。之後只靠追蹤更新(沒有計時器)。

**列表預覽(一次往返批次)**:每次輪詢把所有要預覽的聊天合成一個主機腳本:每個請求印一行「隨機分隔標記 + key」(標記每次呼叫隨機產生——固定標記曾被一份談論本 app 的對話紀錄內容撞到,commit 1fc9dfa),再印剝圖後的檔尾 48,000 bytes(Pi/OMP 另含 header 檢查);腳本以不會失敗的指令結束(一個檔不存在不讓整批失敗)。預覽 = 最後一則非 sidechain、非純工具、非系統的訊息;文字去掉 `**`、`__`、反引號、開頭 `#` 與清單記號,壓縮空白,截 200 字;shell 指令顯示 `! cmd`。完整掃描:第一次、每第 5 次、強制時;其他時候只掃 active/seq 有變/事件指名/無快取的 agent。
- 出處:`src/lib/transcript/store.ts:463-1059`、`src/features/thread/useTranscriptTails.ts`、`src/lib/transcript/window.ts`、`src/features/chats/useWorkspaces.ts:658-747`。

### 4.8 從終端機畫面擷取的資訊

**即時預覽**(working 時,主要 pane 的 visible 40 行)
1. 每行清理:去 OSC、CSI 與其他跳脫序列(正規式中必須真的含 ESC 字元——曾經漏掉讓 `[TODO]` 變成 `ODO]`,#12);只修剪兩端的框線字元 `│┃|╭╮╰╯─┌┐└┘├┤`、空白、tab;內部 `│┃` 換成 `|`。
2. 去掉底部 chrome:從 Codex 的「Queued follow-up inputs」面板到結尾;含「← for agents」的輸入框頁尾以下全部。
3. 找錨點(最後一個符合者):spinner 行(首字為 `✳✽✻✢✶✷✸✹✺⚹∗·` 或 U+2801–U+28FF 點字,接空白與字母,且含 `…`);否則狀態行(含 `esc to interrupt`、`tokens)`、`token · `,或 `↓ ` 與 `token`,但排除 agents 窗格行與 `for agents`);否則不含 `…` 的類 spinner 行;否則最後一個以 `❯`/`›` 開頭的行(輸入框);否則畫面結尾。
4. Codex:錨點前最後一個 `• ` 行若是 `• Ran`/`Running`/`Viewed Image`/`Explored`/`Searched` → 不顯示預覽。
5. 從錨點往上收最多 8 行:跳過空行直到找到文字,下一個空行停止;遇到 `❯`/`›` 後接文字(prompt)停止;以 `⎿` 開頭 = 工具輸出 → 不顯示;略過 chrome:以 `❯›>` 開頭、agents 窗格行、類 spinner 行、分隔線(`-─=`)、只有點字或方塊元素(U+2580–U+259F,Grok 捲軸)的行,以及含 `manual mode`、`for agents`、`/effort`、`◉`、`esc to`、`ctrl+`、`⏸`、`resume this session`、`? for shortcuts`、`restart to update`、`auto-update`、`ctx:`、或含 `@` 且有三個以上 `|` 欄位的行。
6. 去掉一個前導 `⏺`、`●`、`⏵`;**至少 20 字**,否則不顯示(錯的預覽比沒有更糟)。
- 一定用 `visible`:Claude 在 alternate screen,`recent` 會是空的。
- 出處:`src/lib/transcript/livePreview.ts`、`ansi.ts`、commit b4453ad、9689320、bfa4fd0、ead0442。

**Claude 背景 agents 窗格**:最後一個 `⏺ main`(或 `● main`)標頭之後的列:`<記號> <種類>  <任務>  <1h 13m 1s>  · ↓ <156.7k> tokens`。記號:`◯○` 執行中;`⏺●◉✓✔` 完成;`✗✘×` 失敗。最後一行 `↓ N more` = 折疊下還有 N 列。token 數格式 `980`、`1,234`、`156.7k`、`1.2M`。出處:`src/lib/transcript/agentsPane.ts`。

---

## 5. Blocked 狀態:偵測、取得選項、回答

### 5.1 偵測

- 來源(每次狀態輪詢):`agent_status == "blocked"` 的 agent;若沒有,則找 `input_pending == true` 且不在 working 的 agent。
- 讀該 pane 的 **visible 畫面 40 行**(`pane.read`)。
  - input_pending 的 pane:若畫面解析為 slash 指令面板 → 是面板(§F9.4)不是問題;否則若解析為有選項的選單 → 視為 blocked(Claude 首次啟動的資料夾信任;herdr 回報 idle 並以 `agent_input_pending` 拒絕 prompt,commit 4abefa0)。
  - blocked 的 Codex,畫面同時含 `All Results`、`Filesystem Only`、`Plugins` → `@` 檔案選擇器:只提供「關閉選擇器」(Esc),說明「Codex 開著檔案選擇器,可在此關閉或到終端機選檔」;此時數字或 Enter 會把檔案插進 prompt(herdr 0.9.1 把它算 blocked,commit a956a55)。
  - 其他 → 解析選單(§5.2)。「送出需要 Enter」= 該 agent 的「數字即回答」旗標之反。
- 同一問題在多次輪詢間保持同一物件(以內容比較)。blocked 期間快速輪詢。
- 出處:`src/features/thread/useBlockedPrompt.ts:65-126`、`src/lib/transcript/blockedPrompt.ts`。

### 5.2 選單解析(依 fixture 畫面:`src/lib/__tests__/fixtures/screens/*.txt`)

- 每行去 ANSI、修剪框線。
- **選項行**:可選的游標記號(`❯ › ▶ > → • *`)之後:
  - Grok 形式 `^([1-9]) \([●○]\) (.+)$`(例 `2 (○) Yes, proceed`);字母列(如 `z (○) Type your answer here`)排除。
  - 數字 + `.` 或 `)` + 標籤;標籤中:2 個以上空白後接 `│┃┌└├╭╰` 之後是側邊預覽面板 → 截掉;結尾快捷鍵提示 `(y)`、`(p)`、`(esc)`、`(enter)`、`(return)`、`(tab)` → 去掉;`[ ]` 或 `[x]`/`[X]`/`[✔]`/`[✓]` 前綴 → 勾選列(多選)。
- **縮排規則**:縮排超過選單編號欄、緊接在某選項下的行屬於那個選項(描述、折行標籤、預覽),**永不是新選項,即使以 `1.` 開頭**(#107)。
- **最後一個連續選單勝出**:編號不大於前一個時重置清單。
- **折行標籤**:兩個選項之間、未縮排超過編號、自身不是選項的行,接續上面的標籤(agy 會折到第 0 欄)。
- **問題文字**:第一個選項正上方的連續行,往上到空行、選項或分隔線(8 個以上 `─━▔╌╍┄┅┈┉`,或 `╭──…╮` 框頂),以空白連接。
- 有任何勾選列 → 多選。沒有選項 → 試資料夾信任解析器;仍沒有 → 沒有提示,顯示通用鈕。
- Codex 的游標是 `›`(沒辨識時選項 1 會消失)。

### 5.3 權限細節(要批准的是什麼)

- 從問題往上找提示自己的**開頭分隔線**(實心 8 個以上 `─━▔`,或框頂)。
  - 先遇到第 0–2 欄的對話記號(`⏺⎿❯›•✻✳✢✶✽>`)→ 改試 Codex 形式。
  - 越過虛線分隔或 `│ ` 邊界後到達畫面頂端 → 提示開頭在畫面外:標示「細節在畫面外」且**不顯示標題**(不可把指令行升格為標題,commit 0e78357)。
- 區塊:第一行是標題(`Bash command`、`Create file`、`Edit file`;以 `←→☐☒☑✔✓□■●◯` 開頭者是 AskUserQuestion 的分頁頭 → 無標題);之後到空行/分隔線/邊界行為摘要(去掉 `Tip:` 行);兩條虛線(2.1.299)框住內容,最後一條之後是附註;沒有分隔線時,結尾的 `⚠…` 或期限行是附註。
- 依 pane 寬度(由分隔線長度推得,容許 2 欄誤差)接回被終端機折行的行,字中被折斷的不加空白;內容去縮排並去掉指令的 `│ ` 邊界;複製時是**將要執行的樣子**。
- 舊版 Claude(2.1.280):Bash 標題且無摘要時,內容最後一行若是散文(大寫開頭、含空白、無 shell 元字元)移到摘要。
- **期限**:`automatically deny this request in (M:SS | about N minutes/seconds)`——每次輪詢從畫面重讀,手機不倒數。
- agy:問題上方有 `Requesting permission for:` → 其下縮排行是內容,標題是其上分隔線上方那一行(`Command`)。
- Codex:沒有分隔線;問題上方段落以 `Would you like to …` 開頭;標題以 `the following command?` 結尾且問題以 `$ ` 開頭 → 指令成為內容,散文(Environment、Reason)成為摘要。
- 出處:`blockedPrompt.ts:290-418`、commit 3405b1a、4231c49、2c181f2、a864a84。

### 5.4 資料夾信任提示(沒有編號)

- 只在畫面同時有標頭 `Accessing workspace:` 與選項 `Yes, I trust this folder` 時辨識。選單 = 該選項周圍的非空列;游標列以 `❯`(Claude)或 `>`(agy)開頭。
- 每個選項帶自己的按鍵:從游標列到該選項的 `up`/`down` 次數,再 `enter`。**Claude 的游標起始在「No, exit」,單按 Enter 會關掉 Claude。**
- 問題:「信任 <資料夾>?<Agent> 將能讀取、編輯、執行那裡的檔案」(資料夾 = 標頭下第一段,折行接回不加空白,以 `/` 或 `~` 開頭才用);否則「信任這個資料夾?」。Agent 名取自畫面上「<X> requires permission to」,預設 Claude Code。不顯示編號。
- Fixture 實例:Claude(2.1.286)游標在 No → Yes = `down, enter`、No = `enter`;agy 游標在 Yes → Yes = `enter`、No = `down, enter`,資料夾跨三行接回成一條路徑;Codex 的信任是一般編號選單 `1. Yes, continue / 2. No, quit`,要數字 + Enter。
- 出處:`blockedPrompt.ts:604-670`、fixtures `trust.txt`、`agy-trust.txt`、`codex-trust.txt`。

### 5.5 回答的按鍵

經 `pane.send_keys {pane_id, keys}` 送到 blocked 的 pane(沒有則主要 pane)。

| 情況 | 按鍵 |
|---|---|
| 選項帶自己的按鍵(信任提示) | 那些按鍵(方向鍵 × n,再 `enter`) |
| 編號不在 1–9 | **不可從手機回答**(顯示但停用) |
| 多選列 | 只送數字(切換勾選) |
| 數字即回答的 agent(Claude、Grok、Antigravity) | 只送數字(多一個 Enter 會回答**下一題**或在多選中多勾一列,#107;agy 的 Enter 會落進輸入框) |
| 其他(Codex、Pi、OMP、未知 agent) | 數字,再 `enter`(Codex 的數字只移動游標) |
| 多選「繼續」 | `right`(移到下一題或檢閱畫面;檢閱畫面是普通選單) |
| 關閉選擇器 | `esc` |
| 通用鈕 | 確認 `enter`;「1」`1, enter`;「2」`2, enter`;Esc `esc` |

- **提示簽章**(判斷「同一個提示」):問題 + 細節的標題、摘要、內容(**不含附註**,因為期限每秒在變)+ 每個選項「編號.[x]/[ ]標籤」(含勾選狀態,切換勾選才看得出已送達);只用內容第一行曾讓連續的 `cd /repo && …` 指令看起來相同(commit 4231c49)。讀不到畫面 → 簽章 null = 未知,永不當成新提示。
- 進行中回答的判定與期限:F8。
- 出處:`blockedPrompt.ts:137-149,697-760`、`agents.ts:34-39`、commit 1bef1d1、628eb9d、82e9bd1、934da83。

### 5.6 Slash 面板(閒置狀態下的選單)

- Claude 面板:頂端 8 個以上 `▔` 的分隔,之後有符合 `Esc to (cancel|close|exit|go back)` 的提示行;沒有提示行但有選單且沒有輸入框分隔(`─{8,}`)也算(「Switch model?」確認)。列:可選游標 `❯`/`›`(或 `↑`/`↓` 捲動箭頭)、`NN. 標籤`、2 個以上空白後是細節;`✔` 標示目前選擇。含 `▲` 與 `─` 的行是滑桿,下一行是層級名;`←/→ to adjust` 表示可調整。提示行以 ` · ` 切成動作 `<Key> to|for <文字>`(Enter/Return、Esc、Tab、Space 或單一字母如 `s`)。
- Codex 面板:頁尾 `Press enter to confirm or esc to go back`;其正上方的列為選項,再上方為標題段;`(current)` 標示使用中;動作 Enter(確認)、Esc(返回)。
- 回答一律用游標鍵,永不數字(F9.4)。
- 出處:`src/lib/transcript/paneOverlay.ts`。

---
## 6. 終端機

### 6.1 三種目標

| 目標 | herdrchat 的指令 | 使用時機 |
|---|---|---|
| Agent pane | `herdr agent attach <pane_id> [--takeover]` | pane 中 herdr 偵測到任何 agent |
| Shell pane | `herdr terminal attach <terminal_id> [--takeover]`(用 snapshot 的 `terminal_id`,**不是** pane id;`terminal attach w4:pB` 會回 not found) | 沒有 agent 的 pane |
| 登入 Shell | 使用者的預設 shell 以登入模式啟動(不加 PATH 前綴、不經 herdr) | Computers 分頁 |

- 共同前綴:設 `LANG`(未設時用 UTF-8 locale;sshd 不傳環境、App 也不送 env)、PATH、具名 session。
- `--takeover` 只有在使用者按「接管」時才加(§6.3)。
- 早期作法「把 pane zoom 起來再 `session attach`」被移除:zoom、focus、側欄是 herdr 的**共享狀態**,會移動桌機畫面——「影響其他檢視者或 client 的狀態不可接受」(commit dede6a7)。direct attach 只把那一個 pane 畫給手機,不改桌機的 zoom/focus/側欄;唯一共享的是 pane 尺寸(attach 期間 pane 以此 client 的尺寸繪製,detach 時恢復)。
- 無法建構指令(snapshot 沒有 `terminal_id`、或 id 含不安全字元)→ 說明且**不提供重新連線**(永遠不會成功,commit 77f2ee9)。
- herdr 的 prefix(Ctrl-B)永遠屬於 herdr,不會到達程式;prefix 後按 `q` detach(exit 0)。
- 沒有 TTY 時 attach 失敗(`Inappropriate ioctl for device`)。
- **Windows:原生 Windows 不支援 direct terminal attach**(`herdr terminal attach` 與 `herdr agent attach` 回「direct terminal attach is not supported on Windows yet」)【herdr:src/client/startup.rs:17-24、herdr:docs/windows-beta.mdx:130-140】→ Windows 主機的 Pane 終端機只能走 `terminal session control`(§6.5)。
- 出處:`src/lib/terminal/command.ts:7-129`、`src/features/terminal/target.ts:42-47`、`status.ts:17-79`。

### 6.2 herdrchat 的 PTY 繞路(說明「為什麼」,我們不需要)【需換做法】

- Citadel 只能對 `shell` 請求開 PTY,不能對 `exec` 開。herdrchat 因此開一個互動登入 shell,再**打字**送入一行「以空白開頭(不進 history)、`exec` 一個 `/bin/sh -c '<印出一次性標記>; <指令>'`」;輸出端過濾器把標記出現前的所有東西(MOTD、Last login、prompt、回顯)丟掉,標記之後原樣通過。標記在打字的那一行裡用 `""` 拆開,所以回顯與行編輯器重繪永遠不會出現完整標記,只有 shell 真正的輸出會。標記含 8 bytes 亂數(舊 scrollback 不會誤中)。**失敗開放**:20 秒內沒看到標記或累積超過 256KiB → 全部放行原樣顯示。指令中不可有反斜線(fish)。
- 副作用(使用者看得到的雷):rc 檔若在 SSH TTY 上自動啟動 tmux/screen/herdr,打字的那一行會落進那個程式裡;App 無法讓自己的 session 被跳過(沒有 env 請求,sshd 預設 `AcceptEnv` 也會丟掉;`$SSH_TTY` 有值、`$-` 含 `i`、`TERM=xterm-256color`,和人自己 ssh 一模一樣)。只能由使用者在 rc 中加條件。
- **Drover Chat**:swift-nio-ssh 可在同一 channel 先送 `pty-req` 再送 `exec`,所以 attach 與登入 shell 都可直接 exec,不需要標記、不受 rc 影響【推論,未實測】。Exit status 必須在讀取迴圈中取得(Citadel 在主機關閉後自己的 close 會拋錯蓋掉真正的 status,曾把 exit 3 回報成 0,commit 8f08922)。
- 出處:`modules/herdr-ssh/ios/ShellLaunch.swift:3-131`(繞路本身,只供理解)、`modules/herdr-terminal/README.md`「A shell rc that starts tmux or herdr」。

### 6.3 接管(takeover)規則

- 已有另一個寫入端 client 時,第二個 attach 以 **exit 1** 結束並說明「已有 attached client,請以 --takeover 重試」;第一個 client 不受影響。被接管的一方收到「terminal attach taken over」。桌機的 herdr TUI client **不算** attached client。
- App 只在「通道以 exit code 1 結束」時顯示「接管」並說明「herdr 無法 attach,可能有其他 client 已附著,或 pane 已關閉」。按下(輕觸覺)以 `--takeover` 重開。**首次開啟與每次重新連線都不帶 --takeover**——永不自動搶。
- 已知:App 被殺掉後 herdr 可能仍持有死掉的 client,下一次 attach 會被拒(手動驗證過的情況)。
- 出處:`src/features/terminal/status.ts:37-39`、`useTerminalShell.ts:175-183`、`herdr:src/server/headless.rs:1786-1808`、commit dede6a7。

### 6.4 尺寸、輸入、手勢、剪貼簿、連結

**尺寸**
- 終端機視圖第一次回報以格為單位的尺寸後才開通道(之前狀態「等待」);cols/rows 由模擬器依字型與邊界算出。綁定通道時立即送一次目前尺寸。
- 之後尺寸改變**去抖 250ms** 才送給主機(鍵盤滑動動畫每幀都改尺寸,而每次 resize 也會重繪桌機的 pane);0 欄或 0 列拒絕。PTY 以 `window-change` 送(像素 0)。
- 鍵盤推高終端機(不覆蓋);旋轉與鍵盤變化都只是新尺寸;鍵盤隱藏時才套用底部安全區;邊到邊、左右 4pt 內距。
- PTY 請求:term `xterm-256color`、至少 1×1、像素 0、無 terminal modes。

**字型**:系統等寬、一般粗細;預設 13pt、最小 8、最大 28(<8 不可讀;>28 時直立 iPad 放不下 80 欄);捏合以手勢開始時的大小縮放、即時限制、結束時回報;**只存在記憶體、不持久化**(刻意);捏合與滾輪手勢互斥。

**Accessory bar**(在軟體鍵盤上方)
- 一條可橫捲的按鍵列 + 兩個固定控制:**貼上**、鍵盤開關(永遠可用)。每個鍵選擇觸覺;鍵至少 44pt、等寬 15pt 粗體。沒有開著的通道時按鍵與貼上變暗停用(位置不變)。列要捲而不是縮或換行;**Esc、Tab、Ctrl、Alt 在 iPad 最窄詳細欄中也必須不捲就看得到**。
- 按鍵與無修飾時送出的 bytes:

| 鍵 | bytes |
|---|---|
| esc | `1B` |
| tab | `09` |
| ctrl / alt | 黏著切換,本身不送 |
| ← ↓ ↑ → | `1B 5B 44` / `1B 5B 42` / `1B 5B 41` / `1B 5B 43`(CSI D/B/A/C) |
| `/` `-` `\|` `~` | 字面字元 |
| home / end | `1B 5B 48`(CSI H)/ `1B 5B 46`(CSI F) |

- 有修飾時:修飾參數 = 1 + Alt(2) + Ctrl(4);游標類鍵變 `CSI 1;<p><final>`(Ctrl-↑ = `ESC[1;5A`);(未放在列上的)PageUp/PageDown 為 `CSI 5~`/`CSI 6~`、`CSI 5;<p>~`。Esc/Tab 加 Alt 前綴 `ESC`;只有 Ctrl 時送原 byte。字元加 Ctrl:字母 → 0x01–0x1A;`@`、空白、`2` → 0x00;`[`、`3` → ESC;`\`、`|`、`4` → 0x1C;`]`、`5` → 0x1D;`^`、`~`、`6` → 0x1E;`_`、`-`、`/`、`7` → 0x1F;`?`、`8` → 0x7F;其他不變。Alt 在結果前加 `ESC`。
- (編碼器支援但未接上的模式:DECCKM 讓方向鍵變 `ESC O A`;Kitty 鍵盤協定 `CSI 27u` 等——App 看不到程式的模式,所以沒用。)
- **黏著 Ctrl/Alt**:點一下高亮;下一個 bar 鍵帶著修飾編碼後兩者都放開;同時把修飾推給模擬器,讓**下一個軟體鍵盤字元**也帶修飾,模擬器回報重置後 bar 取消高亮。
- bar 的 bytes 直接寫給通道(不經模擬器)。
- **貼上**:呼叫模擬器的貼上(剪貼簿文字,程式要求時加 bracketed paste;可能觸發系統「允許貼上」)。

**硬體鍵盤**:按鍵經模擬器(它知道程式的模式);Option 當 Meta;**Command-K 清除 scrollback**;模擬器自己的 input accessory 關掉。iPad 上通道開啟後終端機自動取得焦點。

**手勢**
- 兩種 attach 都把 herdr 的 client 畫在 alternate screen 且開啟滑鼠回報;模擬器預設會把單指拖動變成按下-拖曳-放開(到 herdr 變成選取或拖動分割線,本地 scrollback 又是空的,commit d510778)→ **移除模擬器的滑鼠拖動手勢**。
- 程式持有滑鼠時,**垂直**單指滑動(|vy| ≥ |vx|)送**滾輪事件**:SGR/xterm 編碼的按鈕 64(上)/65(下),每滑過一列一個事件,座標是手指所在格;自然捲動(手指往下 = 滾輪往上)。iPad 觸控板雙指捲動同樣處理(接受連續與離散的間接捲動,commit 8b4c532)。
- 程式沒持有滑鼠時,滑動捲動模擬器自己的 scrollback。點擊仍是點擊;長按選取與複製是模擬器內建行為。

**剪貼簿與連結**
- 程式的 OSC 52 **寫入**剪貼簿:允許(合法 UTF-8 才寫)。
- OSC 52 **讀取**:**一律拒絕**(回空)——會讀到使用者在任何地方最後複製的東西。
- 連結:只開 `http`/`https`,其他 scheme 忽略。
- 標題與 bell 轉成事件;cwd 更新、捲動位置等回呼忽略。

**配色**:由 App 調色盤(含主機主題)推導,所有顏色為不透明 `#RRGGBB`;背景 = 系統背景、前景 = label;紅綠黃取自 destructive/positive/attention 色,藍 = tint,洋紅與青 = tint 色相轉到 300° 與 185°,逐一調亮(深色)或調暗(淺色)直到達文字對比;亮色版依規則調整到對比 ≥3;灰階由背景往前景混合;游標 = tint(對比 ≥3)否則前景;選取 = tint 35% 疊背景;鍵盤外觀與捲軸跟隨深淺色。ANSI 色表長度不是 16 就忽略。

- 出處:`src/lib/terminal/keys.ts`、`barFit.ts`、`theme.ts`、`src/features/terminal/AccessoryBar.tsx`、`fontSize.ts`、`modules/herdr-terminal/ios/HerdrTerminalView.swift:40-225`、`PaneTerminalView.swift`、`src/lib/herdr/timeouts.ts:214-229`。

### 6.5 生命週期

- **App 進背景 → 立刻掛斷,回前景不自動重連**(鎖著的手機不能一直佔住 attach,也不能讓桌機 pane 一直是手機尺寸,commit fc77291)。通道在背景時才開好 → 立即掛斷。
- 離開畫面 → 掛斷;仍在開啟中就離開 → 開好時掛斷。
- 在「開啟」完成前就到達的「結束」事件要保留並顯示(否則畫面在死掉的通道上顯示「已連線」,commit fb1f2f1)。
- 掛斷 = 關閉通道,主機送 SIGHUP 給該命令。
- 重新連線開**新**通道,但保留同一個模擬器(舊 scrollback 留在上方)。
- 輸出在視圖附上前到達 → 暫存(上限 2MiB,超出丟最舊),讓立即失敗的命令仍能顯示錯誤;App 已忘記的通道的晚到輸出丟棄。通道開好前的輸入丟棄。
- 結束原因:`exited`(含 exit code;因為用 exec,命令的 status 就是通道的)、連線中斷(client 已不連線)、傳輸失敗(通道壞但 client 還在)、App 主動關閉(不回報)。
- 開啟逾時 20 秒;開啟逾時**不**重設整條連線(慢的終端機不代表其他共用指令有問題)。
- 出處:`src/features/terminal/useTerminalShell.ts:20-213`、`modules/herdr-ssh/ios/SshShell.swift`、`modules/herdr-shell-registry/ios/ShellRegistry.swift:42-151`。

### 6.6 herdr `terminal session control` / `observe` 協定(herdrchat 未使用)

herdrchat 的程式碼與 commit 訊息都沒提過它,也沒有說明為何不用(只有被否決的 zoom + session attach 作法)。以下依 herdr 原始碼、文件與 `--help`【實測 help】。

**指令**
```
herdr terminal session control <TARGET> [--takeover] [--cols N] [--rows N]
herdr terminal session observe <TARGET> [--cols N] [--rows N]
```
- 預設 `--cols 120 --rows 40`;值 1–65535(0 回「must be greater than 0」);未知選項或缺 target → exit 2;`--takeover` 只對 control 有效。
- TARGET:terminal id、pane id(`w1:p1`)、或 agent 名稱/label(必須唯一對到一個 terminal)【herdr:src/app/terminal_targets.rs:33-72】。
- 版本:0.7.2 加入 observe/control;0.9.1 observer 寫入 30 秒逾時;0.9.2 加入 `terminal.mouse`【herdr:CHANGELOG.md】。
- **不需要 PTY**:以 stdin/stdout 交換 NDJSON,用給定 cols/rows 做 handshake,要求 ANSI 編碼(協商到其他編碼 exit 1)【herdr:src/client/terminal_sessions.rs:73-126】。適合一般 SSH exec 通道。
- Exit code:連不到 socket 或 handshake 失敗 → exit 1(stderr `herdr: …`);**其他情況都 exit 0,即使伺服器拒絕**——拒絕以 `terminal.closed` 紀錄送來,呼叫端必須看 `reason`。
- 文件說明【herdr:docs/persistence-remote.mdx:141-164】:observe 給只需要畫面 bytes 的第三方 bridge,多個 observer 可同時看、不搶輸入/尺寸/捲動/接管;control 給互動 bridge,同一時間只有一個 controller 擁有輸入與尺寸。

**stdout(每行一個 JSON)**
```json
{"type":"terminal.frame","seq":<u64>,"encoding":"ansi","width":<cols>,"height":<rows>,"full":<bool>,"bytes":"<標準 base64>"}
{"type":"terminal.closed","reason":<string|null>}
```
- `seq` 每個 client 單調遞增;`full:true` = 完整重繪、`false` = 增量差異;attach 或 observe 後第一個 frame 是基準(render 狀態重置);`bytes` 是可直接餵給終端機模擬器的跳脫序列。伺服器 EOF → 不印紀錄直接結束;圖形等其他伺服器訊息丟棄。
- 已知 `reason`:`detached`(release 或 stdin EOF)、`terminal attach taken over`、`terminal session control failed: terminal target <t> not found`(observe 同理)、`terminal attach failed: terminal <id> already has an attached client; retry with --takeover`、`terminal attach failed: terminal <id> has a read in progress; retry`、`terminal <id> exited`、`server is shutting down`、`live update in progress; reconnect after handoff completes`。

**stdin(只有 control,每行一個 JSON;空行略過;無效行忽略並在 stderr 警告,串流繼續)**
- `{"type":"terminal.input","text":"ls\r"}` 或 `{"type":"terminal.input","bytes":"<base64>"}`:兩者恰好其一(都有是錯誤,都沒有送空輸入)。完整的 bracketed paste(`ESC[200~ … ESC[201~`)依 pane 模式當貼上送;其他原樣寫入。輸入會重置 pane 捲動位置。**每則上限 1MiB**:超大的 bracketed paste 被拒(此串流看不到 toast);其他超大輸入**會斷開 client**【herdr:src/server/pane_input.rs:186-200、client_transport.rs:48】。
- `{"type":"terminal.resize","cols":100,"rows":30,"cell_width_px":0,"cell_height_px":0}`:cols/rows > 0,像素可選;controller 的 resize **會改變 pane 的 PTY 尺寸**,attach 期間鎖在 controller 尺寸,離開時恢復。
- `{"type":"terminal.scroll","direction":"up|down","lines":3,"source":"wheel|page_key","column":0,"row":0,"modifiers":0}`:lines > 0;`wheel` 由伺服器依 pane 狀態路由:程式開了滑鼠回報 → 在該格送編碼後的滾輪;alternate-scroll 模式 → 方向鍵;否則 → herdr 主機端 scrollback 上下捲。`page_key` → `ESC[5~`/`ESC[6~`(除非一般 page key 用主機 scrollback)。
- `{"type":"terminal.mouse","action":"down|up|drag|move","button":"left|right|middle","column":12,"row":5,"modifiers":0}`:座標是 controller viewport 的零起算格;`button` 預設 left;**modifiers 是 crossterm 位元:Shift=1、Ctrl=2、Alt=4(不是 xterm 編碼)**;點擊 = down 再 up;程式沒開滑鼠回報時伺服器丟棄;`move` 只到追蹤所有移動的程式【herdr:docs/cli-reference.mdx:386-394】。
- `{"type":"terminal.release"}`:送出 detach,伺服器回 `terminal.closed` reason `detached`。**stdin EOF 等同 release**(輸入執行緒在 stdin 結束時送 detach)——關閉 SSH 通道的 stdin 就能乾淨釋放【herdr:src/client/terminal_sessions.rs:44-68、337】。

**所有權與尺寸語意**
- 每個 terminal 只有一個寫入擁有者,control 與 `terminal attach`/`agent attach` 共用擁有者表,互斥;沒 `--takeover` 被拒,有則舊擁有者收到「taken over」並被移除;取得擁有權也會啟動該 terminal 上待處理的 agent resume。
- Observer:數量不限,沒有輸入/尺寸/捲動/接管權;其 cols/rows 只決定**自己的** render viewport,pane 的 PTY 永不被改(observer 尺寸不同時看到的是 pane 畫進自己的 viewport,不是 pane 的真實大小)。CLI observe 不讀 stdin,尺寸在啟動時固定。Unix 上 observer 30 秒寫不出去會被斷線(可能收不到 closed 紀錄)。
- **observe 不讀 stdin,所以只有在下一次 stdout 寫入失敗時才發現 SSH 通道關了**;安靜的 pane 會讓它在主機上一直活著——需要和追蹤串流同樣的「通道關閉即停止」處理,或改用 control 並關 stdin。
- **Windows**:client 程式碼對 control/observe **沒有** Windows 封鎖(經 `interprocess` 用本地 socket);observer 寫入逾時只在 Unix;文件沒說支援也沒說不支援 → 【未實測】但它是 Windows 上唯一可能的 Pane 終端機路徑。
- 出處:`herdr:src/client/terminal_sessions.rs:44-339`、`herdr:src/server/headless.rs:1111-1119,1698-1838,2093-2224`、`herdr:src/cli.rs:565-700`、`herdr:docs/persistence-remote.mdx:117-164`、`herdr:docs/windows-beta.mdx:130-140`。

**【推論】對 Drover Chat 的意義**:Pane 終端機可一律用 control(Unix 與 Windows 同一路徑、不需 PTY、resize 是明確 JSON、能拿到 full/增量 frame 資訊、stdin EOF 即乾淨釋放);代價是 base64 + JSON 的頻寬負擔、每則輸入 1MiB 上限、未經 herdrchat 生產驗證。滑動 → `terminal.scroll`(伺服器替我們決定送滾輪、方向鍵或捲主機 scrollback,比手機端自己編碼滾輪更正確);滑鼠點擊 → `terminal.mouse`。登入 Shell 仍需 PTY(exec + pty-req)。

---

## 7. 連線生命週期

### 7.1 連線模型
- **每台主機一條長駐 SSH 連線**,列表、所有對話、追蹤、事件串流、預覽、推播配對、終端機、檔案全部共用;切換畫面不重連(每次呼叫開新連線曾在每次導覽時重連並丟串流,commit 5577c07)。
- **Lazy**:建立 client 不讀 Keychain;第一個指令才讀祕密、pin、passphrase 並握手。
- **同時的多個撥號合併成一個**:所有找不到 client 的呼叫者等同一個進行中的撥號;重設時先把舊 client 從狀態中摘下再關閉;撥號完成時若已有更新的 client 就關掉自己(Swift actor 可重入,曾讓一台主機登入五次、漏掉四個 sshd 程序,#84,commit c11f205)。測試:重設後同時五個指令在主機上只產生一個 SSH 來源埠。
- **失敗的連線不快取**(下一次呼叫重試;常見原因是手機還沒上 tailnet);握手前拋出的任何錯誤也清快取。
- 重用前檢查 client 是否仍連線,否則丟棄重撥。
- **每次撥號用自己的 event loop group,握手或認證失敗時關閉**:Citadel 在失敗時不關 TCP,每次輪詢留下一個未認證連線,sshd 撞到 `MaxStartups` 與每來源懲罰而拒絕手機——恰好在使用者修好問題的時候(commit 72a8f89)。測試:16 次失敗握手後 0 個連線殘留。
- 明確關閉:編輯/刪除主機、儲存、信任新 key 時丟棄並關閉快取的 client;App 結束時取消所有串流、關所有 shell 與連線。
- 主機編輯器的「測試」用獨立暫時連線,測完拆除。
- 出處:`src/state/connections.ts:238-394`、`src/state/sshTransport.ts:21-137`、`modules/herdr-ssh/ios/SshConnection.swift:69-218`。

### 7.2 逾時(每個指令都必須宣告自己的期限)
- 理由:輪詢迴圈在 `finally` 中重新排程;一個永不結束的指令讓迴圈永久停止,畫面凍結在舊資料、沒有任何錯誤,只有強制結束 App 才恢復(commit 1c4e448,#8)。
- 期限在 SSH 層強制;herdrchat 另有晚 5 秒的第二層期限(保證「沒有路徑能卡住畫面」),它永不拋例外,只回傳失敗結果。
- **SSH 層期限到 → 整個 client 丟棄**(超過期限的通道被視為半開 socket 的證據,下一個指令重新撥號);例外:終端機開啟逾時不丟 client。
- **主機端會阻塞等待的指令,我方期限必須比 herdr 的長**(否則正常的「沒到那個狀態」會變成傳輸失敗,或放棄一個即將啟動的 agent 而 fallback 再啟動一個)。
- herdrchat 沒有設 iOS 的連線/握手期限(依賴函式庫預設,未知);Android 有 30 秒整體連線期限(「主機接受 TCP 但永遠不說 SSH 時測試連線會永遠等」,commit 2ef9707)。**Drover Chat 必須設明確的連線與握手期限**。
- 常數見 §12。

### 7.3 什麼永不重試
- **連線層失敗的指令永不自動重送**(主機可能已執行,只是回應遺失)——舊版「重試一次」被移除,因為重試的送出會送兩次(commit 4efe316、7462ab8)。
- 寫入的傳輸逾時 = 「不知道有沒有到」,與 herdr 自己的 `timeout` 區分(#83)。
- socket 失敗不改走 CLI(§3.6)。
- **一個通道失敗不丟整條連線**:只有 client 確實斷線或期限到才丟。OpenSSH `MaxSessions`(預設 10)在健康連線上也會拒絕多餘通道;丟 client 會殺掉所有追蹤與事件串流,它們重開時又要更多通道(commit 32cd86c、5bccff9)。
- 認證類失敗(`auth_failed`、`host_key_changed`、`credentials_missing`、`bad_key`)→ **暫停輪詢**直到使用者下拉、重新載入或編輯主機(OpenSSH `PerSourcePenalties` 懲罰重複失敗登入,commit 2ef9707)。
- 終端機不自動重連;接管不自動;背景/前景切換不重送任何東西。

### 7.4 網路切換
- 監看網路路徑:以「狀態 + 排序後的可用介面類型」做雜湊;改變(Wi-Fi↔行動、Tailscale 上/下)→ 丟棄快取的 client,下一個指令在新路由上撥號;第一次回報只記錄不重設;被丟棄 client 上的 PTY 以「連線中斷」結束(commit 7dd30bd)。
- iOS 端沒有 SSH keepalive(Citadel 不提供);半開 socket 靠期限、喚醒探測與追蹤監看器處理。【swift-nio-ssh 可自行實作 keepalive;Android 版用 20 秒】

### 7.5 背景與前景
- **只在前景且畫面在最上層時輪詢與訂閱事件**;回前景立刻輪詢(背景時 iOS 最先殺長駐 SSH 通道;列表留在被推入的聊天下面時兩個迴圈都在跑,commit 42bdeb7)。
- **喚醒探測**:背景超過 **60 秒**後回前景,先執行一個無害指令(`true`),期限 **3 秒**——掛起期間死掉的連線在 3 秒內逾時並被丟棄,接著的輪詢快速失敗並重撥,而不是各自等 15 秒(commit de1f4ce)。
- 終端機進背景即掛斷(§6.5)。
- 推播:App 在背景時 SSH 會被切斷,「agent 需要你」只能由主機主動通知(ADR-0004、§9);BGAppRefresh 不可靠(常 15 分鐘以上、被滑掉後停止,commit 5ce55fb)。

### 7.6 恢復動作對照(錯誤碼 → 標題/按鈕/動作)

| 狀況 | 使用者看到的意義 | 按鈕 → 動作 |
|---|---|---|
| 認證被拒 | 主機拒絕這組帳密 | 檢視帳密 → 主機編輯器 |
| 祕密不在此裝置 | 還原備份會帶回主機但不帶回密碼/金鑰 | 輸入帳密 → 主機編輯器 |
| 私鑰讀不了 | 貼完整 OpenSSH 私鑰並檢查 passphrase | 檢視私鑰 |
| 連不上 | 確認主機醒著、在 tailnet、位址與埠正確(依原因細分:拒絕連線 → 確認埠與 SSH/遠端登入已開;找不到主機名 → 確認位址與手機在 tailnet;逾時/不可達 → 確認兩邊都在 tailnet) | 檢視主機與埠 |
| herdr 未安裝 | — | 在主機上安裝 herdr(確認後) |
| herdr 路徑是別的程式 | — | 設定 herdr 路徑(不是安裝) |
| herdr 不在 PATH / 不可執行 | — | 設定 herdr 路徑 |
| herdr 沒在跑 | — | 在主機上啟動 herdr |
| host key 改變 | 專屬橫幅(§8.2) | 開主機設定 |
| 其他 | 連線中斷 | 再試一次 |

- 函式庫的內部錯誤字串(EOF、NIO、errno、`Broken transport`…)**不可直接給使用者看**,一律換成一句白話(commit 0c3b333)。
- 出處:`src/lib/connectionRecovery.ts`、`src/lib/herdr/nativeFailure.ts:13-58`、`src/features/chats/useHostRecovery.ts`。

---

## 8. 安全

### 8.1 憑證保存
- 祕密(密碼或私鑰 PEM)、passphrase、host key pin 存 Keychain,依主機 id 分開;可存取等級 **「解鎖時、僅此裝置」**(鎖定時讀不到、不還原到其他裝置)。非祕密欄位存本地資料庫。
- 可存取等級只能在**新增**項目時設定;舊項目以「先寫備份項 → 刪除 → 重新新增 → 刪備份」的崩潰安全順序遷移;遷移寫入失敗**絕不能讓讀取失敗**(曾讓主機全部掛掉,#102)。
- 空 passphrase = 刪除該項目。
- 還原備份後主機在、祕密不在 → 連線前就報專屬錯誤(不要用空密碼登入然後顯示泛用認證錯誤,#98)。
- 刪除主機/清除所有資料時先刪祕密再刪資料列。
- 原生層只在連線生命週期內把憑證留在記憶體。
- 出處:`src/state/connections.ts:53-154`、commit af34289、a02c063、37e51f7。

### 8.2 Host key TOFU
- **指紋**:host 公鑰 **SSH wire 編碼**的 SHA-256,**不補等號**的標準 base64——與 `ssh-keygen -lf` 印出的 `SHA256:` 之後完全相同。存不含前綴、顯示為 `SHA256:<b64>`;比較時去掉補位(遷移舊資料)。Android 曾雜湊 X.509 SPKI,對不上任何東西(commit bb8fe32、0abb422)。
- **政策**:沒有 pin → 接受第一次看到的 key 並持久化;有 pin → 不同的 key 以「host key 改變」拒絕並附上目前出示的指紋;接受過的 key 在原生重連間保留在記憶體(即使還沒存)。
- **空指紋永不儲存**(讀回來等於「沒有 pin」= 永遠 TOFU);連線回報空指紋 → 斷線並報「主機沒有回報指紋,無法確認身分」。
- **編輯器規則**:只有主機或埠改變(或新主機)才重設 pin,改名稱/herdr 路徑/session 不重設(每次儲存都重新 TOFU 是舊 bug);測試連線在端點未變時**強制使用已存 pin**(因為它送出真實憑證,曾以關閉 pin 驗證的方式送出帳密,#36);儲存時,端點改變或沒有 pin 才寫入測試看到的指紋;一旦看到或已有 pin,就以可選取的等寬文字顯示。
- **不符時的 UI**:標題「主機以不同的 key 識別」;說明重灌或重新產生 key 會這樣,攔截連線者也會;「若你沒有重灌或重設這台伺服器,請停下」;顯示「目前出示的 key」與「你存的 key」並教使用者在主機上用 `ssh-keygen -lf` 對照;「信任新 key」→ 破壞性確認 →**只 pin 剛剛出示的那一把**,再重跑測試;**永不清空 pin 然後信任下一個回應者**。聊天列表的 key 改變橫幅只導向編輯器,不能在列表上重新 pin。以錯誤碼辨識,不比對訊息文字(措辭改過一次就壞了,commit 2ef9707)。
- 出處:`modules/herdr-ssh/ios/HostKeyPin.swift`、`SshConnection.swift:266-283`、`src/lib/hostkey.ts`、`src/features/servers/HostKeyPanels.tsx`、`src/features/chats/HostKeyChangedBanner.tsx`。

### 8.3 認證方式
- herdrchat:密碼;OpenSSH 格式私鑰,先試 ed25519 再試 RSA,可帶 passphrase(`ssh-keygen` 預設加密);ECDSA 只有 Android 支援;**沒有** keyboard-interactive、`none`、ssh-agent、憑證、PEM/PKCS#8。私鑰以貼上方式輸入,沒有從檔案匯入。
- **沒有任何 Tailscale SSH check mode 處理**;Tailscale 只出現在文案。
- 【需換做法】Drover Chat:`none`(Tailscale SSH)、密碼、ed25519、ECDSA、Secure Enclave P256(ADR-0003);RSA 要給明確「不支援 RSA,請改用 ed25519」的錯誤;Tailscale check mode 的處理是新工作(§13)。

### 8.4 上傳檔案位置與內容安全
- herdrchat 圖片上傳到 `~/.cache/herdrchat/uploads/`,建立時 umask 077,保留 7 天;一般檔案(Computers 分頁)上傳到使用者瀏覽到的資料夾,**永不覆寫**同名檔;暫存檔為隱藏的點檔。
- 任何內容寫入主機都以 base64 傳遞(防止登入 shell 改寫);回傳路徑要驗證(絕對、以預期檔名結尾)。
- 寫入使用者既有檔案(主題備份、YSK store、Claude 設定)時:跟隨 symlink 寫到真正的檔案旁(macOS 12.3 前沒有 `readlink -f`)、以 checksum 做 compare-and-swap、保留未知內容、每個退出路徑都清暫存檔(fish 吃掉反斜線,commit 71e413a)。
- 【Drover Chat】自訂上傳目錄名(不要用 `herdrchat`);Windows 上位置與權限設定見 §11。
- 診斷資料:永不含主機名、位址、使用者名稱、原始 agent explain(§F15)。
- 隱私:推播中繼不儲存、不記錄(§9.5);**任何改變中繼收到內容的變更都要同一個 commit 更新隱私權政策**。

---

## 9. 推播

### 9.1 herdrchat 架構(參考)
- 手機不監看 agent;主機上一個常駐程序(herdrchat 用 python3 腳本,以 launchd/systemd/nohup 安裝)在 agent 狀態改變時送推播。手機只負責:寫入推播配對資料、可選地安裝監看程序、路由點擊。
- 兩種投遞:經推播中繼(App Store 版唯一可行:APNs 金鑰不能放在使用者主機上);或自簽 App 的人設三個 APNs 環境變數直送 Apple(只設部分 → 報錯,不 fallback;App Store Connect API key 不能簽 APNs)。
- 【需換做法】Drover Chat 用 herdr plugin(主機外掛)取代常駐 watcher(ADR-0004)。下列規則供外掛實作參考。

### 9.2 何時推(轉換規則)
- **權威讀取永遠是 snapshot**(`herdr api snapshot` 的 `agents[]`)。**讀取失敗 ≠ 沒有 agent**:把失敗當空清單會丟掉所有訂閱並重置狀態(commit d6a358c)。
- herdrchat watcher 以 `events.subscribe` 當**喚醒訊號**(不解析事件內容):收到 bytes 後等安靜 0.25 秒再讀 snapshot;串流活著時另有 60 秒安全網讀取;沒有 socket 或訂閱被拒 → 每 3 秒輪詢;pane 集合改變 → 重開訂閱,且重開成功後**立刻讀一次**(讀與訂閱之間的變化不然會遺失)。
- 每個 pane 記住上一輪的 (狀態, `state_change_seq`, `completion_seq`):
  - 狀態不在通知集合(預設 `blocked`、`done`)→ 不推,但更新記憶。
  - **`done` 且 herdr 有給 `completion_seq`**:只在 `completion_seq` 與記憶不同時推——抓得到在兩次讀取之間開始又結束的整輪;還原/啟動落在 done 不推(herdr 不為它們設 completion_seq,herdr#4457,commit 8f29c44)。
  - **否則若現在與記憶都有 `state_change_seq`**:seq 改變就推(兩次讀取之間回答了一個 prompt 又 blocked 在下一個,即使兩次都讀到 `blocked` 也會再推)。
  - 否則:狀態改變就推。
- **播種**:第一次看到非空 agent 清單時只記錄不推。(細節:若啟動時沒有 agent,第一個有 agent 的 snapshot 才是靜默基準。)
- 播種後才出現的 pane 沒有記憶:出現時已是 blocked 或 done(有 completion seq)→ 推。
- 去重:除 0.25 秒安靜期外沒有時間去抖;去重依 pane(記憶/計數器)與依裝置 token(多個配對檔帶同一個 token 只推一次:有連線 id 的檔優先,否則最新的;曾有一台 Mac mini 為同一支手機存了四個檔,每個事件到四次,commit cb633bc)。git 歷史另一條舊規則(BGAppRefresh 時代):同一 (pane, 狀態) 30 分鐘內不重複宣告、一天後清除記錄、多主機基準要合併不可互相覆蓋(commit 579e929、0e44ec2)。
- **主機端不知道手機在做什麼**:不抑制「App 在前景」或「正在看這個聊天」。唯一的每裝置抑制是**靜音**:agent 的 session 值(Claude/Codex/Grok/agy 的 id 或 Pi/OMP journal 路徑)在該裝置的靜音清單 → 跳過該裝置(同主機其他手機照收,commit 13d6826、4237fba)。

### 9.3 推播內容
- agent 顯示名:claude→Claude、codex→Codex、grok→Grok、agy→Antigravity、pi→Pi、omp→OMP,其他用原名。
- **關閉預覽時**:blocked → 標題「<label> 在等你」、內文「<Agent> 在等你的回覆」;done → 「<label> 完成了」、「<Agent> 完成了任務」。
- **開啟預覽(預設)**:
  - 標題 = 聊天標題,若 workspace label 不包含在其中(不分大小寫)則為「label · 聊天標題」;沒有聊天標題就用 label。聊天標題來源:對話紀錄尾端最新的 `custom-title`/`ai-title` entry(`customTitle`/`aiTitle`),否則終端機標題(排除以 `\` 開頭、含 `--resume`、含 UUID 片段、去前導符號後等於 `claude code`/`claude`/`codex`/`omp`/`grok`/`agy` 者;Grok 的「<session> - grok」取前段並去「Action Required」)。
  - blocked 內文:「在等你:<摘要>」,讀不到時「<Agent> 在等你的回覆」;done 內文:<摘要>,否則「<Agent> 完成了任務」。
  - 只讀**由 session id 指名**的對話紀錄(永不「最新檔」;id 須符合 `[0-9A-Za-z-]{8,64}`;路徑規則同 §4,含 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`archived_sessions`、`GROK_HOME`),只讀最後 1MiB、丟掉第一個殘行、從新到舊解析。
  - 「agent 說了什麼」:Claude → 非 sidechain 的 assistant entry,blocked 時若有 `tool_use` 描述最後一個,否則文字;Codex → `task_complete.last_agent_message`,再 `agent_message.message`,blocked 時 `*approval_request` → 「執行:<指令>」或「核准一個變更」;Grok → ACP,blocked 時描述 `tool_call`,否則 `agent_message_chunk` 文字;agy → `PLANNER_RESPONSE`,blocked 時最後一個 `tool_calls`;Pi/OMP → assistant message,blocked 時最後一個 `toolCall`。
  - 工具描述:AskUserQuestion/ask_question → 第一題文字;bash/run_terminal_command/run_command → 「執行:<指令第一行>」;Edit/Write/MultiEdit/NotebookEdit → 「<工具>:<檔名>」;ExitPlanMode → 「檢閱計畫」;其他 → 「使用 <名稱>」。
  - 摘要:去圍欄程式碼、表格行、水平線、開頭 Markdown 記號;段落接到至少 60 字;保留連結文字、去 `**`、`__`、反引號、壓縮空白;截到 200 字,若句尾(「. 」「! 」「? 」)落在上限 1/3 之後就截在句尾,否則在字邊界加「…」。
  - 標題截 120 字、內文截 240 字(中繼限制)。
- **Payload 自訂欄位**(放在 APNs payload 根,與 `aps` 並列):`workspace`(workspace id)、`label`、`session`(agent 的 session 值,有時)、`connection`(該裝置在此主機的連線 id,依裝置)。**不含 pane id**(點了開 workspace 聊天)。
- APNs:`{"aps":{"alert":{"title","body"},"sound":"default"}}`;header `apns-push-type: alert`、`apns-priority: 10`、`apns-expiration` = 現在 + 3600;**沒有** `apns-collapse-id`、`thread-id`、`badge`、category、mutable-content。
- 出處:`scripts/herdr-apns-notifier.py:386-644`。

### 9.4 推播配對(token 檔)
- herdrchat:主機上 `~/.config/herdrchat/apns-tokens/<deviceId>.json`(預設 session)或 `…/sessions/<HERDR_SESSION>/<deviceId>.json`(具名 session;workspace id 依 session 而異,所以每個 session 的 watcher 只讀自己的資料夾;寫具名 session 時順手刪掉舊版留在根資料夾的同名檔)。
- 內容單行 JSON:`{"token":"<hex>","bundleId":"…","env":"production","connection":"<此手機對該主機的連線 id>","muted":["<session 值>",…]}`(Android 另有 `"service":"fcm"`)。`env` 一律 production;`sandbox`/`development` 才走 sandbox。
- 寫入時機與刪除:F14。watcher 每輪重讀 token 檔,所以靜音從下一個推播生效。Apple 回 `Unregistered`、`BadDeviceToken`、`DeviceTokenNotForTopic` → 刪除所有帶該 token 的檔。
- 【需換做法】Drover Chat 的「推播配對」以配對密鑰識別(GLOSSARY.md),一台主機可配多支裝置、一支裝置可配多台主機;配對資料寫在主機外掛可讀的位置,寫入指令需有 Windows 版本。

### 9.5 中繼(herdrchat 的 Cloudflare Worker,參考)
- `GET /` → 服務狀態;其他路徑 404;`/v1/push` 只接受 POST(否則 405);所有回應 JSON + `cache-control: no-store`。
- 請求:POST JSON,欄位 `token`、`env`、`title`(≤120)、`body`(≤240)、`data`(物件)、Android 的 `service`。**沒有認證:持有 device token 即授權**。
- 驗證:body ≤4096 bytes(Content-Length 與實際 UTF-8 長度都檢查,否則 413);非 JSON 400;只允許上述頂層鍵(未知鍵 400);APNs token `^[0-9a-f]{64,200}$`(轉小寫);FCM token `^[A-Za-z0-9_:-]{100,1024}$`;`env` production(預設)或 sandbox;`data` 只允許 `workspace`、`label`、`session`、`connection`,各為 ≤200 字字串。
- 限流(驗證後):每 IP 每 60 秒 120 次,再每 token 每 60 秒 20 次;超過 429。
- APNs:ES256 provider JWT(WebCrypto)快取 50 分鐘;依 env 送到 production 或 sandbox;topic = bundle id;**payload 由中繼自己組**(不透傳)。200 → `{ok:true}`;否則轉傳 Apple 狀態碼與 reason。未設定 → 503。
- FCM:service account 簽 RS256 換 OAuth token(50 分鐘);data-only 訊息(channel `agents`、HIGH、ttl 3600s);錯誤對應到 APNs 詞彙(UNREGISTERED/NOT_FOUND → Unregistered;SENDER_ID_MISMATCH → DeviceTokenNotForTopic;INVALID_ARGUMENT 刻意不對應,可能是訊息而非 token 的問題)。
- 隱私:關閉觀測(無請求記錄、無 trace)、不儲存、只送給本 App;隱私權頁列出:device token、標題、內文、workspace/session/連線 id;關閉預覽則 agent 的字不經過中繼。
- watcher 端:非 200 記錄錯誤(token 只印末 6 碼);不重試、不排隊。
- 出處:`relay/src/relay.ts`、`relay/wrangler.toml:17-31`、`scripts/herdr-apns-notifier.py:233-283`。

### 9.6 以 herdr plugin(主機外掛)實作的要點
- Plugin = 一個資料夾 + `herdr-plugin.toml`(必填 `id`、`name`、`version`、`min_herdr_version`;建議 `platforms`);區段 `[[build]]`、`[[startup]]`、`[[actions]]`、`[[events]]`(`on = "<事件>"`、`command = [argv]`)、`[[panes]]`、`[[link_handlers]]`。command 是 argv,**不經 shell**【herdr:docs/plugins.mdx:55-121】。
- **可掛 hook 的事件**(比可訂閱的少):workspace.created/updated/closed/renamed/moved/reordered/focused、worktree.created/opened/removed、tab.created/closed/renamed/moved/focused、pane.created/closed/focused/moved/exited/agent_detected、**pane.agent_status_changed**【herdr:src/api/schema/events.rs:286-309】。
- **每個事件啟動一個新程序**(`herdr:src/app/api/plugins/runtime.rs:203-252`),環境含 `HERDR_PLUGIN_EVENT` 與 `HERDR_PLUGIN_EVENT_JSON`(序列化的事件 envelope),以及 `HERDR_SOCKET_PATH`、`HERDR_BIN_PATH`、`HERDR_ENV=1`、`HERDR_PLUGIN_ID`、`HERDR_PLUGIN_ROOT`、`HERDR_PLUGIN_CONFIG_DIR`、`HERDR_PLUGIN_STATE_DIR`、`HERDR_PLUGIN_CONTEXT_JSON`、可用時的 `HERDR_WORKSPACE_ID`/`TAB_ID`/`PANE_ID`【herdr:docs/plugins.mdx:265-298】。
- `pane_agent_status_changed` 的事件資料只有 `agent`、`agent_status`、`display_agent`、`pane_id`、`state_labels`、`title`、`workspace_id`【實測 schema】——**沒有** `state_change_seq`/`completion_seq`、session、對話紀錄。要套用 §9.2 的規則,外掛仍須讀 snapshot(`$HERDR_BIN_PATH api snapshot`)。
- 每事件一個程序 → §9.2 的每 pane 記憶必須持久化在 `HERDR_PLUGIN_STATE_DIR`,並處理多個 hook 程序同時跑的競態(檔案鎖或原子替換)。
- Startup hook 在還原後與 live handoff 時跑一次,**不是**受監管的 daemon;plugin 必須在父命令結束前停掉自己脫離的背景程序;伺服器結束後殘存的程序不受保護 → **不建議**在 plugin 裡跑長駐訂閱迴圈,用每事件 hook【herdr:docs/plugins.mdx:205-251】。
- HTTP:herdr 不提供;外掛自己的命令做(curl、node fetch、PowerShell `Invoke-RestMethod`…)。設定(中繼 URL、預覽開關)放 `HERDR_PLUGIN_CONFIG_DIR`,狀態放 `HERDR_PLUGIN_STATE_DIR`;沒有儲存 API。
- 安裝:只能 `herdr plugin install owner/repo[/subdir] [--yes]`(GitHub 簡寫;互動終端機會預覽並確認)或 `herdr plugin link <path>`(不跑 build);`min_herdr_version` 會強制;已安裝的 plugin 對該使用者**所有 herdr session** 生效。【未知:plugin 環境中沒有文件化的 session 名稱變數,`HERDR_SOCKET_PATH` 依 session 不同,可用來區分】
- Windows:plugin 為 **preview**,安裝、link、build、actions、events、panes 皆 best-effort;命令必須是 Windows argv(不能 sh/bash);npm 類 shim 可解析;不支援的 action 回 `platform_unsupported`【herdr:docs/windows-beta.mdx:46、69】。外掛宜以跨平台執行環境撰寫或以 item 層級 `platforms` 提供 PowerShell 版。
- 呼叫 herdr 一律用 `HERDR_BIN_PATH`(在 Unix socket 與 Windows named pipe 間可攜)。

---
## 10. 踩過的雷(規則 + 理由 + 出處,每條應可變成一個測試)

格式:**編號 規則** — 理由 — 出處。來源為 CLAUDE.md、程式註解、commit 訊息與 issue 修正。前文已有細節者此處只列規則本身。

### 10.1 SSH 與連線
- **R-S01 每台主機一條共用連線,換畫面不重連。** — 每次呼叫開連線會在導覽時丟串流、歷史殘缺。— commit 5577c07
- **R-S02 同時撥號合併為一;重設先摘下舊 client;輸掉競爭的撥號自行關閉。** — 一台主機登入五次、漏四個 sshd。— #84、commit c11f205
- **R-S03 連線層失敗的指令永不自動重送。** — 主機可能已執行,重送造成重複 prompt。— commit 4efe316、7462ab8
- **R-S04 單一通道被拒只讓該指令失敗;只有斷線或期限到才丟 client。** — `MaxSessions` 拒絕會連帶殺掉所有追蹤與事件串流。— commit 32cd86c、5bccff9
- **R-S05 每個指令都要有呼叫者宣告的期限;期限到丟棄 client;不重試。** — 永不結束的指令讓輪詢迴圈永久停擺、畫面凍結無錯誤。— #8、commit 1c4e448
- **R-S06 主機端會阻塞的等待,我方期限 > herdr 期限。** — 否則正常的「未到狀態」變傳輸失敗,或 fallback 啟動第二個 agent。— commit 1c4e448、6c382d3、`client.ts:1137-1139`
- **R-S07 網路路徑改變即丟棄快取 client;第一次回報不重設。** — 指令卡在死 socket。— commit 7dd30bd
- **R-S08 背景 ≥60 秒回前景先以 3 秒期限跑無害探測。** — 無 keepalive,第一個輪詢在死 socket 上卡約 20 秒。— commit de1f4ce
- **R-S09 agent working 時追蹤 90 秒無輸出 = 已死,重啟;閒置時不算。** — 主機睡眠後半開 TCP 不報錯。— commit 54532be
- **R-S10 POSIX 指令一律前綴完整 PATH。** — 非互動 shell 不讀 profile;`sh` 使用者連 `ls`/`tail` 都找不到(exit 127)。— commit f54a06d、c265894
- **R-S11 指令字串在 sh/dash/bash/zsh/fish 下都要不變地執行:不用反斜線引號、不用可能空匹配的 glob、一行一敘述、以 `&&` 串接。** — fish 在單引號內處理 `\`;zsh glob 不匹配即中止;`do; [` 是 bash 語法錯誤。— commit 02d6acd、17e2398、269538c、71e413a、79a7405
- **R-S12 exit 0 不足以證明完成;要處理 exit-signal(或用完成標記)。主機腳本不可明確 `exit 0`。** — 被訊號殺掉回報 exit 0,herdr 崩潰看起來像成功。— #103、commit 02d6acd
- **R-S13 以最終(引號化/編碼後)指令長度檢查上限 126KiB,超過以可讀錯誤拒絕。** — 96–120KiB 的 prompt 通過前置檢查卻在主機上失敗。— #105、commit 72b42c3
- **R-S14 herdr 路徑的 `~/` 展開為家目錄,其餘維持引號。** — 引號內 `~` 不展開 → exit 127,診斷又叫使用者設他剛設過的路徑。— #106、commit d15bd13
- **R-S15 依 exit code 判斷,不比對 stderr 文字。** — strerror 在地化,非英文主機壞掉。— #45、commit 1fc9dfa
- **R-S16 對位元組敏感的主機腳本整段在 C locale 執行。** — BSD `cut` 在被切斷的多 byte 字元處停止並回錯 offset。— commit be0d864
- **R-S17 讀 byte 範圍用 seek + `head`/`wc`,不對管線用 `tail`。** — BSD tail 讓每頁 2 秒。— commit d14e4d4
- **R-S18 awk 可攜性:偵測 mawk 才加 `-Winteractive`;不用 `{n}` 區間正規式。** — mawk 緩衝管線輸入,即時追蹤什麼都不印;舊 mawk 不支援區間。— commit bc0afd4、2bdc7f9
- **R-S19 `pipefail` 下提早結束的讀者(`grep -q`、`head`)會讓管線回 141。** — release 守門誤拒兩個好 build。— commit aaf8163、34a1c39
- **R-S20 停止串流必須停止主機上的程序;串流開始時不可送 stdin EOF。** — 被留下的 `tail -f` 在主機跑好幾小時。— #4、commit d711fb1、49463be
- **R-S21 取消串流要能中斷閒置中的讀取。** — 被取代的串流殘留。— commit 7462ab8
- **R-S22 串流只送完整的行(以 `\n` 切分)。** — chunk 邊界切斷 JSON。— commit 6a6dda3
- **R-S23 握手/認證失敗必須關閉其 TCP。測試:16 次失敗後 0 殘留。** — sshd `MaxStartups` 與每來源懲罰拒絕手機。— commit 72a8f89
- **R-S24 認證類失敗暫停輪詢直到使用者動作。** — OpenSSH `PerSourcePenalties`。— commit 2ef9707、f6bc9cf
- **R-S25 主機掛掉時退避(×2,上限 60 秒),成功即重置,使用者下拉清除退避;錯誤橫幅持續顯示。** — 行動網路上每 3 秒一次失敗往返。— #14、commit 42bdeb7
- **R-S26 只輪詢前景且最上層的畫面。** — 列表在聊天下面照樣輪詢,指令數加倍。— commit 42bdeb7
- **R-S27 輪詢倍率只接受提供的選項。** — 存了 0 或 NaN 會讓迴圈空轉。— commit 7a7fdde
- **R-S28 可預期的失敗以資料回傳(碼 + 訊息),由邏輯層解讀(例如 exit 127 → 未安裝),並有測試釘住。** — `CLAUDE.md:52-56`、commit ccac8e5
- **R-S29 開啟失敗不可污染連線快取;認證成功卻沒指紋要連原生 session 一起丟。** — 快取了被拒的 promise,之後每個指令都失敗到重啟為止,且不再驗證 host key。— commit 179a353
- **R-S30 祕密缺失是獨立錯誤,在連線前報。** — 還原備份後用空密碼登入顯示泛用錯誤。— #98、commit 37e51f7
- **R-S31 祕密以「解鎖時、僅此裝置」存;遷移以重新新增進行;遷移寫入失敗不能讓讀取失敗。** — #102、commit af34289、a02c063
- **R-S32 儲存主機失敗要留在編輯器說明原因。** — Keychain -34018 讓「儲存」沒反應。— commit d692c1e
- **R-S33 支援加密私鑰的 passphrase。** — `ssh-keygen` 預設加密,UI 叫人檢查 passphrase 卻沒有欄位。— commit 15c5b5d
- **R-S34 函式庫錯誤一律換成一句白話,保留錯誤碼。** — 「Broken transport; encountered EOF」給到使用者。— commit 0c3b333、2ef9707
- **R-S35 SSH 相依以 commit 釘死,不用版本範圍。** — 每次 prebuild 重新解析範圍,新 tag 可在 repo 無 diff 時改變出貨的 SSH 程式碼。— #194、commit 4ae4c24
- **R-S36 必須設明確連線/握手期限。** — 接受 TCP 但不說 SSH 的主機讓測試永遠等。— commit 2ef9707(Android)

### 10.2 Host key
- **R-K01 首次 TOFU,之後不同的 key 拒絕。** — commit 4efe316
- **R-K02 指紋 = wire blob 的 SHA-256、不補等號 base64,與 `ssh-keygen -lf` 相同且可檢視。** — commit bb8fe32、0abb422
- **R-K03 測試連線強制已存 pin,並記錄出示的指紋供儲存。** — 帳密曾經過未驗證連線送出。— #36、commit af34289
- **R-K04 儲存只在主機或埠改變時重設 pin。** — 每次儲存都默默重新 TOFU。— commit af34289
- **R-K05 空指紋是錯誤,永不儲存。** — commit bb8fe32、3cf3115
- **R-K06 重新信任只 pin 剛出示的那把;以錯誤碼辨識 key 改變;列表橫幅只導向編輯器。** — 重新信任曾讓主機變成未 pin;措辭變動讓文字比對失效。— commit 179a353、2ef9707、bb8fe32

### 10.3 herdr 協定與版本
- **R-H01 只列 herdr 認得的事件型別;版面事件只在需要時加。** — 一個未知型別讓整個訂閱被拒,App Store 版永遠沒有即時事件。— #75、commit f971a4b、2ecff2f
- **R-H02 訂閱 pane 集合改變要重開;順序不同不重開;重連 1→30 秒倍增。** — commit 50d72f0
- **R-H03 串流開始與 `events_lost` 時全量重讀。** — 事件不重播。— #94、commit 2012a87
- **R-H04 被接受前就結束的串流算失敗並退避。** — 每秒重連一次,每次一個通道與主機程序。— #104、commit e2dac36
- **R-H05 事件「踢」輪詢時去抖 250ms;進行中被踢就完成後再跑一次。** — 事件被丟,「需要你」延遲 30 秒。— #88、commit 4de60e0
- **R-H06 事件只刷新它指名的 pane;版面事件不讀對話紀錄。** — 拖動調整大小每步一個事件。— commit 0f609c2、2ecff2f
- **R-H07 以 `state_change_seq`/`completion_seq` 偵測轉換,不只比對狀態。** — 兩次輪詢之間開始又結束的一輪被漏掉。— #115、commit 8f29c44
- **R-H08 `input_pending` 且非 working 視為 blocked。** — 信任選單被 herdr 稱為 idle,永遠不出現在「需要你」。— commit 4abefa0
- **R-H09 版本以數值比較;不明版本走安全路徑。** — `0.10.0` < `0.8.0`。— commit dce258c
- **R-H10 snapshot 缺 `workspaces` ≠ 空。** — commit 5927179
- **R-H11 先讀錯誤 envelope 再看 exit code;不給使用者看原始 JSON;已知碼改寫成手機適用的話,未知碼保留原文。** — commit af880f9、6ab2f23
- **R-H12 exit 127 先診斷再建議;只有真的沒有才提供安裝;使用者已填路徑時不叫他改 PATH。** — commit d1b984e、722d2ec
- **R-H13 herdr 路徑指到 Herdr Desktop 的 `herdr-core`(用法錯誤)→「路徑跑的是別的程式」,恢復動作是改路徑。** — #196、commit bc20877
- **R-H14 安裝 herdr 只在確認後,顯示精確指令與主機。** — commit dd0bf2e、8d26f92、bb8fe32
- **R-H15 「啟動 herdr」執行無頭伺服器並輪詢確認;按兩次安全;永不跑裸 `herdr`。** — commit 902f1a3、2ef9707
- **R-H16 具名 session 綁在傳輸層(含連線測試)。** — 測試曾回報預設 session。— commit eed385a、d711fb1
- **R-H17 integration 安裝輸出是純文字;非零 exit 才失敗。** — commit bacb560
- **R-H18 過期 integration 是建議不是錯誤。** — commit b08d514
- **R-H19 「更新 herdr」= `update --handoff` + 必要時 `server.live_handoff`。** — 單純 update 讓伺服器留在舊版,警告在使用者照做後仍在。— commit a5bed77
- **R-H20 顯示 pane 的 `restore_error`。** — commit f0bb92d
- **R-H21 診斷中的 agent explain 縮成白名單、3 秒上限。** — 原始輸出 7.2KB,含使用者名稱與畫面片段。— commit 179a353
- **R-H22 在場回報 seq 以時鐘起算、單調。** — herdr 忽略不大於上次的 seq,即使過了 TTL。— commit ca94901
- **R-H23 以上游穩定版 herdr 測試,不用 fork。** — fork 才有的 `pane.turn_completed`、`delivery` 欄位被出貨。— #85、commit a177484
- **R-H24 remote-api-bridge 的 stdin 必須保持開啟直到讀到回應。** — stdin EOF = client 離開;等待型請求無輸出且 exit 0。— commit e51514d(#116)、【實測】
- **R-H25 探測結果只在主機有回答時快取;snapshot 回報的版本優先於探測。** — 一次網路失敗讓主機終生被降級。— #42、commit 6ab2f23

### 10.4 送出 prompt
- **R-P01 `agent.prompt` 等待 `until: [working, blocked]`、≥5000ms;我方期限更長。** — commit eed385a、6c382d3、f7829d3
- **R-P02 上游成功回應即「已送達」(沒有 `submitted` 欄位不代表未驗證)。** — 上游每次都被當成未驗證、走補 Enter 路徑。— #76、commit af647a6
- **R-P03 補 Enter 只在新鮮讀到 idle/done 時;永不對 blocked 補 Enter。** — 補 Enter 批准了沒人看過的工具呼叫。— #76、commit af647a6、f50caab
- **R-P04 socket 拒絕不改走 CLI 重試(唯一例外:unknown method)。** — commit f7829d3
- **R-P05 傳輸逾時 ≠ 停滯:等 8 秒回執,沒有就說「可能已到」,不盲目重試。** — 「再試一次」送了兩次。— #83、commit 1680a20
- **R-P06 送出當下以新鮮 snapshot 重選目標 pane。** — 2 秒前的 pane id 可能已過時。— #22、commit f7d1ab2
- **R-P07 送給聊天顯示其對話紀錄的那個 agent(可讀者優先、聚焦優先)。** — 桌機聚焦 opencode 時手機訊息被送走,回音永遠不確認。— commit fb6655d
- **R-P08 回音只能被送出後更新的使用者行確認;key = 文字 + 圖片數。** — 第二個相同訊息在送出前就消失;純圖片訊息被任意 tool result 確認。— commit a9fc979、0331523、c804b68
- **R-P09 Codex 只以對話紀錄確認,永不重送。** — commit 0331523
- **R-P10 被拒的送出保留草稿;重試同時只能一個。** — #100、commit be97ee4
- **R-P11 錯誤有三個擁有者(輪詢/動作/追蹤),各自清除;輪詢成功不清動作警告。** — 送出警告 2 秒就消失,誘發重送。— #82、commit 7beeec5、e0bd166
- **R-P12 排隊中的 prompt 以 `queued_command` attachment 確認;解開 `<pasted_content>`。** — #77、#79、commit 72f13e6
- **R-P13 停止 = 一個 Esc + 3 秒內確認離開 working;Ctrl-C 要確認;目標是 working 的 pane,不是 blocked 的。** — 第二個 Esc 開回溯選單;主機會收下不認得的鍵名當文字。— commit e7acb7f、6e863a3
- **R-P14 使用 herdr 的鍵名語法。** — `C-a` 這類 tmux 寫法曾被拒。— commit ab76376
- **R-P15 Slash 指令不等待、不補 Enter,以面板/對話紀錄/agent 反應確認。** — `/model` 永遠不 working;補的 Enter 選到面板某列。— commit b561d39、a514193、8a189af

### 10.5 Session 身分與對話紀錄
- **R-I01 聊天身分 = session 簽章;每個快取帶簽章,改變即丟。** — herdr 回收 workspace/pane id,新聊天顯示舊對話。— `CLAUDE.md:57-61`、commit f4506d7
- **R-I02 永不猜對話紀錄檔;沒 session id 就等。** — 「最新 .jsonl」預覽到別人的 session(兩個聊天同資料夾)。— `CLAUDE.md:63-69`、commit eb5421d
- **R-I03 即時追蹤以 session 為 key,永不以 cwd。** — 同資料夾兩個 agent 撞成一個,第二個永遠不串流。— `CLAUDE.md:79-81`
- **R-I04 列表預覽帶讀取時的簽章,依 pane 存放;pane 離開或 session 改變即丟。** — 回收 slot 顯示舊聊天最後一行約 48 秒。— #86、commit 214489b、1e123d8
- **R-I05 未讀是推導值;沒有時間戳的預覽不算未讀。** — 漏清的旗標留下永遠清不掉的點。— commit 4eaaf0c
- **R-I06 workspace 在開著的對話下被重建 → 解除綁定、暫停送出;同 session 換 pane 保留。** — 回覆送進別的 agent。— #87、commit 5a562d9
- **R-I07 關閉 workspace 刪除 `w` 與 `w/…` 的所有本地資料(精確前綴,不用 LIKE)。** — commit bc08cbf、dea8024
- **R-I08 80 秒才判定 integration 缺少;已知缺少則立刻;問題開著時暫停計時。** — 新 Claude 約 48 秒才回報。— commit 9cee0bf、4abefa0
- **R-I09 新 Claude session 在第一個 prompt 前可能沒有檔案 → 顯示可用的空聊天,不是錯誤。** — commit b30f895
- **R-I10 探測分四步,只有「檔案/資料夾不存在」是缺席。** — 權限錯誤被當缺席,對話永遠等。第三次混淆這兩者。— #23、#46、commit f257ad6、324430e
- **R-I11 精確移植 Claude 的資料夾名規則、尊重 `CLAUDE_CONFIG_DIR`、worktree 以精確 id 搜尋。** — #89、commit 1b04239
- **R-I12 id 與路徑在進入 shell 前驗證。** — commit ccac8e5、527f51b、6b6a6cd
- **R-I13 家目錄依連線快取 promise,失敗即逐出。** — #52、commit 9c0d8a3
- **R-I14 Claude:每個 content block 一個片段;沒 `uuid` 用確定性雜湊;解析器版本入快取戳。** — commit 7c63540、9c8fa4d、10b7fe8
- **R-I15 Claude harness 行隱藏;`<synthetic>` 不設 header;任務通知只從 harness 行解析。** — #78、#80、commit 10b7fe8
- **R-I16 Codex 只渲染 `response_item`;cached tokens 不重加;倒帶只靠狀態資料庫;`.zst` 是「讀不了」不是「不在」。** — commit 80aa111、187a16c、ac78f62
- **R-I17 agy 輸出配給前一個 step 的呼叫,不依順序。** — 被中斷的呼叫讓之後全部配錯。— commit 600d7d9
- **R-I18 Pi/OMP 中斷輪次的零 usage 不算 context;模型名去 provider 前綴。** — commit 2b77fdd、fac120f、4237fba

### 10.6 增量讀取
- **R-B01 游標是 UTF-8 byte。** — UTF-16 長度在 emoji 上漂移、默默跳訊息。— `CLAUDE.md:111-112`
- **R-B02 有損解碼後以探測大小為準,不以解碼長度加總。** — #37、commit badf15a
- **R-B03 在主機回報的行開頭恢復;問不到才回退 4KB 並去重。** — 固定回退落在字元中間。— #109、commit a25795a
- **R-B04 開啟讀最後 N 行(不是 byte),主機上剝除圖片 base64。** — 1MB 圖片行讓 byte 視窗只有 8–25 列;重播整個積壓要好幾分鐘。— #66、commit a3105cb、d14e4d4
- **R-B05 往上翻用 byte 錨定頁,超長單行要問主機行開頭;不寫入快取;session 改變後到的頁丟棄。測試:200 輪對話翻到頂,每輪恰好一次。** — #81、commit 34a1c39、3fa42b8、21912f9
- **R-B06 即時追蹤在主機剝圖並回報每行原始 byte 長度。** — commit 2bdc7f9
- **R-B07 每個追蹤有世代計數,丟棄被取代者的晚到 chunk;啟動追蹤是加法,不拆健康的兄弟。** — 全域柵欄讓活著的對話靜音。— commit 8caa931、af0ee1c
- **R-B08 重開時 ≤64KB 且單一來源才從游標串流,否則讀新視窗。** — commit 0e9c28f、f50caab
- **R-B09 追蹤重啟延續視窗;只有真正的斷層才重建列表。** — 重建把讀者丟到底。— commit a535a0f
- **R-B10 缺席的兄弟檔以 5→60 秒退避重試(有其他追蹤活著時)。** — #99、commit 70ff022
- **R-B11 追蹤斷掉先靜默重啟一次,第二次才顯示橫幅。** — 每次解鎖都顯示 30 秒「更新暫停」。— commit 6b93fae
- **R-B12 追蹤行以 100ms 批次;訊息先寫、游標後寫;被取代者的批次不寫。** — commit fc3f274、f50caab
- **R-B13 快取交易串行;序號在交易內讀;每聊天最多 500 則;清訊息同時清游標。** — #92、commit 5f599ea、fe8d12e、0bf2930
- **R-B14 header 中繼資料取自已串流的行,開啟時一次初值;預覽與 header 讀取先剝圖再截。** — commit 54532be、bc6ff87
- **R-B15 重新載入清記憶體與磁碟中的歷史與游標並重新錨定。** — commit 6127015、ca9eb07、a243144
- **R-B16 離線時唯讀顯示已存歷史,只在快取屬於列表看到的 session 時。** — #97、commit 5c60196、589675a

### 10.7 圖片
- **R-U01 圖片縮到 2048px JPEG、base64 分段寫到上傳資料夾、保留一週、路徑各占一行、最多 4 張;上傳失敗整則不送並保留草稿與圖片;重試沿用已上傳路徑。** — commit c804b68、71e413a
- **R-U02 去除圖片參照後必須剛好剩下使用者打的字。** — 否則回音永不確認,泡泡顯示「送出失敗」。— `CLAUDE.md:83-89`
- **R-U03 每個 URI 記住圖片比例。** — commit 08358da
- **R-U04 任何內容寫入主機都以 base64;寫既有檔案跟隨 symlink、清暫存檔。** — fish 吃反斜線;symlink 的 dotfile 被換成一般檔。— commit 71e413a、7e2f992

### 10.8 Blocked
- **R-Q01 讀 visible 畫面(alternate screen 的 scrollback 是空的)。** — commit 8685335
- **R-Q02 選單解析:縮排行屬於上一個選項;多選 + 繼續(Right);辨識 `›`;去快捷鍵字母;Grok 列;截側邊面板;接回 agy 折行。** — #107、commit 1bef1d1、8e12808、a9df91c
- **R-Q03 Claude/Grok/agy 只送數字;Codex 數字 + Enter。** — 多餘 Enter 回答了下一題。— #107、commit 1bef1d1
- **R-Q04 10 以上的選項顯示但停用。** — 「10」選了 1 又送出雜訊「0」。— #53、commit 628eb9d
- **R-Q05 回答進行中鎖住選項,以 送達/被取代/逾時/等待 判定;逾時 max(12 秒, 3 × 輪詢間隔);簽章含完整內容與勾選、不含倒數。** — 連點送出第二個答案;慢輪詢設定下好答案被判逾時。— #38、#47、commit 82e9bd1、934da83、4231c49
- **R-Q06 權限細節只從提示自己的分隔線讀;開頭不在畫面就說明;期限不在手機倒數。** — commit 3405b1a、0e78357、2c181f2、a864a84
- **R-Q07 資料夾信任用方向鍵 + Enter(游標起在 No, exit)。** — 單按 Enter 關掉 Claude。— commit 4abefa0、421195d
- **R-Q08 Codex `@` 檔案選擇器只給 Esc。** — #120、commit a956a55
- **R-Q09 blocked 時維持快速輪詢;回答後 0.4 秒與 1.2 秒再看。** — 下一題 30 秒看不到。— commit ab62529
- **R-Q10 只有一份去 ANSI 實作且含 ESC 與 OSC。** — 漏 ESC 吃掉 `[TODO]` 與連結括號。— #12、commit 69e2282
- **R-Q11 即時預覽:錨定 spinner、`⎿` 是工具、一長串 chrome 規則、沒有真散文就不顯示。** — commit b4453ad、f5310de、4381424、20010d3、ead0442、9689320、bfa4fd0

### 10.9 Slash 指令、subagent、workflow
- **R-C01 指令發現有界、排程、不等待、每連線一個;不在開聊天時阻塞。** — 第一版讓新聊天失敗被 revert。— commit b704ec8、df3e4d3、220714f、5121845
- **R-C02 內建指令只在執行檔路徑/大小/mtime 改變時重新掃;失敗 6 小時不重試。** — commit df3e4d3、391a687
- **R-C03 frontmatter 描述要處理 YAML block scalar;plugin 命名空間取自 manifest。** — commit b561d39、ab76376
- **R-C04 面板以游標鍵操作,永不數字。** — 數字在模型選擇器直接存成預設。— `paneOverlay.ts:19-23`
- **R-C05 有副作用的指令只填入不送出。** — commit 391a687、5121845、decfbd9
- **R-C06 header 立即反映 `/model`、`/effort`。** — commit 8a189af
- **R-C07 `!` 行只和同一對話紀錄相鄰行配對;輸出解跳脫一次、`&amp;` 最後;回執兩端修剪。** — commit b80c333、2cee5e8
- **R-W01 委派狀態取自之後的通知,不取啟動結果。** — 背景 agent 卡全部立刻顯示完成。— commit 17e2398、1f1548f
- **R-W02 以 meta 的 `toolUseId` 找 subagent 檔,永不最新檔;用 find 不用 glob。** — commit 17e2398
- **R-W03 workflow 執行中讀 journal;checksum 變才重讀;30 分鐘無變化停止;跟隨 App 輪詢閘門。** — commit 1f1548f、7894f8b
- **R-W04 開著的 subagent 畫面自己偵測結束。** — 父聊天被蓋住時停止輪詢。— commit 1f1548f
- **R-W05 背景 agents 列:working 後第一次閒置再讀;有執行中列維持快速輪詢;全部完成且無隱藏才說完成。** — commit e0d34ce、0a3b0d7、dc5de60

### 10.10 列表、導覽、UI
- **R-L01 預覽一次往返批次、每次呼叫隨機分隔標記、每第 5 次全掃。** — 固定標記撞到內容。— commit 1e46998、1fc9dfa
- **R-L02 標題優先序與預設標題黑名單。** — 每個新聊天看起來都一樣。— commit 8d224ae、0671dd8、0ecc085
- **R-L03 無法連線的主機不是空主機;空畫面可下拉;4 秒後提示 Tailscale/睡眠。** — #96、commit 8de963a、3cb2e87
- **R-L04 刪除選取主機時改選並持久化;每主機設定一起刪。** — #90、commit 5406d48
- **R-L05 回收的滑動列瞬間歸位。** — commit 41c87c2、902f1a3
- **R-L06 列的身分含主機 id。** — `w1` 在每台主機都有。— `listedChat.ts:4-12`
- **R-L07 後到的橫幅放在列下方。** — 頂端插入讓使用者點錯。— `ChatsList.tsx:406-409`
- **R-L08 搜尋同時比對 agent 顯示名與 herdr id。** — commit 1e272c0
- **R-L09 空間卡統計把不可讀的 agent 也算 agent。** — commit 365a285
- **R-L10 徽章數 workspace、排除畫面上的;只在 >0 畫。** — commit 8943d61、2cba57f
- **R-L11 程序名一次批次、不等待、快取「無名稱」。** — commit 5bccff9、72f1012
- **R-L12 未變的列/agent/問題/訊息切片保持物件身分。** — 每次輪詢重繪所有可見列。— commit 1f14ba1、6109740、e38c4a5
- **R-L13 iPad 列表重用開著聊天的近期 snapshot。** — commit 3d9c9dc
- **R-N01 從 modal 交回值用共享狀態,不用路由參數。** — `CLAUDE.md:122-125`
- **R-N02 不在關 sheet 的同一 tick push;由根畫面下次取得焦點時開。** — commit 295d67f
- **R-N03 手機開聊天先 dismiss 到根再 push;回聊天用 dismiss-to-root 不用 navigate-to-root。** — push 落在 modal 下面;navigate 疊出第二個列表。— commit 8c97cce、5814a9f
- **R-N04 根堆疊錨定在分頁上(冷連結到設定也有地方回去)。** — commit 5814a9f
- **R-N05 通知點擊:以 request id 去重、等主機載入、驗證 session、路由到發送主機。** — #50、#62、#91、commit 7a70dec、14de072、d104acb
- **R-V01 只有使用者自己的捲動改變跟隨/閱讀模式。** — commit a535a0f、30a9817
- **R-V02 工具串列 key 用最後一個項目。** — commit d14e4d4
- **R-V03 Markdown:圍欄規則、成對括號、只開 http(s)、識別字底線、粗體中的 code、表格對齊、行內 code 無底色。** — #108、HC-111、HC-117、commit 2c38fd9、3e58d0b、2e9f584
- **R-V04 空的程式碼區塊不提供複製。** — 會清空剪貼簿。— commit 545a80c、3d75f40
- **R-V05 context 只顯示 token 數,不顯示百分比,0 不顯示。** — 對話紀錄沒記 context 視窗大小。— commit fd40f08、0ac4730
- **R-V06 長按用原生手勢,不用會吃觸控的元件。** — 表格與程式碼無法橫捲。— commit 7d4a699
- **R-V07 軟體 Return 永遠換行;硬體 Return 送出(可設定);Cmd-Return 永遠送;組字中不攔截。** — 手機送出寫一半的 prompt。— #155、commit e4b174e
- **R-V08 程式改寫草稿時追蹤游標。** — commit f90546b
- **R-V09 只有剪貼簿是單純圖片時 Cmd-V 才當附件。** — 文字貼上觸發「允許貼上」。— commit f90546b
- **R-V10 thread 標題永不是 raw id。** — #113、commit 2b8e0fb
- **R-V11 主機不在了不顯示輸入框。** — commit c565626

### 10.11 終端機
- **R-T01 終端機模擬器版本釘死。** — 新版加入的 build plugin 讓命令列 build 失敗。— `modules/herdr-terminal/README.md`、commit 8f08922
- **R-T02 Exit status 在讀取迴圈中取得。** — 關閉時拋錯蓋掉真正 status。— commit 8f08922
- **R-T03 Agent pane 用 `agent attach`、shell pane 用 `terminal attach <terminal_id>`;永不 zoom + session attach。** — 共享狀態移動桌機。— commit 269538c、dede6a7
- **R-T04 只有使用者按「接管」才加 `--takeover`。** — commit dede6a7
- **R-T05 背景即掛斷不自動重連;resize 去抖 250ms。** — commit fc77291
- **R-T06 開啟前到達的結束事件要保留;開啟中離開要在開好時掛斷。** — commit fb1f2f1
- **R-T07 程式持有滑鼠時滑動 = 滾輪事件;接受觸控板間接捲動;移除拖曳手勢。** — commit d510778、8b4c532
- **R-T08 OSC 52 寫可、讀拒;只開 http(s) 連結。** — `modules/herdr-terminal/README.md`
- **R-T09 iPad 開好後終端機取得焦點。** — 硬體 Ctrl-C 沒反應直到點一下。— commit fb1f2f1
- **R-T10 無法建構指令時不提供重新連線。** — commit 77f2ee9

### 10.12 推播
- **R-N1 推播必須來自主機(APNs);BGAppRefresh 不可靠。** — commit 5ce55fb、27f9e8e
- **R-N2 每 pane 基準合併不覆蓋;同 (pane, 狀態) 30 分鐘不重複;一天後清;第一輪靜默播種。** — 兩台主機互相清掉基準,無限重複「完成」。— commit 579e929、0e44ec2
- **R-N3 前景時呈現通知(除了正開著的聊天)。** — iOS 前景時預設丟掉通知。— commit ccae39f、b424316
- **R-N4 裝置 id 只產生一次並持久化;啟動與輪替時對所有主機上傳;關閉時刪掉本裝置的檔。** — #39、commit b424316、e6cd54c
- **R-N5 只在使用者打開通知時請求權限。** — 還原的設定在沒被問的情況下跳框。— #51、commit e6cd54c
- **R-N6 中繼自己組 payload、不存不記錄、內文 ≤240;關預覽則不送 agent 的字;中繼收到的內容改變要同 commit 改隱私權政策。** — commit 7d472d0、04a920b、5ea04c2、`CLAUDE.md:187-189`
- **R-N7 每個 device token 只推一次;靜音在主機端每裝置生效;用 `completion_seq`;讀取失敗不等於空清單。** — commit cb633bc、13d6826、8f29c44、d6a358c
- **R-N8 移除主機不等待配對清理;清除全部最多 4 秒。** — #49、commit f9c5f78、5406d48
- **R-N9 Demo 永不註冊推播。** — commit 1db179a
- **R-N10 監看程序每次變更要升版號,合併後重新編號。** — 兩個分支都出「8」,主機卡在錯的腳本。— commit 4ec79a1、0ec83f2
- **R-N11 延後啟動的訂閱成功後立刻讀一次。** — commit d6a358c
- **R-N12 出貨 build 用 production APNs 環境並驗證簽章後的 entitlement。** — development token 在 production 被拒(BadDeviceToken)。— commit b926433

### 10.13 iOS、App Store、效能
- **R-O01 必須採用 scene 生命週期。** — iOS 27 SDK 下會 crash。— commit 8d8191f
- **R-O02 鍵盤:列表隨鍵盤縮、輸入框在鍵盤邊緣、iPad 浮動輔助列空隙、sheet 頁尾以鍵盤自身高度抬升。** — commit 15d4a93、156b76d、413536c、b51ef21、488d557
- **R-O03 外觀選擇推到原生層。** — 白閃、淺色 App 配深色 tab bar。— commit 40038e5、9dc7ef5、54257b4
- **R-O04 Liquid Glass 先偵測 API 是否存在;永不以透明度淡出玻璃。** — 某些 iOS 26 build 會 crash;透明度 0 關掉效果。— `CLAUDE.md:114-117`、commit f5310de、622ec65
- **R-O05 行高隨動態字級縮放(不要重複乘);空狀態可捲;大字級改直排。** — commit f40779e、e69bbdf
- **R-O06 匯出合規:`ITSAppUsesNonExemptEncryption = NO`(標準 SSH 加密)。** — commit 4b3dfc5
- **R-O07 內建 Demo 主機,沒有主機時自動選取;審核說明要與 build 內容一致。** — build 51 被退件。— commit 83553cd、51af0a6、970eaf5
- **R-O08 隱私權政策要與實際行為一致(含網站分析與中繼)。** — commit 2db8663、c40fd24
- **R-O09 build 號必須真的遞增;已核准的 marketing version 其 train 已關閉。** — commit 579e929、10350fd
- **R-F01 每個開著的聊天的指令預算:working ≤60/分、閒置無事件 ≤30/分、閒置有事件 ≤2/分。** — commit 1f14ba1、40cef1f
- **R-F02 每次輪詢最多讀一次畫面,供 blocked、預覽、面板共用。** — commit b561d39、0a3b0d7
- **R-F03 主機主題只讀一般檔案、≤64KB、以 checksum 偵測變動、JSON 巢狀上限 64。** — FIFO 與 `/dev/zero` 讓 SSH 讀取卡死。— commit c2538ef、2b100eb

---

## 11. 因約束必須換做法的地方

### 11.1 總表

| herdrchat 的做法 | 衝突的約束 | Drover Chat 需要的做法 |
|---|---|---|
| python3 bridge 為主要 socket 通道(含長駐多工 bridge) | 零安裝、不用 python3 | 只用 `herdr remote-api-bridge`;每請求一個 exec,stdin 保持開啟直到讀到回應(§3.3);以批次/限流控制通道數 |
| `remote-api-bridge` 以 FIFO + sleep 保持 stdin | swift-nio-ssh 可直接保持 exec stdin | 不需 FIFO;**也因此 Windows 可用**(FIFO 是 POSIX 專屬) |
| 沒有 bridge 時退回 CLI 輪詢(Windows 一律如此) | — | 0.9.5 一律有 bridge;Windows 需實測(§13) |
| Citadel:PTY 只能配 shell,打字 exec + marker 過濾 | swift-nio-ssh | exec + pty-req;或 Pane 終端機改用 `terminal session control`(無 PTY) |
| `herdr agent/terminal attach`(需 TTY) | Windows 不支援 direct attach | Windows 的 Pane 終端機用 `terminal session control`(未實測);建議全平台統一 |
| RSA 金鑰 | swift-nio-ssh 無 RSA | 偵測並明確說明不支援,引導改 ed25519;支援 ECDSA、Secure Enclave |
| 沒有 `none` 認證、沒有 Tailscale check mode 處理 | Tailscale SSH 連線方式 | 實作 `none`;處理 check mode(顯示驗證網址、開瀏覽器、等待) |
| 圖片/檔案以 base64 拼進指令參數分段(每段 96KiB),以 `printf >>` 附加、`base64 -d`/`-D` 解碼 | 無 SFTP(相同);Windows 無這些工具 | 改以 exec 的 **stdin** 傳 bytes(ADR-0003):POSIX 由 `cat >` 或 `head -c N >` 接收;Windows 由 PowerShell 讀 stdin 寫檔;仍需驗證大小、權限、不覆寫 |
| 所有主機腳本是 POSIX sh(`tail -f`、`dd`、`head`、`wc`、`sed -E`、`awk`、`grep -a -b`、`cut`、`find`、`cksum`、`stat`、`pgrep`、`base64`、`mktemp`、`readlink`…) | Windows cmd/PowerShell | 每個主機操作需要兩種方言(POSIX sh、PowerShell);§11.2 |
| 串流的「通道關閉即殺子程序」以 stdin 看門程序 + `pgrep -P` 實作 | Windows | PowerShell 中以讀 `[Console]::In` 至 EOF 後 `Stop-Process`;或選擇本身在 stdin EOF 時就結束的命令(`terminal session control` 天生如此) |
| 對話紀錄即時追蹤在主機用 awk 剝圖並回報每行 byte 長度 | Windows 無 awk | PowerShell 以 FileStream seek/讀取 + 輪詢檔案成長實作 follow;剝圖可在主機(PowerShell 正規式)或在手機端(代價是頻寬) |
| Codex 啟動器(bash + python3,裝到 `~/.local/bin` 的 `codex` 與另一個指令) | 零安裝、無 python3 | 不安裝;herdr 0.9.5 的 Codex integration v5 是否在共用 app server 下仍能回報 session 需實測(§13);若不能,說明限制 |
| Claude 用量:改寫 `~/.claude/settings.json` 的 status line 並安裝包裝腳本 | 零安裝 | 需要人類決策(§13):保留(視為使用者同意的設定變更)或改由主機外掛提供 |
| You-should-know:寫回 Claude plugin 的 store | 「零安裝」不禁止寫使用者資料,但需 Windows 版 compare-and-swap | 保留行為,兩種方言實作 |
| 主機主題:讀 `~/.herdrchat/theme.json`,按鈕時寫參考檔 | 品牌/路徑 | 改用自己的目錄名;是否相容 herdrchat 的檔案位置需決策 |
| 推播:python watcher 常駐服務(launchd/systemd/nohup) | 零安裝(推播例外為主機外掛) | herdr plugin 每事件 hook + 自營中繼;外掛需要 runtime(bash/node/PowerShell);Windows plugin 為 preview |
| 中繼無認證(token 即授權) | 推播配對以密鑰識別 | 中繼驗證配對密鑰(設計待定) |
| `herdr update --handoff`/`server.live_handoff` | Windows 不支援 live handoff | Windows 上只能提示使用者在主機重啟 herdr |
| 安裝 herdr:`curl … \| sh` | Windows | Windows 需 herdr 的 PowerShell 安裝方式(herdrchat 沒有;需查 herdr 官方) |
| 完成標記(因 Citadel 忽略 exit-signal) | swift-nio-ssh 會遞送 exit-signal | 直接處理 exit-status/exit-signal;是否仍保留標記作雙保險可選(在 Windows 方言下標記也要有對應寫法) |
| 單一 exec 內批次多個 bridge 請求(以 sh 框住) | Windows | PowerShell 版本的批次;或限制並行通道數 |
| 登入 Shell:`exec "${SHELL:-/bin/sh}" -l` | Windows | 開 PTY 時不送 exec(用 `shell` 請求取得使用者預設 shell),或明確啟動 `pwsh`/`powershell`/`cmd` |
| 檔案路徑一律以 `/` 開頭驗證 | Windows 路徑是 `C:\…` | 依主機 OS 驗證 |

### 11.2 Unix 依賴與 Windows 對應(依功能)

| 功能 | POSIX 依賴 | Windows 要達成同一行為需要 |
|---|---|---|
| 指令外殼 | `export PATH=…`、`export HERDR_SESSION=…`、單引號引號化 | `$env:PATH`、`$env:HERDR_SESSION`;整段包成 `-EncodedCommand`;PowerShell 引號規則(`'` 寫成 `''`) |
| 家目錄 | `$HOME`、`~` | `$env:USERPROFILE`;注意中文/韓文等非 ASCII 使用者名稱(herdr 0.9.5 修過 Windows 上 Claude session 追蹤在非 ASCII 使用者資料夾的問題) |
| herdr 探測 | `command -v`、`[ -x ]`、固定 Unix 安裝路徑 | `Get-Command herdr`、`Test-Path`;herdr 的 Windows 安裝位置(待查) |
| socket bridge | `herdr remote-api-bridge` | 以 `Start-Process -NoNewWindow -PassThru` 啟動並轉發 stdin/stdout(herdr 的作法);未實測 |
| 檔案探測 | `[ -d ] [ -x ] [ -e ] [ -r ]`、`wc -c` | `Test-Path`、`Get-Item` 的 `Length`、嘗試開檔判斷權限;以自訂 exit code 回報缺席/不可讀 |
| 視窗讀取 | `dd` seek + `head -c` + `wc -l` + `sed -E` 剝圖 | `[IO.FileStream]` Seek/Read、在 bytes 中數 `\n`、`[regex]::Replace` 剝圖;以 bytes 輸出(注意 PowerShell 管線會轉碼——應直接寫 `[Console]::OpenStandardOutput()`) |
| 行開頭查詢 | `grep -a -b` + `cut` + `tail -n 1`(C locale) | FileStream 讀前 64KB 找最後一個 `\n` |
| 即時追蹤 | `tail -c +N -f` + awk 框行 | 迴圈:開檔 Seek 到游標、讀到結尾、睡一下、檢查長度成長;每行輸出「長度 TAB 內容」;stdin EOF 時結束 |
| Codex 尋檔 | `find … -name 'rollout-*-<id>.jsonl'`、`sqlite3 -readonly` | `Get-ChildItem -Recurse -Filter`;`sqlite3.exe` 不一定存在 → 有歧義時報錯 |
| Grok/OMP/subagent 尋檔 | `find -mindepth -maxdepth -type d -name` | `Get-ChildItem -Depth -Directory -Filter` |
| 父對話紀錄 grep | `grep -F -e`、`cksum` | `Select-String -SimpleMatch`、`Get-FileHash` |
| 圖片上傳 | `umask 077`、`mkdir -p`、`printf >>`、`base64 -d`、`find -mtime +7 -delete` | `New-Item -Force`、ACL、由 stdin 讀 bytes 寫檔、`Get-ChildItem | ? LastWriteTime -lt … | Remove-Item` |
| 資料夾瀏覽 | `cd`、`ls -1Lp`、`ls -lnA`、`pwd` | `Get-ChildItem -Directory`/`-Force`、`Resolve-Path` |
| 檔案下載 | `wc -c`、`base64` | `[IO.File]::OpenRead` 直接輸出 bytes(SSH 通道是二進位安全的,不需 base64) |
| 主題/YSK/用量的 CAS 寫入 | `cksum`、`readlink` 迴圈、`mktemp`、`mv` | `Get-FileHash`、`(Get-Item).LinkTarget`、暫存檔 + `Move-Item -Force` |
| 啟動 herdr 伺服器 | `nohup herdr server … &` | `Start-Process herdr.exe -ArgumentList server -WindowStyle Hidden`(未實測) |
| 串流清理 | `exec 3<&0`、`pgrep -P`、`kill`、`wait` | PowerShell job + 讀 stdin 至 EOF 後 `Stop-Process` |
| 終端機 | PTY + `herdr agent/terminal attach` | `terminal session control`(Windows 不支援 direct attach);OpenSSH 的 PTY 經 ConPTY,輸出序列可能不同 |
| 換行與編碼 | `\n`、UTF-8 | `\r\n`、OEM code page → 去 `\r`、設 UTF-8 輸出 |
| 指令長度 | 128KiB | 約 32,767 字元 → 大內容一律走 stdin |
| 推播外掛 | bash/python + curl | PowerShell `Invoke-RestMethod` 或 node;以 item 層級 `platforms` 區分 |

出處:`src/lib/herdr/shell.ts`、`src/lib/transcript/store.ts`、`src/lib/attachments/upload.ts`、`src/lib/files/remoteFiles.ts`、`src/lib/notifier/watcher.ts`、`docs/getting-started.md:268-276`、`herdr:src/remote/attach.rs`。

---

## 12. 常數總表(herdrchat 數值,供參考)

| 項目 | 值 |
|---|---|
| 狀態/列表輪詢逾時 | 15 s |
| 讀畫面逾時 | 15 s |
| 送出/按鍵逾時 | 20 s |
| 對話紀錄讀取逾時 | 30 s |
| 建 workspace/啟動 agent | 60 s(啟動 = herdr 逾時 + 60 s) |
| 安裝(herdr、integration) | 180 s |
| 串流啟動 | 20 s(事件訂閱 10 s) |
| 終端機啟動 | 20 s |
| 喚醒探測 | 背景 ≥60 s 後,3 s |
| 第二層期限寬限 | +5 s |
| prompt 等待 | 8000 ms(herdr 地板 5000 ms) |
| 停止確認 | 3 s,每 500 ms |
| 送出後等狀態(無法驗證時) | 3.5 s,補 Enter 後 2.5 s |
| 傳輸失敗等回執 | 8 s;Codex 5 s;slash 確認 10 s |
| 對話輪詢 | 2000 ms × 倍率(1/2/5);事件活著 30 s;失敗退避上限 60 s |
| 列表輪詢 | 3000 ms × 倍率;事件活著 30 s;上限 60 s |
| 事件去抖 | 250 ms;重連 1→30 s |
| 開啟視窗 / 舊頁 | 300 行 / 200 行;一次最多 6 個空頁;失敗 2 s 冷卻 |
| 從游標串流門檻 | 64 KB |
| 行開頭查詢塊 | 64 KB;退回 4096 bytes |
| 視窗起始塊 | 4 MB,×4 成長 |
| 預覽批次 / header 初值 | 48,000 bytes / 讀 1 MB 剝圖截 256 KB |
| 追蹤批次 | 100 ms |
| 追蹤監看 | working 時 90 s 無輸出 |
| 缺席兄弟退避 | 5 → 60 s |
| 無 session 寬限 | 80 s |
| 快取 | 開啟載入 150 則,保留 500 則 |
| 圖片 | 4 張、長邊 2048 px、JPEG 0.8、主機保留 7 天 |
| 檔案傳輸上限 | 25 MB |
| 指令長度上限 | 126 KiB |
| 在場回報 | 每 20 s,TTL 45 s,單獨送出前等 5 s |
| blocked 回答逾時 | max(12 s, 3 × 輪詢間隔);回答後 0.4 s、1.2 s 再看 |
| 面板監看 | 8 s;送鍵後 300 ms 重讀 |
| slash 掃描 | exec 20 s;grep 12 s;檔案 5 s;每 10 min;開聊天後 1.5 s;失敗 6 h 不重試;每資料夾 200 檔、每檔 4 KB、總 2 MB |
| workflow | 每 3 s;30 min 無變化停止 |
| subagent | 尋檔每 2 s;結束偵測每 3 s |
| 程序名全掃 | 每 5 次輪詢 |
| 終端機 | resize 去抖 250 ms;字型 13/8/28 pt;輸出暫存 2 MiB;marker 等待 256 KiB |
| 連線提示 | 4 s |
| 主機主題 | 每 10 s;≤64 KB |
| YSK | 偵測每 10 min、讀每 10 s、≤512 KB |
| 用量 | 約每 5 s;>10 min 標示「截至」 |
| 推播 watcher | 安靜 0.25 s;安全網 60 s;無 socket 3 s;標題 120 / 內文 240 字 |
| 中繼 | body ≤4096 bytes;每 IP 120/60 s、每 token 20/60 s;JWT 50 min;APNs 過期 3600 s |

出處:`src/lib/herdr/timeouts.ts`、`src/lib/poll.ts`、各功能檔。

---

## 13. 未知與不確定之處

1. **Windows 上的 `remote-api-bridge`**:herdrchat 記錄 0.9.3 在 Git Bash 下通過 check 但不回應(herdr#5128);herdr 自己以 PowerShell `Start-Process` 啟動。0.9.5 以 `-EncodedCommand` + 保持 stdin 的方式是否可用,需在 Windows 實測。→ #6 已實測:Git Bash 直接呼叫與 `-EncodedCommand` 都可用;Windows 的 bridge 遇到 stdin EOF 連 `ping` 都不回,見 `terminal-session-control-windows.md`。
2. **Windows 上的 `terminal session control`**:程式碼沒有封鎖、文件沒提;是 Windows Pane 終端機唯一可能路徑,需實測。ConPTY 對 xterm 序列與滑鼠的影響未知。→ #6 已實測可用,wire format 與 macOS 相同(滑鼠回報程式未測),見 `terminal-session-control-windows.md`。
3. **Windows 上各 agent 對話紀錄位置**:herdrchat 從未處理;推測為 `%USERPROFILE%\.claude` 等,Claude 資料夾名規則對 `C:\Users\x\repo` 應產生 `C--Users-x-repo`(推論);herdr 回報的 cwd 形式需實測。
4. **Tailscale SSH check mode**:herdrchat 沒有任何處理。Tailscale 在 check mode 下如何把驗證網址交給 SSH client(banner 或 keyboard-interactive 訊息)、連線會等多久,需在真機測。
5. **Codex session 回報**:herdr 0.9.5 不再安裝 Codex turn hook,狀態改由畫面偵測;integration v5 的 session 回報在 Codex 共用 app server 下是否仍需要 herdrchat 那種啟動器(帶 `HERDR_PANE_ID` 等環境變數),需實測。不能安裝啟動器時的退路未定。
6. **Codex 倒帶/`history_base` 分頁**:依 Codex 0.163 原始碼寫成,herdrchat 未以真實倒帶 session 驗證。
7. **agy 多呼叫 step 的結果配對**:herdrchat 註解與程式行為不一致(後續輸出實際上未配對)。需決定期望行為並以真實 agy 驗證。
8. **Pi 的 id-only 查找**:只搜 `~/.omp`(或 `PI_CONFIG_DIR`/`PI_CODING_AGENT_DIR`),不搜 Pi 自己的預設家目錄。
9. **Grok 權限提示解析**:依 herdr 的 `grok.toml` 引用列寫成,沒有真實 Grok 提示的擷取;herdrchat 量測的 Grok 是關閉核准的。
10. **自動拒絕倒數行**:fixture 是手寫的,未擷取過真實畫面。
11. **Claude「[Request interrupted by user]」**:沒有特殊處理,行為未定義。
12. **對話紀錄格式漂移**:本機 Claude Code 2.1.325 出現 herdrchat 沒提過的 record type(`api-request*`、`atis-latch`、`cost-state` 等)——目前規則下會被忽略,但代表格式在持續變動;建議 Drover Chat 對未知 type 一律忽略並有回歸 fixture。
13. **主機外掛的 session 識別**:plugin 環境沒有文件化的 herdr session 名稱變數;已安裝 plugin 對所有 session 生效,推播配對若要依 session 分開需另想辦法(`HERDR_SOCKET_PATH` 可能可用)。
14. **主機外掛的 runtime**:plugin 是使用者機器上能跑的 argv 命令;零安裝前提下要選什麼語言(bash 在 Windows 不可用、PowerShell 在 macOS/Linux 不一定有、node 不一定有),需人類決策。
15. **iOS 連線/握手逾時**:herdrchat 沒設,預設值未知;Drover Chat 必須自訂。
16. **一次性 exec 的 stdin EOF 行為**:herdrchat 不確定 Citadel 是否對一次性 exec 送 EOF;swift-nio-ssh 下要明確控制(對 bridge 不送、對讀 stdin 的上傳要送)。
17. **`terminal attach` 的版本**:herdrchat 認為 0.9 才有,herdr CHANGELOG 寫 0.5.10;對我們(≥0.9.5)無影響。
18. **長按選取**:iOS 上的終端機選取是模擬器預設行為,herdrchat 沒有自訂;我們用的模擬器需確認。
19. **前景通知抑制**:git 歷史有「前景時除了開著的聊天都顯示」的規則,但現行設定是前景一律以橫幅顯示;兩者以哪個為準未明。

### 需要人類決策的開放問題
- **D1 Windows 支援方式**:實作 PowerShell 方言(工作量:每個主機操作兩份腳本 + 測試)vs. 要求 Git Bash(違反「shell 可能是 cmd 或 PowerShell」的約束)。本規格假設前者。
- **D2 Pane 終端機傳輸**:全平台統一用 `terminal session control`(Windows 唯一可行;無 PTY;未經生產驗證),或 Unix 用 PTY + `attach`、Windows 用 control。
- **D3 會改主機檔案的功能**:Claude 用量(改 `settings.json`)、Codex 啟動器、主題參考檔、YSK 寫回——在「零安裝」下各自保留、改由主機外掛提供、或捨棄(使用者要求全部功能都做,但 ADR-0002 禁止主機安裝)。
- **D4 主機外掛的實作語言與分發**:每事件 hook 程序需要的 runtime;安裝方式(`herdr plugin install owner/repo`,需公開 GitHub repo);Windows 為 preview 時的 best-effort 範圍。
- **D5 推播配對與中繼認證**:配對密鑰的產生、交換(經 SSH 寫入主機)、中繼如何驗證、限流與撤銷。
- **D6 主機端目錄與檔名**:上傳、主題、配對資料的路徑(不可沿用 `herdrchat` 品牌);是否讀取 herdrchat 既有的主題檔以相容。
- **D7 新聊天預設權限模式**:herdrchat 預設「完全存取」(`bypassPermissions`);是否沿用(與 App Review、安全預期相關)。
- **D8 RSA 使用者**:只顯示錯誤,或另行提供在 App 內產生 ed25519/Secure Enclave 金鑰並教使用者加入 `authorized_keys`。
- **D9 Demo 內容**:Demo 是上架必需;範例內容要自己重寫(不可沿用 herdrchat 的 fixture 文字)。
- **D10 遙測與診斷**:是否保留「複製診斷」與其白名單內容。
