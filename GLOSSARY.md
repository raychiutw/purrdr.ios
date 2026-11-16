# Purrdr(purrdr.ios)

在 iPhone／iPad 上看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機進那台電腦。這份文件只定義本專案的共同語彙;同一個東西有多種叫法時挑一個，其餘列在 _避免_。UI 文字、型別名稱、測試名稱一律用這裡的詞。實作細節不寫在這裡。

herdr 自己的概念(Workspace、Tab、Pane、Agent 狀態)沿用 herdr 官方文件的英文名稱與定義。

## 連線

**主機**(Host):
使用者的一台電腦，上面跑著 herdr,app 透過 SSH 連進去。一台主機有一種作業系統(macOS、Linux 或 Windows)和一種連線方式。
_避免_:電腦、伺服器、機器、Device、Computer

**連線方式**:
app 登入主機的方式，分成 **Tailscale SSH**(由 Tailscale 依 tailnet 身分放行，不需金鑰或密碼)與 **OpenSSH**(主機自己的 sshd,用金鑰或密碼)。
_避免_:Transport、Auth mode

**選取中主機**:
新聊天開在它上面、套用它的主題、它的錯誤佔滿畫面的那台主機。存在本機，重新啟動後選回同一台。不影響列表上看得到哪些主機：所有主機的 Agent 一律合併在同一個 Agent 列表。
_避免_:目前主機、Active host

**主機分享連結**:
把一台主機的連線設定(名稱、位址、埠、使用者名稱、連線方式、herdr 路徑與 session、host key 指紋)編成 `purrdr://host?d=…` 的連結;QR code 的內容就是它。永不含私鑰、密碼或 passphrase。匯入後仍要通過連線測試才儲存。
_避免_:匯出檔、Config QR、邀請連結

**Tailscale 重新驗證**(Tailscale check):
Tailscale SSH 的規則要求連線端定期在瀏覽器重新登入 Tailscale(Tailscale 稱 check mode)。主機給一個驗證網址，驗證完連線才會繼續。UI 稱「Sign In to Tailscale」。
_避免_:二次驗證、2FA、re-auth

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
把會員的主機清單(主機名稱、連線方式、使用者名稱、host key 指紋)存在 Purrdr 後台，讓會員的各支裝置共用。私鑰與密碼永不同步。與 QR code 匯出匯入並存。
_避免_:Backup、Cloud sync
