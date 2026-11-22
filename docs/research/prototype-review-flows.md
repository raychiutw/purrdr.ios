# Purrdr 新版原型：功能動線與資訊架構審查

日期：2026-11-22
審查對象：`scratchpad/design377/project/*.dc.html` 的 20 個 artboard(索引 `canvas.json`),對照規格 #376、拆票 #377–#396、`origin/master` 的 `DESIGN.md`／`GLOSSARY.md`,以及 `terminal-width-research.md`。
方法：逐一讀原始碼(去掉 style 後讀 `<x-dc>` 標記與 `renderVals` 資料)推出畫面，沒有渲染。artboard 以 canvas 標題的編號稱呼，例如「A6 四個 tab 與切換主機」。
依據標記：每項判斷附 Apple HIG、App Store 審查準則或 Nielsen Norman Group 的一手 URL;Apple 自家 App 的做法標「慣例」;沒有權威依據的判斷標「意見」。

---

## 摘要：最嚴重的 10 項

| # | 問題 | 嚴重度 | 一句話修正 |
|---|---|---|---|
| 1 | **切換主機選單在三個 tab 共用同一個值**:在「檔案」或「主機」tab 換主機會默默改掉聊天列表的篩選;選單裡的「所有主機」在檔案／主機 tab 點了會怎樣沒有定義(F-01) | 必修 | 聊天 tab 的選單改「目前主機」(含所有主機);檔案、主機 tab 的選單只改「選取中主機」,而且不列「所有主機」 |
| 2 | **帳號頁沒有「刪除會員」**:規格把帳號頁瘦身成「會員＋通知裝置＋登出」,違反 App Store 5.1.1(v)(F-02) | 必修 | 帳號頁最下面加 destructive「刪除會員…」(先跳確認),「登入方式」留著 |
| 3 | **在別的 tab 時看不到「需要你」**:聊天 tab 沒有 badge;在對話裡也不知道其他 Agent 在等(F-03) | 必修 | 聊天 tab 加「需要你」數量 badge;對話返回鈕旁顯示其他需要你的數量 |
| 4 | **「略過權限」「自動」這類高風險模式要點開面板才看得到**(F-04) | 必修 | 模式不是「一般」時，標題膠囊第二行加模式符號;略過權限用橙色 |
| 5 | **改版拿掉了既有功能卻沒給新入口**:做完再送(原在狀態 sheet)、主機同步、通知種類、主機分享與重新命名、主機主題／You should know／Codex 啟動器、數據用量、再看歡迎頁(F-05) | 必修 | 逐項指定新位置(見 F-05 表) |
| 6 | **缺少「沒有內容」與「不支援」的 tab 畫面**:沒有主機時的檔案／主機 tab、HTTPS 主機不支援檔案、範例主機的主機 tab(F-06) | 必修 | 每個 tab 都畫 `ContentUnavailableView` 版本，不隱藏也不停用 tab |
| 7 | **「+」有三種意思**:右上是新增聊天、輸入列是加入附件、選單裡是新增主機;在主機 tab 按右上「+」,使用者預期是新增主機(F-07) | 應修 | 新增聊天改用 `square.and.pencil`(訊息、郵件的慣例),「+」只留給加入與新增主機 |
| 8 | **模型膠囊只在輸入列展開時出現**,收合時哪裡都看不到目前模型;切換是在主機上操作 `/model` 面板，原型沒有「切換中」與「失敗」狀態(F-08) | 應修 | 標題面板加一列「模型 · Opus 5.5 中」;膠囊有切換中、失敗、停用三種狀態 |
| 9 | **關閉 sheet 的方式三種並存**,而且跟 DESIGN.md 的規則衝突(F-10) | 應修 | 改 DESIGN.md 跟 HIG(2026-03 版):取消／關閉在左上，完成在右上;新增聊天與加入 sheet 只留一種確認方式 |
| 10 | **終端機 artboard 畫成手機寬度自然折行**,跟終端機寬度研究的結論(電腦寬度整寬縮放)相反，會讓實作者照錯的畫面做(F-19) | 應修 | 重畫成整寬縮放＋捏合;一般 shell 另有「文字」檢視 |

---

## 一、主要任務動線逐條評估

步數以「從聊天 tab 第一層出發的點擊數」計(打字不算)。評分:A 順、B 可用但有小斷點、C 有明顯斷點、D 死路或缺畫面。

| 動線 | 路徑(artboard) | 步數 | 可發現性 | 回得去嗎 | 斷點、死路、重複入口 | 評分 |
|---|---|---|---|---|---|---|
| 1. 看哪個 Agent 需要我 → 回答 | 聊天 tab → 列表最上面帶「!」的列 → 對話中的權限卡片選項(A6、A19) | 2(從別的 tab 是 3) | 列表內高(橙色「!」、預覽「需要你：」粗體);**列表外低** | 返回鈕回列表 | 在檔案／主機／設定 tab 時沒有 badge(F-03);在對話 A 時不知道 B 也在等;無法從列表直接回答 | C |
| 2. 送 prompt 並附檔 | 點輸入框(展開)→「+」→ 加入 sheet → 選照片 →「加入 2 個」→ 送出(A1、A5) | 4–5 | 中(「+」是訊息 app 的慣例) | sheet 左上關閉 | 選「檔案」會從 sheet 再開系統文件挑選器(疊兩層 modal,F-21);**加入後輸入列長怎樣沒畫**(附件縮圖、移除);不能附主機上的檔案;離線時「+」仍可按(F-18) | C |
| 3. 切模型與投入程度 | 點輸入框(鍵盤升起)→ 模型膠囊 → 模型選擇 sheet → 選模型;投入程度：再點「投入程度」→ 子頁 → 選 → 返回 → 關閉(A4) | 3／6 | **低**:收合時看不到膠囊，只想換模型也得先叫出鍵盤 | sheet 內子頁有返回 | 選了模型後 sheet 是否自動關、主機端切換要時間，沒有進度與失敗狀態;「更多模型」列違反規格(F-09);Codex 的膠囊沒畫 | C |
| 4. 切權限模式 | 點標題膠囊 → 面板 → 選模式(A2) | 2 | **低**:膠囊外觀跟 Git、檔案預覽的靜態標題一樣，看不出能點(F-15);目前模式不顯示 | 點面板外關閉(推測) | 等你回覆時停用並說明原因(A16,好);高風險模式不可見(F-04) | B− |
| 5. 看用量與 context | 對話：點膠囊 → 面板;整體：主機 tab(A2、A7、A16) | 1–2 | 中 | 可以 | 兩處都有，算合理分工(F-17),但面板沒寫是哪台主機的額度;HTTPS 主機 tab 用量區整塊消失、沒有說明 | B |
| 6. 開終端機與 Git 變更 | 對話右上「⋯」→ 終端機／Git 變更 → 清單 → 單檔 diff(A3、A11、A12) | 2–3 | 中(「⋯」只裝兩項) | 返回 | 「⋯」只有兩項，沒 Git 時只剩一項(F-14);Spaces 檢視點只有 shell 的 Tab 也進終端機、主機 tab 又有「登入 Shell」:三個終端機入口，名稱要分清楚(F-24) | B |
| 7. 換主機 | 中間標題 → 選主機(A6、A7、A10) | 2 | 高 | 可以 | **跨 tab 互相影響**(F-01);設定 tab 中間不是選單，同一個位置意思不同 | C |
| 8. 新增主機與第一次使用(含範例主機) | 沒主機：空狀態「新增主機」或「體驗範例主機」;之後：中間標題 → 「新增主機…」(A14、A15) | 1–2 | 空狀態高;**之後低**(主機 tab 內沒有新增，右上「+」又不是新增主機) | sheet 取消 | 歡迎頁沒畫;範例主機啟用後怎麼移除沒畫(規格說「隨時可移除」);新增主機第一頁沒有推薦(F-20);後續步驟頁沒畫 | C |
| 9. 搜尋 Agent | 聊天 tab 往下拉 → 搜尋欄(A15) | 1(要知道往下拉) | **低**(藏起來，F-22) | 取消 | 結果標「所有主機 · 2 個結果」,範圍清楚(好);Spaces 檢視能不能搜沒定義;無結果畫面沒畫 | B− |
| 10. 離線時送出 | 對話頂端橫幅「連不上…再試一次」;打字送出 → 「排隊中 · 連上後送出 · 取消」(A17) | 1 | 高(輸入框 placeholder 寫「連上後送出」) | 取消排隊 | 「取消」是一小段文字，觸控目標不明;附件在離線不能送，但「+」沒停用(F-18) | B+ |
| 11. 登入與會員 | 右上帳號 → 登入 sheet → Apple 登入 → 帳號頁 → Purrdr Plus(A18、A8) | 3–4 | 中 | sheet 關閉 | 刪除會員不見(F-02);主機同步不見;「已登入、未開通」與付費牆沒畫;主機 tab 的通知開關在未開通時會怎樣沒定義(F-05) | D |
| 12. 設定 | 設定 tab(A8) | 1 | 高 | — | 少了數據用量、再看歡迎頁、隱私權政策(F-05);右上「+」與帳號在設定 tab 很突兀(F-12) | B |

---

## 二、問題清單

格式：編號｜嚴重度｜artboard｜現況｜依據｜具體修正。排序就是建議的處理順序。

### F-01 切換主機選單共用一個值，「所有主機」在三個 tab 意思不同　**必修**
- **artboard**:A6 四個 tab 與切換主機、A7 主機 tab、A7b HTTPS 主機、A10 檔案 tab、A15 搜尋。
- **現況**:中間標題在聊天、檔案、主機三個 tab 都是同一個切換主機選單(所有主機、各台、新增主機…)。規格 #390:「所有主機只對聊天有效，檔案與主機 tab 在選到它時沿用上次選的那台」。照 `GLOSSARY.md`「目前主機……在任一處切換主機就是改它」的定義，使用者在檔案 tab 選「Ray PC」,回到聊天 tab 會發現列表只剩 Ray PC 的 Agent,其他 Agent「不見了」。此外，選單在檔案／主機 tab 也列「所有主機」,但點了只會顯示上一台、標題卻寫什麼沒定義——同一個動作，結果不同。
- **依據**:NN/g〈Consistency and Standards〉「Users should not have to wonder whether different words, situations, or actions mean the same thing.」https://www.nngroup.com/articles/ten-usability-heuristics/ ;NN/g〈Modes in User Interfaces〉:mode slip 是「when the user is not aware of the currently active mode」,要「Clear visibility of the current active mode」https://www.nngroup.com/articles/modes/ 。`GLOSSARY.md` 已經分出「目前主機」(列表看哪些)與「選取中主機」(新聊天、主題用哪台)兩個值，原型沒有用上。
- **修正**:
  1. 聊天 tab 的選單只改「目前主機」,含「所有主機」(保留現狀)。
  2. 檔案、主機 tab 的選單只改「選取中主機」,**不列「所有主機」**;選中那台打勾。
  3. 聊天 tab 選某一台時，同時設成選取中主機(沿用 DESIGN.md #244 的規則);反過來，檔案／主機 tab 換主機**不改**聊天的篩選。
  4. 新增聊天的主機挑選鈕預設選取中主機。
  5. 在 `GLOSSARY.md` 與 #390 寫清楚這條規則，UI 測試加一條「在檔案 tab 換主機，聊天列表不變」。

### F-02 帳號頁沒有「刪除會員」　**必修**
- **artboard**:A8 帳號頁(右上角)。
- **現況**:帳號頁只有頭像、會員(Purrdr Plus)、通知裝置、登出。規格 #376／#393 寫「帳號頁只留會員與通知裝置」,把現行 DESIGN.md 帳號頁的「登入方式」「刪除會員」一起拿掉了。
- **依據**:App Store 審查準則 5.1.1(v)「If your app supports account creation, you must also offer account deletion within the app.」https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage ;HIG〈Managing accounts〉「Provide a clear way to initiate account deletion within your app or game.」https://developer.apple.com/design/human-interface-guidelines/managing-accounts
- **修正**:帳號頁由上而下：頭像與名稱 → 會員 → 主機同步(見 F-05)→ 通知裝置 → 登入方式(push)→「登出」→ 最下面獨立一組 destructive「刪除會員…」,點了跳確認 alert(說明後果，destructive「刪除會員」+ 取消)。同時修正 #393 的驗收條件，不要寫成「只有」。

### F-03 在別的 tab 或對話裡看不到「需要你」　**必修**
- **artboard**:A6、A10、A7、A8(tab bar 都沒有 badge)、A19 需要你(對話內看不到其他 Agent)。
- **現況**:「看哪個 Agent 需要我」是產品的核心任務，但只有在聊天 tab 的列表才看得到。進到對話時 tab bar 隱藏，連 tab 都看不到。
- **依據**:HIG〈Tab bars〉「Use a badge to indicate that critical information is available.」https://developer.apple.com/design/human-interface-guidelines/tab-bars ;NN/g〈Visibility of System Status〉「The design should always keep users informed about what is going on」https://www.nngroup.com/articles/ten-usability-heuristics/ 。慣例：訊息 app 在對話裡，返回鈕旁顯示其他對話的未讀數。
- **修正**:
  1. 聊天 tab 圖示加 badge,數字是「需要你」的 Agent 數(只算這個,完成、未讀不算，才不會稀釋)。
  2. 對話第二層的返回鈕右邊顯示「需要你」數量(例如「‹ 2」),VoiceOver 念「返回，另外 2 個 Agent 需要你」。
  3. 其他 Agent 在使用者看對話時轉成需要你，可以在頂端顯示一次不自動消失的小橫幅「weather-app 需要你」,點了直接切過去(意見：取代或補充推播)。

### F-04 高風險權限模式要點開面板才看得到　**必修**
- **artboard**:A2 標題膠囊與面板、A16 標題面板的特殊狀態、A1。
- **現況**:權限模式從輸入列移到標題面板。面板外沒有任何地方顯示目前模式。「略過權限」「自動」這種會讓 Agent 不經詢問就改檔、跑指令的模式，使用者要記得自己切過。
- **依據**:NN/g〈Modes〉建議「Clear visibility of the current active mode」,而且最好用兩種以上的視覺訊號 https://www.nngroup.com/articles/modes/ ;NN/g〈Recognition Rather than Recall〉「Minimize the user's memory load by making elements, actions, and options visible.」https://www.nngroup.com/articles/ten-usability-heuristics/
- **修正**:模式不是「一般」時，膠囊第二行最前面加模式符號與短名(例:「接受編輯 · ● 工作中 · Ray Mac Mini」放不下時，主機名先截斷);「略過權限」用系統橙加 `exclamationmark.shield`,VoiceOver 念出模式。面板裡目前模式的列維持勾選。

### F-05 改版拿掉的既有功能沒有新入口　**必修**
- **artboard**:A2、A7、A8、A3。
- **現況與修正**(對照 `origin/master` 的 DESIGN.md):

| 既有功能(DESIGN.md 位置) | 原型 | 建議的新位置 |
|---|---|---|
| 做完再送(#305,在「狀態 sheet」,而標題面板就是要取代狀態 sheet) | 不見 | 標題面板最下面一列開關「做完再送」(唯讀、SSH 時半透明並說明原因,沿用現規則) |
| 主機同步(#30,帳號頁) | 不見 | 帳號頁「會員」下面一列開關 |
| 每台主機的通知與通知種類(需要你／完成／主機服務,帳號頁「通知」區塊) | 主機 tab 只有一個開關，沒有種類;未登入／未開通時行為沒定義 | 主機 tab「通知」改成 push 列(顯示「需要你、完成」)→ 種類頁;未登入點了開登入 sheet,未開通開付費牆(列上副標「需要 Purrdr Plus」) |
| 主機分享(QR code)、重新命名、主機圖示(主機清單) | 不見(「多台主機的管理入口是標題選單」只能切換) | 主機 tab「這台主機」區塊加「分享…」;編輯主機頁照舊可改名與圖示 |
| 主機主題、You should know、Codex 啟動器(#274,主機頁最下方) | 不見 | 主機 tab 加「這台主機的設定」區塊，或明寫在「編輯主機」頁裡 |
| 數據用量(#354,設定頁) | 不見 | 設定 tab「其他」區塊 |
| 再看歡迎頁(#34,設定頁) | 不見 | 設定 tab「支援」或「關於」 |
| 已配對裝置、主機服務(#290、#291) | A7b 有，好 | 保留;名稱改用詞彙檔的「已配對裝置」(見 F-25) |

- **依據**:NN/g〈Consistency and Standards〉https://www.nngroup.com/articles/ten-usability-heuristics/ ;規格 #392 驗收條件「各區塊顯示與操作與原本功能等價」——原型沒有做到。
- **修正**:把上表補進 A7、A8、A2,並在 #390／#392／#393 的驗收條件逐項列出。

### F-06 缺少「沒有內容」與「不支援」的 tab 畫面　**必修**
- **artboard**:A15 還沒有主機(只畫聊天 tab)、A10、A7。
- **現況**:沒有主機時，tab bar 四個 tab 都在，但只畫了聊天 tab。HTTPS 主機的檔案(依 DESIGN.md「挑選鈕只列支援的主機」)、範例主機的主機 tab、連不上的主機 tab 都沒畫。
- **依據**:HIG〈Tab bars〉「Don't disable or hide tab bar buttons, even when their content is unavailable.」「If a section is empty, explain why its content is unavailable.」https://developer.apple.com/design/human-interface-guidelines/tab-bars
- **修正**:檔案 tab(沒有主機：「還沒有主機」+「新增主機」;主機不支援：「這台主機不能瀏覽檔案」+ 原因與「換主機」)、主機 tab(沒有主機：同聊天 tab 空狀態;範例主機：說明 + destructive「移除範例主機」;連不上：狀態列「離線」+「再試一次」,其餘區塊保留最後資料)。

### F-07 「+」一個符號三種意思　**應修**
- **artboard**:A6、A7、A10、A8(右上「+」= 新增聊天)、A1(輸入列「+」= 加入)、A6 選單(「+ 新增主機…」)。
- **現況**:右上「+」在每個 tab 都是新增聊天。在主機 tab 按「+」,依 HIG 工具列「動作作用於目前畫面」的原則，使用者會預期新增主機;在檔案 tab 會預期上傳或新增檔案。
- **依據**:HIG〈Tab bars〉「If you need to provide controls that act on elements in the current view, use a toolbar instead.」https://developer.apple.com/design/human-interface-guidelines/tab-bars (工具列放的是作用於目前畫面的動作);HIG〈Toolbars〉「Prefer simple, recognizable symbols」https://developer.apple.com/design/human-interface-guidelines/toolbars ;NN/g〈Consistency and Standards〉。慣例：訊息、郵件、備忘錄的「新增」都是 `square.and.pencil`,訊息的輸入列「+」是附加。
- **修正**:新增聊天改用 `square.and.pencil`(VoiceOver「新增聊天」),「+」只在輸入列(加入)與選單(新增主機…)出現。若要保留規格「右上固定」,就只換符號;若願意調整，主機 tab 的右上動作可以是「新增主機」(意見)。

### F-08 目前模型看不到，切換沒有回饋　**應修**
- **artboard**:A1、A4、A2。
- **現況**:模型膠囊只在輸入列展開(聚焦或有字)時出現;收合時、標題面板裡都看不到模型。規格寫切換是在主機上操作 `/model` 面板(移游標再按 `s`),需要時間也可能失敗，原型只有靜態清單。Agent 在工作中或等你回覆時能不能切也沒定義(權限模式有，模型沒有)。
- **依據**:NN/g〈Visibility of System Status〉、〈Recognition Rather than Recall〉https://www.nngroup.com/articles/ten-usability-heuristics/ ;HIG〈Feedback〉「Show people when a command can't be carried out and help them understand why.」https://developer.apple.com/design/human-interface-guidelines/feedback ;HIG〈Loading〉「Clearly communicate that content is loading」https://developer.apple.com/design/human-interface-guidelines/loading
- **修正**:
  1. 標題面板在 context 下面加一列「模型　Opus 5.5 · 中 ›」,點了開同一個模型選擇 sheet——不聚焦輸入框也能換。
  2. 選模型後 sheet 關閉，膠囊顯示「切換中…」(小型進度元件);失敗時膠囊恢復原值，輸入列上方一行錯誤說明。
  3. Agent 等你回覆時，模型列與膠囊停用，說明同權限模式(「先回答再切換」)。
  4. 補畫 Codex Agent 的膠囊(顯示目前模型、能不能點)。

### F-09 「更多模型」列與規格衝突　**應修**
- **artboard**:A4 模型選擇。
- **現況**:sheet 最下面有「更多模型 ›」。規格 #376:「『更多模型』展開後的畫面與展開方式尚未錄製，錄下之前該列先不出現。」
- **依據**:規格 #376 Implementation Decisions(內部依據);HIG〈Feedback〉不讓使用者點到沒有結果的東西(意見延伸)。
- **修正**:原型拿掉這一列，或標註「錄製後才出現」,避免截圖比對票(#395)把它當成要做的東西。

### F-10 關閉 sheet 的方式不一致，且與 DESIGN.md 衝突　**應修**
- **artboard**:A4、A5、A8 帳號、A18 登入(左上「關閉」xmark)、A14 新增聊天與新增主機(左上「取消」xmark + 底部「開始聊天」)、A5(左上關閉 + 底部「加入 2 個」)。
- **現況**:DESIGN.md:「不編輯內容的 sheet 一律以右上『完成』關閉，不混用 Close(`xmark`)」。原型全部改成左上 xmark,新增聊天與加入另有底部主要按鈕。
- **依據**:HIG〈Sheets〉(2026-03-24 更新按鈕位置)「In iOS and iPadOS, for sheets with a single view, the Cancel button belongs on the leading edge of the top toolbar. When present, the Done button belongs on the trailing edge.」「Avoid showing all three buttons — Cancel, Done, and Back — together.」https://developer.apple.com/design/human-interface-guidelines/sheets ;HIG〈Modality〉「if closing the view could result in the loss of user-generated content, be sure to explain the situation」https://developer.apple.com/design/human-interface-guidelines/modality
- **修正**:
  1. **改 DESIGN.md**,不改原型的左上 xmark:原型符合目前的 HIG,DESIGN.md 的規則已過時。
  2. 新增聊天：左上 xmark 是「取消」,第一則訊息有字時關閉要先問(捨棄／繼續編輯);確認動作只留一個——底部「開始聊天」或右上勾選，二擇一(建議保留底部，因為在鍵盤上方好按，意見)。
  3. 模型選擇、帳號、登入這類不編輯內容的 sheet:左上 xmark 關閉，不加「完成」。

### F-11 Agents／Spaces 切換要兩步，且和主機選單長得一樣　**應修**
- **artboard**:A6、A13 Spaces 檢視。
- **現況**:左上「Agents ▾」點開選單才能選 Spaces(兩步)。規格 #391 寫「一鍵切換」。頂列左邊與中間是兩顆外觀相同的「文字 ▾」玻璃膠囊，一個切檢視、一個切主機，在 390pt 寬加上右邊兩顆鈕，長主機名稱會被擠。
- **依據**:規格 #391;HIG〈Toolbars〉「Minimize the number of groups.」「In general, aim for a maximum of three.」「Prioritize only the most important items for inclusion in the main toolbar area.」https://developer.apple.com/design/human-interface-guidelines/toolbars ;NN/g〈Consistency and Standards〉(外觀相同、作用不同)。
- **修正**:左上改成一顆只有符號的切換鈕(顯示**目前**檢視的符號:Agents 是 `person.2`、Spaces 是 `square.grid.2x2`),點一下切換、長按出選單;VoiceOver「檢視:Agents,點兩下切到 Spaces」。中間保留唯一的「文字 ▾」(主機)。

### F-12 頂列左中右在各 tab 意思不同　**應修**
- **artboard**:A6、A10、A7、A8、A15。
- **現況**:

| 畫面 | 左 | 中 | 右 |
|---|---|---|---|
| 聊天 tab | Agents ▾ | 所有主機 ▾ | + 、帳號 |
| 檔案 tab | 空 | Ray Mac Mini ▾ | + 、帳號 |
| 主機 tab | 空 | Ray Mac Mini ▾ | + 、帳號 |
| 設定 tab | 空 | 「設定」純文字 | + 、帳號 |
| 沒有主機 | 空 | 空 | +(停用)、帳號(人頭) |
| 對話 | 返回 | 標題膠囊(可點，開面板) | ⋯ |
| Git／單檔 diff／終端機 | 返回 | 標題(不能點) | 空 |
| 檔案預覽 | 返回 | 標題(不能點) | 分享 |

  第一層的中間有時是選單、有時是標題;設定 tab 也放「新增聊天」,而且同時有設定 tab 與帳號鈕兩個「設定類」入口。第二層大致一致(好),只差在對話的膠囊可點、其他不可點但外觀相同(見 F-15)。
- **依據**:HIG〈Toolbars〉「Keep consistent groupings and placement」「Provide a useful title for each window.」https://developer.apple.com/design/human-interface-guidelines/toolbars 。慣例：iOS「設定」app 把 Apple 帳號放在設定第一列。
- **修正**:
  1. 第一層每個 tab 都有標題：聊天、檔案、主機 tab 的標題就是主機選單(主機名 ▾),設定 tab 是大標題「設定」——讓「中間 = 這頁看的是什麼」一致。
  2. 設定 tab 的右上不放「新增聊天」(意見:規格要求「固定」,但在設定頁沒有使用情境);帳號鈕保留，另外在設定 tab 第一列放帳號列(頭像、名稱、Purrdr Plus 狀態),與 iOS 設定的慣例一致。
  3. 沒有主機時中間顯示「聊天」標題，不要整列空白。

### F-13 第二層一律隱藏 tab bar 與 HIG 衝突，需要記錄理由　**應修**
- **artboard**:A1、A10 檔案預覽(「第二層,tab bar 隱藏」)、A11、A12。
- **現況**:規格 #376「只有第一層顯示 tab bar,第二層隱藏」,原型的檔案預覽也隱藏。
- **依據**:HIG〈Tab bars〉「Make sure the tab bar is visible when people navigate to different sections of your app.」「If you hide the tab bar, people can forget which area of the app they're in. The exception is when a modal view covers the tab bar」https://developer.apple.com/design/human-interface-guidelines/tab-bars
- **修正**:對話與終端機隱藏(底部被輸入列、按鍵列佔用，這是聊天類 app 的常見例外，意見);**檔案預覽、資料夾第二層保留 tab bar**(那裡沒有底部控制，沒有隱藏的理由)。把這個例外與理由寫進 DESIGN.md 的「頂層導覽」。

### F-14 對話右上「⋯」只裝兩項　**應修**
- **artboard**:A3 右上角整合選單。
- **現況**:「⋯」打開只有「終端機」與「Git 變更」;沒有 Git 變更時(#381:「不出現或停用」)只剩一項。「⋯」的意思是「更多」,但 VoiceOver 標籤是「終端機與 Git 變更」。
- **依據**:HIG〈Toolbars〉「Add a More menu to contain additional actions.」「only add this menu if you really need it」https://developer.apple.com/design/human-interface-guidelines/toolbars ;HIG〈Menus〉「Prefer listing important or frequently used menu items first.」https://developer.apple.com/design/human-interface-guidelines/menus
- **修正**:把它當成這個對話的「更多」選單：終端機、Git 變更 /(分隔)/ 做完再送(開關，若不放面板)、顯示版面(Tab 版面圖)。Git 不可用時顯示停用並在副標寫原因(「不是 Git 資料夾」),選單不要只剩一項。VoiceOver 標籤改「更多」。

### F-15 可點的標題膠囊看不出能點　**應修**
- **artboard**:A1、A2(對話膠囊)vs A11、A12、A10(靜態標題膠囊)。
- **現況**:對話的膠囊點了開用量與權限面板;Git、終端機、檔案預覽的標題是同樣的玻璃膠囊，但不能點。
- **依據**:NN/g〈Consistency and Standards〉https://www.nngroup.com/articles/ten-usability-heuristics/ ;HIG〈Toolbars〉若自訂控制「make sure it still looks the same, behaves as people expect」https://developer.apple.com/design/human-interface-guidelines/toolbars
- **修正**:對話膠囊第一行尾加小 `chevron.down`(與主機選單一致);其他第二層的標題不用膠囊底(用系統標題文字)。VoiceOver hint「點兩下顯示用量與權限模式」。

### F-16 狀態符號在列表與膠囊不一致，連線狀態混進 Agent 狀態　**應修**
- **artboard**:A6(列表：頭像右下 ✓／!／•••)、A1／A2／A19(膠囊:「● 完成」「● 工作中」「! 需要你」)、A17(膠囊「● 離線」)、A12(「● 已連線」)。
- **現況**:列表用形狀區分狀態;膠囊大多用同一個圓點、只靠顏色，需要你才用「!」;「離線」是連線狀態，卻放在 Agent 狀態的位置。
- **依據**:NN/g〈Consistency and Standards〉;DESIGN.md「狀態同時用文字 + 符號 + 顏色」(內部依據)。
- **修正**:膠囊沿用列表那組符號(✓ 完成、••• 工作中、! 需要你);連線中斷時第二行改「`wifi.slash` 離線 · Ray Mac Mini」,Agent 狀態顯示最後已知值加「?」(同 A17 列表的「未知」)。

### F-17 用量同時在標題面板與主機 tab:合理，但要講清楚範圍　**應修**
- **artboard**:A2、A16、A7、A7b。
- **現況**:面板只顯示這個 Agent 對應的服務(「用量 · Claude」);主機 tab 顯示 Claude 與 Codex 兩組。用量其實是主機上那個帳號的額度，面板沒寫是哪台主機;HTTPS 主機的主機 tab 用量區整個消失，沒有說明;「啟用用量顯示」只畫在面板，主機 tab 沒有。
- **依據**:HIG〈Feedback〉「When status feedback is available near the items it describes, people get important information without having to take action or leave their current context.」https://developer.apple.com/design/human-interface-guidelines/feedback ;HIG〈Tab bars〉「If a section is empty, explain why」https://developer.apple.com/design/human-interface-guidelines/tab-bars
- **修正**:兩處留著(面板就近看、主機 tab 看全部),共用同一個元件(#389)。面板標題改「用量 · Claude · Ray Mac Mini」;主機 tab 補「尚未啟用」(與面板同一顆「啟用用量顯示」)與 HTTPS「這台主機的用量要等主機服務支援」一行說明，不讓區塊無聲消失。

### F-18 離線時輸入列「+」仍可按　**應修**
- **artboard**:A17 離線與排隊訊息。
- **現況**:DESIGN.md #301:「離線時仍可送出文字(有附件、自訂回答時不行)」。原型離線的輸入列「+」沒有停用。排隊泡泡的「取消」是一小段文字。
- **依據**:NN/g〈Error Prevention〉「the best designs carefully prevent problems from occurring in the first place.」https://www.nngroup.com/articles/ten-usability-heuristics/ ;DESIGN.md 通用規則「觸控目標 ≥ 44×44 pt」(內部依據)。
- **修正**:離線時「+」停用，點了顯示一行「連上後才能加入附件」;「取消」改成泡泡的長按選單「取消排隊」,或至少 44pt 高的按鈕。

### F-19 終端機 artboard 與終端機寬度研究的結論相反　**應修**
- **artboard**:A12 終端機、A18 登入 Shell。
- **現況**:Pane 終端機畫成手機寬度自然折行的文字。研究結論是全螢幕 TUI「不改 PTY 寬度，就不可能在手機上自然折行」,建議「電腦尺寸整寬縮放＋捏合」,一般 shell 另有唯讀的「文字」檢視。原型也沒有連線中斷、接管的狀態。
- **依據**:`scratchpad/terminal-width-research.md` §3、§4(內部一手實測);HIG〈Feedback〉(連線狀態)。
- **修正**:A12 改畫整寬縮放(字小、捏合放大到游標附近)與縮放指示;shell Pane 的右上多一顆「文字／終端機」切換;補「連線中斷 · 重新連線」與「桌機正在操作 · 接管」橫幅。登入 Shell 照舊配合手機寬度(研究也這樣建議),兩者的差異寫進 DESIGN.md。

### F-20 新增主機第一頁沒有推薦，和既有引導不一樣　**應修**
- **artboard**:A14 新增主機。
- **現況**:第一頁列出 Tailscale SSH、OpenSSH、HTTPS 三列，沒有推薦與「不確定選哪個」。DESIGN.md #341 的引導是「一頁問一件事、SSH 標推薦、選項在底部玻璃面板」,原型改成了 sheet 清單;後續步驟沒畫。
- **依據**:HIG〈Onboarding〉「design a brief, enjoyable experience that doesn't require people to memorize a lot of information.」https://developer.apple.com/design/human-interface-guidelines/onboarding ;NN/g〈Help and Documentation〉https://www.nngroup.com/articles/ten-usability-heuristics/
- **修正**:沿用 #341 的引導第一頁(或在這份清單上加「推薦」標在 Tailscale SSH);「體驗範例主機」留在最下面(好)。標題列照 HIG 多步驟規則：第一頁左上取消、之後返回取代取消。

### F-21 加入 sheet 的「檔案」會疊第二層 modal　**應修**
- **artboard**:A5 加入 sheet。
- **現況**:sheet 裡點「檔案」只能再開系統文件挑選器(或主機檔案),等於 sheet 上再疊一層;加入之後輸入列怎麼顯示附件沒畫。
- **依據**:HIG〈Sheets〉「Display only one sheet at a time from the main interface.」「If something people do within a sheet results in another sheet appearing, close the first sheet before displaying the new one.」https://developer.apple.com/design/human-interface-guidelines/sheets
- **修正**:點「檔案」「拍照」時先關加入 sheet 再開系統畫面;補一張「已加入 2 張照片、1 個檔案」的輸入列(縮圖列、每個可移除、超過上限的說明)。可選：加「主機上的檔案」選項，從檔案 tab 的瀏覽器挑(意見)。

### F-22 搜尋藏在往下拉　**建議**
- **artboard**:A6、A15。
- **現況**:搜尋欄要往下拉才出現。結果標「所有主機 · 2 個結果」,範圍清楚(好)。Spaces 檢視能不能搜、搜不到時怎麼顯示沒畫。
- **依據**:HIG〈Searching〉「If search is important, give it a primary position in your app or view.」「In apps that use tab bars, like Photos and Apple TV, search is a dedicated tab.」「Clearly display the current scope of a search.」https://developer.apple.com/design/human-interface-guidelines/searching ;NN/g〈Search: Visible and Simple〉偏好看得到的輸入框而不是隱藏入口 https://www.nngroup.com/articles/search-visible-and-simple/
- **修正**:Agent 數量通常不多，往下拉可以接受，但列表在頂端時搜尋欄**預設顯示**、捲動後才收起(系統 `.searchable` 的自動模式);Spaces 檢視搜 workspace 與 Tab 名稱;補「找不到『xxx』」畫面(`ContentUnavailableView.search`)。若之後搜尋範圍擴大到檔案，再考慮 iOS 26 的 trailing 搜尋 tab。

### F-23 選單裡勾選與圖示的位置不一致　**建議**
- **artboard**:A6 主機選單(勾在左)、A13 檢視選單(圖示在左、勾在右)、A2／A4(sheet 內清單勾在右)。
- **依據**:HIG〈Menus〉「Consider using a checkmark to show that an attribute is currently in effect.」「provide icons for all menu items in a group, or none of them.」https://developer.apple.com/design/human-interface-guidelines/menus 。勾選與圖示確切位置由系統元件決定(意見)。
- **修正**:彈出式選單一律用系統 `Menu`／`Picker`,不手畫，勾選位置交給系統;sheet 裡的清單勾在右(iOS 設定 app 慣例)。主機選單若要帶主機圖示，就每一項都帶(含「所有主機」與「新增主機…」)。

### F-24 三個終端機入口要分清楚名稱　**建議**
- **artboard**:A3(對話 ⋯ → 終端機)、A13(Spaces 點只有 shell 的 Tab)、A7(登入 Shell)、A18。
- **現況**:「終端機」是這個 Agent 所在 Pane;「登入 Shell」是一條新的 SSH shell。兩者的標題列很像(A12「purrdr.ios ● 已連線」、A18「登入 Shell ● 已連線」)。
- **依據**:NN/g〈Match Between the System and the Real World〉、〈Consistency and Standards〉https://www.nngroup.com/articles/ten-usability-heuristics/
- **修正**:選單項目改「Pane 終端機」,副標「這個 Agent 的畫面」;登入 Shell 的副標寫「在主機上開新的 shell」。名稱寫進 `GLOSSARY.md`。

### F-25 用詞與詞彙檔不一致　**應修**
- **artboard**:A7b(「主機服務」「已配對的裝置」)、A6(tab「聊天」vs 檢視「Agents」)、A14／A15(「範例主機」)。
- **現況**:`origin/master` 的 `GLOSSARY.md` 仍寫畫面說「電腦」、主機服務在畫面稱「Purrdr 連線助理」、Demo 主機避免「範例主機」;規格 #376 決定改成「主機」「範例主機」,但沒提主機服務的畫面名稱。
- **依據**:NN/g〈Consistency and Standards〉;專案規範「UI 文字一律用 GLOSSARY.md 的詞」(內部依據)。
- **修正**:先完成 #378(詞彙檔改「主機」「範例主機」),同時決定主機服務的畫面名稱(維持「Purrdr 連線助理」或改「主機服務」),原型跟著改;「已配對的裝置」改「已配對裝置」。tab 叫「聊天」、檢視叫「Agents」可以並存，但在詞彙檔寫明「聊天 tab 有 Agents 與 Spaces 兩種檢視」。

### F-26 刪除主機、移除範例主機沒有確認畫面　**應修**
- **artboard**:A7、A7b(「刪除主機」)。
- **依據**:HIG〈Alerts〉「when people take an uncommon destructive action that they can't undo, it's important to display an alert」「include a Cancel button」https://developer.apple.com/design/human-interface-guidelines/alerts
- **修正**:沿用 DESIGN.md 主機清單的確認文字(「要從這部裝置移除『主機名』嗎?」、說明影響、destructive「移除主機」+ 取消);按鈕文字統一用「移除主機」(主機本身不受影響，用「刪除」會誤導)。

### F-27 需要你的卡片與輸入列並存，沒說打字會怎樣　**建議**
- **artboard**:A19 需要你：權限確認。
- **現況**:卡片有「允許」「這個 session 都允許」「不要，告訴 Agent 怎麼做…」,下方輸入列 placeholder 仍是「訊息」。
- **依據**:NN/g〈Error Prevention〉https://www.nngroup.com/articles/ten-usability-heuristics/
- **修正**:有待回答的卡片時，placeholder 改「或告訴 Agent 怎麼做」,直接打字送出等同第三個選項;列表列長按出現「允許／不允許」快速回答(意見)。

### F-28 新增聊天 sheet 沒有標題　**建議**
- **artboard**:A14 新增聊天。
- **現況**:標題位置放主機挑選鈕，sheet 沒有「新增聊天」字樣;從聊天 tab 選「所有主機」時預設哪台不明顯。
- **依據**:HIG〈Toolbars〉「Provide a useful title for each window.」https://developer.apple.com/design/human-interface-guidelines/toolbars
- **修正**:標題「新增聊天」,主機改成表單第一列「主機　Ray Mac Mini ›」(預設選取中主機，見 F-01)。

### F-29 帳號 sheet 內再開付費牆可能疊 sheet　**建議**
- **artboard**:A8 帳號頁(Purrdr Plus 列)。
- **依據**:HIG〈Sheets〉「Display only one sheet at a time」https://developer.apple.com/design/human-interface-guidelines/sheets
- **修正**:Purrdr Plus 頁在帳號 sheet 內 push;從主機 tab 通知開關進入時才以 sheet 開。

---

## 三、資訊架構

**4 個 tab 的分類**:聊天(主要)、檔案、主機、設定，符合 HIG「tab 是導覽，不是動作」(https://developer.apple.com/design/human-interface-guidelines/tab-bars),數量合理。需要調整的地方:
- **主機 tab 依賴標題選單**:它是「一台主機的總頁」,沒有清單頁，所以多台主機的總覽只剩選單裡的副標(連線方式 · 線上／離線)。這個副標要保留，選單也是唯一的主機總覽(好);但分享、排序、範例主機移除必須在主機 tab 內有入口(F-05、F-06)。
- **放錯或拆散的東西**:通知被拆成「主機 tab 的開關」與「帳號頁的通知裝置」兩處，種類沒有家(F-05)。建議主機 tab 管「這台主機要不要通知、通知哪些」,帳號頁管「哪些裝置收得到」,兩處互相連結(意見)。「已用／剩餘」放設定 tab 合理(全域)。
- **藏太深**:模型(要先聚焦輸入框)、權限模式(要點標題)、Git 變更(要進對話再開 ⋯)。前兩個用 F-04、F-08 補可見性;Git 變更以 Agent 的工作目錄為單位，留在對話裡合理。

**「所有主機」的語意**:聊天 = 合併顯示;檔案、主機 = 沿用上一台;設定 = 沒有;新增聊天 = 沒定義;搜尋 = 跟著聊天。同一個選項在不同 tab 意思不同，是這份原型最大的 IA 問題(F-01)。

**用量出現兩處**:合理(面板就近、主機 tab 全貌),條件是共用元件、標明主機、空與未啟用狀態一致(F-17)。

---

## 四、狀態設計

| 狀態 | 原型有沒有 | 一致性與缺口 |
|---|---|---|
| 空狀態(沒有主機) | 聊天 tab 有(A15) | 檔案、主機 tab 沒畫(F-06);搜尋無結果沒畫 |
| 載入 | 沒有 | 列表骨架與「連線中…」列(DESIGN.md #221)、對話第一次載入、模型切換中、Git 清單讀取中都沒畫 |
| 離線 | 列表與對話有(A17) | 主機 tab 的離線、裝置沒有網路(全畫面 `wifi.slash`)沒畫;離線時「+」沒停用(F-18) |
| 需要你 | 列表、對話、面板都有(A6、A19、A16) | tab 沒有 badge(F-03);多題問答、自訂回答的卡片沒畫 |
| 工作中 | 有，含停止(A19) | 工作中能不能換模型沒定義(F-08);做完再送佇列沒畫(F-05) |
| 權限停用 | 有(A16,附原因) | 好;模型停用沒比照(F-08) |
| 用量未啟用 | 面板有(A16) | 主機 tab 沒有;HTTPS 沒說明(F-17) |
| 唯讀裝置 | **沒有** | 輸入列、需要你選項、停止、權限面板都要停用並說明(DESIGN.md #60) |
| 未配對(這支裝置沒有權杖的 HTTPS 主機) | 沒有 | 主機 tab 與主機選單要標「這支裝置尚未配對」 |
| 主機服務過舊 | A7b 有「更新到 0.12.0」 | 好 |
| herdr 過舊 | 沒有 | 主機 tab 要有提示 |
| 已登入未開通 Plus | 沒有 | 帳號頁與主機 tab 通知開關的樣子 |

---

## 五、缺漏畫面清單

1. 歡迎頁(含「試用範例主機」),以及啟用範例主機後的列表(有「正在看範例主機 · 移除」的入口)。
2. 檔案 tab:沒有主機、主機不支援、空資料夾、讀取失敗。
3. 主機 tab:離線、範例主機、未配對 HTTPS、唯讀、herdr 過舊、用量未啟用、刪除確認、分享 QR code、通知種類頁、這台主機的設定(主題、You should know、Codex 啟動器)。
4. 對話：唯讀輸入列、已加入附件的輸入列、做完再送佇列、模型切換中／失敗、Codex 模型膠囊、第一次載入骨架、其他 Agent 需要你的提示。
5. 列表：第一次載入骨架、「連線中…／仍在連線…」列、裝置沒有網路、搜尋無結果、Spaces 檢視的搜尋。
6. Git 變更：沒有變更、不是 Git 資料夾、讀取中。
7. 終端機：整寬縮放、文字檢視、連線中斷、接管(F-19)。
8. 帳號：已登入未開通(步驟卡)、付費牆、主機同步、登入方式、刪除會員確認(F-02)。
9. 新增主機引導第 2 步以後、測試連線失敗、完成頁。
10. 新增聊天：建立中、失敗。
11. App 鎖遮罩，以及推播點開時的導航(解鎖後才進對話)。

---

## 六、做得好、應保留的部分

- **輸入列兩態**(A1):收合一列、展開兩列，上限 5 行;模型膠囊、加入、送出各就各位，沒有收鍵盤鈕。
- **權限停用附原因**(A16):「Agent 正在等你回覆。先回答，再切換權限模式。」把錯誤預防和說明放在同一處(NN/g〈Error Prevention〉)。
- **Codex 唯讀顯示核准政策並指路**(A16):「請在電腦上用 /permissions 調整」——做不到的事明講。
- **投入程度子頁**(A4):在 sheet 內 push、「推薦」與「3.5× 或更多使用量」提示、「改了會成為新 session 的預設」說明，符合 HIG 讓使用者知道後果。
- **加入 sheet 顯示已選數量與「加入 2 個」**(A5)。
- **搜尋結果標出範圍**(A15:「所有主機 · 2 個結果」),符合 HIG「Clearly display the current scope of a search」。
- **離線排隊**(A17):輸入框 placeholder 寫「連上後送出」、泡泡標「排隊中」、可取消;連不上的主機保留最後的列並標「?」,列表下方「連線中斷」區段可重試，不用 alert。
- **主機選單帶連線方式與線上／離線**(A6),選單本身就是簡易總覽;「新增主機…」以分隔線放最後，符合 HIG〈Menus〉的「…」用法。
- **主機 tab 依連線方式調整**(A7、A7b):HTTPS 不顯示登入 Shell,改顯示主機服務版本、更新與已配對裝置;刪除放在最下面獨立一組。
- **Git 變更清單 → 單檔 diff**(A11):增刪行數、變更種類有 VoiceOver 標籤(「修改」「新增」)。
- **狀態用文字＋符號＋顏色**(列表的 ✓／!／•••),VoiceOver 標籤齊全;很多按鈕都有 `aria-label`,方便之後對應 accessibility identifier。
- **空狀態同時給「新增主機」與「體驗範例主機」**(A15),符合 HIG〈Onboarding〉「People want to start using your app … immediately」與 App Store 2.1 對 demo mode 的要求。
- **深色底提亮對照**(A9):純黑與提亮並排，方便決策。

---

## 依據來源

- Apple HIG:Tab bars https://developer.apple.com/design/human-interface-guidelines/tab-bars ;Toolbars https://developer.apple.com/design/human-interface-guidelines/toolbars ;Menus https://developer.apple.com/design/human-interface-guidelines/menus ;Sheets https://developer.apple.com/design/human-interface-guidelines/sheets ;Modality https://developer.apple.com/design/human-interface-guidelines/modality ;Searching https://developer.apple.com/design/human-interface-guidelines/searching ;Onboarding https://developer.apple.com/design/human-interface-guidelines/onboarding ;Feedback https://developer.apple.com/design/human-interface-guidelines/feedback ;Loading https://developer.apple.com/design/human-interface-guidelines/loading ;Alerts https://developer.apple.com/design/human-interface-guidelines/alerts ;Managing accounts https://developer.apple.com/design/human-interface-guidelines/managing-accounts (以上引文取自各頁的 JSON 資料，2026-11-22 擷取)
- App Store 審查準則 5.1.1(v)、2.1(a):https://developer.apple.com/app-store/review/guidelines/
- Nielsen Norman Group:10 Usability Heuristics https://www.nngroup.com/articles/ten-usability-heuristics/ ;Modes in User Interfaces https://www.nngroup.com/articles/modes/ ;Search: Visible and Simple https://www.nngroup.com/articles/search-visible-and-simple/
- 內部：規格 #376、拆票 #377–#396、`origin/master` 的 `DESIGN.md` 與 `GLOSSARY.md`、`scratchpad/terminal-width-research.md`。
