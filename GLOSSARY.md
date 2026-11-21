# Purrdr(purrdr.ios)

在 iPhone／iPad 上看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機進那台電腦。這份文件只定義本專案的共同語彙;同一個東西有多種叫法時挑一個，其餘列在 _避免_。UI 文字、型別名稱、測試名稱一律用這裡的詞。實作細節不寫在這裡。

herdr 自己的概念(Workspace、Tab、Pane、Agent 狀態)沿用 herdr 官方文件的英文名稱與定義。

## 連線

**主機**(Host):
使用者的一台電腦，上面跑著 herdr,app 透過某種連線方式連進去。一台主機有一種作業系統(macOS、Linux 或 Windows)和一種連線方式。
_避免_:電腦、伺服器、機器、Device、Computer

**連線方式**:
app 連上主機的方式，分成 **Tailscale SSH**(由 Tailscale 依 tailnet 身分放行，不需金鑰或密碼)、**OpenSSH**(主機自己的 sshd,用金鑰或密碼)與 **HTTPS**(經 Tailscale Serve 連到主機服務，用裝置權杖)。HTTPS 不支援登入 Shell。
_避免_:Transport、Auth mode(例外：網路傳輸層的型別沿用 `*Transport`,如 `URLSessionHostServiceTransport`、`PaneTerminalTransport`、`BackendTransport`,指收送位元組的那一層，不是連線方式)

**新增主機引導**(Add host guide):
新增一台主機時一頁問一件事、帶使用者在主機上做好準備並填完連線設定的流程，最後測試連線。編輯已存的主機不經引導(用主機編輯頁)。畫面上 OpenSSH 稱「原生 SSH」。
_避免_:精靈、Wizard、Onboarding(那是 app 第一次開啟的歡迎頁)

**主機身分確認**:
第一次以 SSH 連到一台主機時，使用者決定是否信任它出示的 host key,信任後記住它的指紋;之後指紋變了一律擋下。Tailscale SSH 由 tailnet 身分保證，不必確認。
_避免_:配對(那是 HTTPS 的連線配對)、驗證主機

**目前主機**(Current host):
使用者目前在看的主機範圍：所有主機，或某一台主機。全 app 共用、存在本機;有主機範圍的畫面(Agent 列表、數據用量、方案用量…)預設用它，在任一處切換主機就是改它。那台主機被刪除時回到所有主機。目前主機是某一台時，它同時是選取中主機。
_避免_:主機篩選(那是 Agent 列表上改目前主機的控制，不是另一個值)、全域主機

**選取中主機**:
新聊天開在它上面、套用它的主題、它的錯誤佔滿畫面的那台主機。存在本機，重新啟動後選回同一台。不決定列表看哪些主機(那是目前主機):所有主機的 Agent 預設合併在同一個 Agent 列表。
_避免_:目前主機、Active host

**主機圖示**(Host icon):
使用者替主機選的小圖，顯示在主機名稱前(主機清單、主機選單、Agent 列表的主機標示)，讓多台主機一眼分得出來。11 種(桌機、筆電、Mac mini、機架、PC、螢幕、開發板、遊戲機、家、雲、終端機)加「無」,沒選過是桌機。跟著主機同步(#243)。不取代 agent 頭像(那是 agent 種類)。
_避免_:主機類型、Server icon、主機頭像

**主機分享連結**:
把一台主機的連線設定(名稱、位址、埠、使用者名稱、連線方式、herdr 路徑與 session、host key 指紋;HTTPS 主機是名稱與 HTTPS 位址)編成 `purrdr://host?d=…` 的連結;QR code 的內容就是它。永不含私鑰、密碼、passphrase 或裝置權杖。匯入後仍要通過連線測試才儲存(HTTPS 主機要先在這支裝置連線配對)。
_避免_:匯出檔、Config QR、邀請連結

**Demo 主機**(Demo host):
app 內建、不連任何真實主機的模擬主機，內容是寫好的範例 Agent,讓還沒有主機的使用者(與 App Review)試用。它出現在 Agent 列表時，會一起出現幾台示範主機(演出多主機與連線中斷);兩者都不是使用者存下的主機，不在主機清單、不同步。
_避免_:假主機(那是測試用的)、範例主機、Sample host、Mock host、Sandbox

**Tailscale 重新驗證**(Tailscale check):
Tailscale SSH 的規則要求連線端定期在瀏覽器重新登入 Tailscale(Tailscale 稱 check mode)。主機給一個驗證網址，驗證完連線才會繼續。UI 稱「Sign In to Tailscale」。
_避免_:二次驗證、2FA、re-auth

**主機服務**(Host service):
HTTPS 連線方式在主機上執行的 Purrdr 常駐程式;只聽本機，直接連 herdr 的本機 socket,只提供 herdr 相關操作，不能執行任意指令。
_避免_:Daemon、Agent、Server、主機外掛(主機外掛是推播用的另一個元件)

**連線配對**:
讓一支裝置可以用 HTTPS 連上某台主機的授權流程：主機顯示 QR code,裝置掃描後取得裝置權杖。
_避免_:推播配對(那是推播用的)、Login、Register

**配對碼**(Pairing code):
主機配對指令產生、隨 QR code 顯示的一次性短碼(例如 `K7QM-2XPA`),幾分鐘內有效、用過即作廢;app 用它換裝置權杖。
_避免_:PIN、OTP、密碼

**裝置權杖**(Device token):
連線配對後，主機服務發給某支裝置的憑證;每台主機一組，存在該裝置的 Keychain,可撤銷、可設成唯讀，永不同步。
_避免_:API key、Session token、Pairing token、APNs token(那是推播用的)

**已配對裝置**(Paired device):
和某台主機完成連線配對、持有那台主機裝置權杖的裝置;在主機頁(ⓘ)下方的「已配對裝置」區塊列出，可撤銷別支裝置;撤銷這支裝置走移除主機。
_避免_:通知裝置(那是推播配對的裝置)、Session、Client

## herdr

**Workspace**／**Tab**／**Pane**:
herdr 的三層結構:Workspace 底下有 Tab,Tab 切成多個 Pane;Pane 是真正的終端機。定義以 herdr 官方文件為準。

**Agent**:
在某個 Pane 裡被 herdr 偵測到的 coding agent 程序，例如 Claude Code、Codex。
_避免_:Bot、Assistant、Session

**Agent 狀態**:
herdr 回報的 `blocked`／`working`／`done`／`idle`／`unknown`。UI 上 `blocked` 稱為「需要你」。

**對話紀錄**(Transcript):
Agent 自己寫在主機上的對話檔，app 從這裡讀出對話內容。格式由各 agent 自訂，不是公開 API。
_避免_:Log、History

**Agent 檔案參照**(Agent file reference):
從對話紀錄解析出、Agent 碰過的一個主機檔案：做了什麼(新建、覆寫、修改、讀圖片、工具結果帶的圖、產生圖片)、主機上的絕對路徑，以及對話紀錄當時記下的內容或修改摘要、大小(可能沒有)。只來自對話紀錄，不連主機。
_避免_:附件、Attachment、檔案連結

**檔案卡片**(File card):
聊天裡顯示一個 Agent 檔案參照的卡片：檔名、路徑、類型，與寫入的內容或修改摘要。離線也看得到，因為內容來自對話紀錄。圖片的卡片(圖片卡片)另外經主機取檔顯示縮圖。
_避免_:檔案預覽、附件卡、File bubble

**主機取檔**(Host file fetch):
app 從主機讀 Agent 碰過的檔案(圖片縮圖;點開其他檔案時下載到 app 的快取，以 QuickLook 預覽、可分享，上限 25 MiB):先查狀態(存在、大小、版本),再依版本分塊讀取;檔案的版本變了就重讀。只讀 Agent 工作目錄之下(工作目錄是根目錄、家目錄或它的上層時不算),或 Agent 在對話紀錄中自己寫出的路徑(訊息文字、工具呼叫的檔案路徑、圖片生成與 MCP 圖片;使用者 prompt 與工具結果不算)且在系統暫存目錄、Purrdr 上傳或這段對話紀錄的附檔資料夾;主機端解析 symlink(Windows 也解析 junction,路徑不分大小寫)後再檢查一次，開檔後再核對;排除清單(SSH 金鑰、雲端與套件憑證、keychain、瀏覽器設定、shell 歷史、`.env`、Purrdr 主機服務與推播配對資料夾等)一律不讀。圖片超過 8 MiB 不自動載入，等使用者點擊。
_避免_:下載、檔案傳輸、SFTP、主機檔案(那是 Purrdr 自己的設定檔讀寫)

**訊息內路徑**(Path in message):
Agent 訊息文字中的主機絕對路徑(POSIX 或 Windows 磁碟機路徑;含空白的要包在反引號或引號裡)。顯示成可點，點了才經主機取檔，以檔案卡片的開啟流程在 app 內開;網址、`~` 與相對路徑不算。app 與主機服務用同一套規則判斷，所以它也算「Agent 寫出的路徑」(工作目錄以外仍只限暫存、上傳與附檔資料夾)。
_避免_:檔案連結、file URL

**主機更新來源**(Host updates):
每台主機一個，收 herdr 的事件並維持那台主機最新的快照;Agent 列表與聊天畫面都從它讀，不各自讀快照。
_避免_:輪詢器、Poller、事件迴圈、Event loop

## Agent 列表

**Agent 列表**:
所有主機的 Agent 合併成的一個列表，是 app 的首頁。有兩種檢視。
_避免_:Chat list、Inbox、Home

**Spaces 檢視**:
Agent 列表以 workspace 為單位呈現(#275):每台主機的每個 workspace 一段，段落標題是「主機 · workspace」,段內每個 Tab 一列。點 Tab:只有一個 Pane 直接開(Agent 開聊天、其他開 Pane 終端機),多個 Pane 開那個 Tab 的版面圖。UI 稱「Spaces」,繁中也保留英文。
_避免_:Workspace 檢視、Grouped view、Workspace 群組(#103 的可收合群組已移除)

**Agents 檢視**:
Agent 列表每個 Agent 一列，不分 workspace。列的第一行是 workspace 名稱，第二行是「主機 · 最後一句」(#269)。
_避免_:Flat view、Chats 檢視

**已釘選**(Pinned):
使用者在這支裝置上釘到 Agent 列表最前面的聊天，自成一組、不論 Agent 狀態。只存在這支裝置。
_避免_:Favorite、置頂、Starred

**未讀**(Unread):
聊天在這支裝置上次開啟之後，Agent 又有了新的回覆(自己送出的訊息不算)。未讀的「完成」才標示，已讀的完成視為閒置。
_避免_:New、Unseen、Badge

**需處理數量**:
有「需要你」或未讀 Agent 的 workspace 數。
_避免_:Badge count、Notifications

## 方案用量

**方案用量**(Plan usage):
某種 Agent 的服務方案(例如 Claude 的 Pro／Max)在一個用量週期內已用掉的比例與重置時間。屬於服務方案，不屬於主機：主機只是讀取它的地方，同一個方案在不同主機讀到的是同一份。只在使用者打開方案用量畫面或手動重新整理時查詢，查詢不啟動 Agent、不花 token。
_避免_:用量(單獨使用時，會與 context 用量、token 數混淆)、額度、Usage

**用量週期**:
服務方案計算方案用量的時間範圍，例如 5 小時、每週;各有自己的重置時間。
_避免_:視窗(那是 iPad 的 app 視窗)、Window

## 視窗

**視窗**(Window):
iPad 上 app 的一個視窗，有各自的導覽狀態(側欄、列表、開著的聊天);主機與 Agent 列表所有視窗共用。UI 一律稱「視窗」。
_避免_:Scene、分頁(Tab 是 herdr 的層級)

## 隱私

**App 鎖**(App Lock):
開啟後，冷啟動與離開超過 1 分鐘再回來時，要以 Face ID／Touch ID(失敗可改用裝置密碼)解鎖才看得到內容;多工切換畫面遮蔽內容。設定只存在這支裝置。
_避免_:螢幕鎖、隱私鎖、Passcode lock

## 終端機

**Pane 終端機**:
接到某個 herdr Pane 的終端機畫面。

**登入 Shell**(Login shell):
直接在主機上開的一般 shell,背後沒有 herdr Pane。
_避免_:Raw SSH、Console

**輸入元件**(Terminal input view):
Pane 終端機與登入 Shell 接收鍵盤輸入的 Purrdr 元件，放在遠端游標格子上;鍵盤焦點在它身上，不在終端機模擬器。組字期間不送任何東西，確認的文字與按鍵才送到遠端。
_避免_:隱藏輸入框、Key catcher、SwiftTerm 輸入

## 輸入

**組字**(Composition):
用輸入法(注音、拼音、日文等)打字時，選字確認前的暫時文字與其狀態。確認(選字、按 Return)才變成真正的輸入;系統結束組字時，組字文字不含注音與聲調就當確認的文字送出(注音點候選字),含注音就放棄;Purrdr 自己結束組字時一律放棄，不送出。
_避免_:預編輯、Preedit、Marked text(UIKit 的實作名稱，只在程式碼對應 UIKit API 時用)

**組字浮層**(Composition overlay):
終端機畫面上，把組字文字畫在遠端游標格子的那一層;確認或放棄組字後消失。
_避免_:預覽框、IME 浮窗、Inline preedit

**停止列**(Stop bar):
agent 工作中或有停止結果時，聊天輸入卡片最上面的那一列;放停止鈕、停止中與停止或強制結束的結果。
_避免_:停止按鈕列、中斷列、狀態列、Toolbar、Stop banner

**強制結束**(Force Quit):
經使用者確認後對工作中的 agent 送出 Ctrl-C;可能結束 agent 程序，和只送 Esc、中斷這一輪的「停止」不同。
_避免_:強制停止、終止、Kill、中斷(中斷是停止的說法)

**上傳到主機**(Host upload):
聊天輸入列把使用者挑的圖片或檔案放到主機的 Purrdr 上傳資料夾(`~/.purrdr/uploads`),再把主機上的絕對路徑放進 prompt;圖片在送出時上傳，檔案挑好就上傳、路徑插入輸入框。SSH 與 HTTPS 主機共用同一個介面。
_避免_:附件上傳、傳檔、SFTP、檔案傳輸(主機取檔是反方向)

**展開編輯**(Expanded composer):
從聊天輸入列打開的大編輯畫面(large sheet),編輯同一份草稿;畫面本身稱「展開畫面」。
_避免_:全螢幕編輯、Fullscreen editor、大輸入框

## 推播

**Purrdr 後台**(Backend):
由 Purrdr 營運的伺服器，負責會員登入、訂閱權限、主機同步與推播轉送;保管 APNs 金鑰。聊天與終端機不經過它。
_避免_:推播中繼、Relay、Push server、API server

**主機外掛**(Host plugin):
裝在主機 herdr 上的 plugin,在 Agent 狀態改變時通知 Purrdr 後台。是推播的選用元件，聊天與終端機不需要它。
_避免_:Watcher、Daemon、Agent(會跟 Agent 混淆)

**推播配對**:
一台主機與一支裝置之間的推播授權，以配對密鑰識別。一台主機可以配對多支裝置，一支裝置也可以配對多台主機。
_避免_:Registration、Pairing token

**推播外掛安裝**(Push plugin installer):
App 對「一支裝置 × 一台主機」的推播主機端操作：查狀態、安裝(寫推播配對，必要時裝主機外掛)、移除(刪這支裝置的配對，最後一支時移除 Purrdr 裝的外掛)。SSH 主機以 `herdr plugin install` 實作;HTTPS 主機由主機服務代為執行。
_避免_:Push host、推播主機

**通知裝置**(Push device):
會員名下會收到通知的一支裝置(至少一組推播配對);同一支裝置在多台主機的配對以裝置 id(存 Keychain 的推播裝置 id,也是主機上配對資料夾的名稱)歸成一台。帳號頁可遠端關閉(撤銷它所有的配對)與改名;舊版 app 的裝置沒有名稱，顯示「未命名裝置」。
_避免_:Device token(那是 APNs 的)、推播主機

## 會員

**會員**(Member):
以 Sign in with Apple 或 Google 登入 Purrdr 後台的使用者身分;一個會員可以連結兩種登入方式，用任一種都登入同一個會員。只有訂閱功能需要會員;聊天與終端機不需要登入。
_避免_:用「帳號」指會員這個身分(「帳號」只當畫面名稱，見帳號頁)、User、Account

**帳號頁**(Account):
聊天列表最右上角的帳號鈕開的畫面(#246):會員資料(頭像、名稱、登入方式、登出、刪除會員)與 Purrdr Plus 開通(設定 Purrdr Plus 步驟)。「帳號」只是畫面與按鈕的名稱;領域概念仍是會員，說的是使用者身分時用「會員」。
_避免_:會員頁、帳戶、Profile

**設定 Purrdr Plus 步驟**(Plus setup steps):
帳號頁上依序的四步：加入會員 → 開通 Purrdr Plus → 開啟通知 → 同步主機名單。每步依實際狀態算完成，只有第一個沒完成的步驟能操作;四步完成後收成「Purrdr Plus・已開通」一列。
_避免_:新手引導、Onboarding(那是歡迎頁)

**訂閱**(Subscription):
會員的自動續訂方案(商品名稱 Purrdr Plus)，開通推播與主機同步。可以購買，也可以用 Apple 的 Offer Code 兌換;權限記在會員身上，不記在裝置上。
_避免_:授權碼、License、Pro、Plus(單獨使用時)、推播訂閱

**主機同步**:
把會員的主機清單(主機名稱、連線方式、使用者名稱、host key 指紋或 HTTPS 位址、主機圖示)存在 Purrdr 後台，讓會員的各支裝置共用。私鑰、密碼與裝置權杖永不同步。與 QR code 匯出匯入並存。
_避免_:Backup、Cloud sync
