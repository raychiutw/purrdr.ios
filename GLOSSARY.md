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

**選取中主機**:
新聊天開在它上面、套用它的主題、它的錯誤佔滿畫面的那台主機。存在本機，重新啟動後選回同一台。不影響列表上看得到哪些主機：所有主機的 Agent 一律合併在同一個 Agent 列表。
_避免_:目前主機、Active host

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

## Agent 列表

**Agent 列表**:
所有主機的 Agent 合併成的一個列表，是 app 的首頁。有兩種檢視。
_避免_:Chat list、Inbox、Home

**Spaces 檢視**:
Agent 列表依主機分組、以 workspace 為單位呈現：只有一個 Agent、沒有其他 Pane 的 workspace 是一列聊天，其餘是一個可收合的 workspace 群組。UI 稱「Spaces」,繁中也保留英文。
_避免_:Workspace 檢視、Grouped view

**Agents 檢視**:
Agent 列表每個 Agent 一列，不分 workspace。
_避免_:Flat view、Chats 檢視

**Workspace 群組**:
Spaces 檢視裡代表一個 workspace 的項目：有兩個以上的 Agent,或有 Agent 以外的 Pane(終端機)時才出現。收合時只有一列標頭(名稱、Agent 數、狀態條),展開後列出底下的 Agent 與終端機。
_避免_:Workspace 卡片、Workspace row、Folder

**已釘選**(Pinned):
使用者在這支裝置上釘到 Agent 列表最前面的聊天，自成一組、不論 Agent 狀態。只存在這支裝置。
_避免_:Favorite、置頂、Starred

**未讀**(Unread):
聊天在這支裝置上次開啟之後，Agent 又有了新的回覆(自己送出的訊息不算)。未讀的「完成」才標示，已讀的完成視為閒置。
_避免_:New、Unseen、Badge

**需處理數量**:
有「需要你」或未讀 Agent 的 workspace 數。
_避免_:Badge count、Notifications

## 視窗

**視窗**(Window):
iPad 上 app 的一個視窗，有各自的導覽狀態(側欄、列表、開著的聊天);主機與 Agent 列表所有視窗共用。UI 一律稱「視窗」。
_避免_:Scene、分頁(Tab 是 herdr 的層級)

## 終端機

**Pane 終端機**:
接到某個 herdr Pane 的終端機畫面。

**登入 Shell**(Login shell):
直接在主機上開的一般 shell,背後沒有 herdr Pane。
_避免_:Raw SSH、Console

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

## 會員

**會員**(Member):
以 Sign in with Apple 或 Google 登入 Purrdr 後台的使用者身分;一個會員可以連結兩種登入方式，用任一種都登入同一個會員。只有訂閱功能需要會員;聊天與終端機不需要登入。
_避免_:帳號、User、Account

**訂閱**(Subscription):
會員的自動續訂方案(商品名稱 Purrdr Plus)，開通推播與主機同步。可以購買，也可以用 Apple 的 Offer Code 兌換;權限記在會員身上，不記在裝置上。
_避免_:授權碼、License、Pro、Plus(單獨使用時)、推播訂閱

**主機同步**:
把會員的主機清單(主機名稱、連線方式、使用者名稱、host key 指紋或 HTTPS 位址)存在 Purrdr 後台，讓會員的各支裝置共用。私鑰、密碼與裝置權杖永不同步。與 QR code 匯出匯入並存。
_避免_:Backup、Cloud sync
