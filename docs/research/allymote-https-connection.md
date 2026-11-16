# Allymote 的 HTTPS 連線方式與 Purrdr 新增 HTTPS 連線的設計選項(截至 2026-11-16)

> 目的:Purrdr 目前只有 SSH(Tailscale SSH、OpenSSH)兩種連線方式。使用者想參考 Allymote,新增「HTTPS」連線方式並自行實作。本文整理 Purrdr 現況、Allymote 的公開資訊、可行設計與未決問題。
>
> 標記:**【文件】** = Allymote 或第三方官方文件、公開 release、隨安裝檔附的安裝腳本與 CLI 說明所述;**【實測】** = 本機唯讀觀察(只看檔名、目錄結構、`--help` 輸出);**【推論】** = 由上述推出、未直接驗證;**【未查得】** = 找不到來源,不當成事實。
>
> 方法與界線:Allymote 的伺服器**原始碼不公開**(release repo 只放安裝檔;同組織另一個 repo 的說明明寫 "source stays private",見來源 S2)。本機安裝的 `dist\cli.js` 是隨安裝檔散布的 Node 打包檔,**本次刻意沒有閱讀**(不做逆向;也符合 ADR-0001 的 clean-room 精神)。因此「HTTP/WebSocket 的路徑與訊息格式」**無從得知**,全文只到文件與安裝腳本能說的程度。未讀取 `auth.json`、`server.log`、`vapid.json` 等檔案內容,也沒有啟動、停止或改動 Allymote。

## 摘要

- Purrdr 目前**尚未有實作程式碼**(`src/` 只有 App 圖示),SSH 設計只存在於 ADR 與行為規格;所以「連線抽象層」要在實作時才切,現在是加入 HTTPS 的最佳時機。
- Allymote 的架構:**電腦端跑自己的常駐伺服器(內附 Node.js,只聽本機 127.0.0.1:8765),由 `tailscale serve` 負責 TLS 並只在 tailnet 內公開;手機 app 只接受 https 位址,用 QR code 配對、每台電腦一組裝置權杖;沒有雲端 relay**。
- 關鍵取捨:HTTPS 路線**必然需要在主機上裝 Purrdr 自己的 agent**,這直接違反 ADR-0002「主機端零安裝」。這是最大的決策點,需要新 ADR。
- 建議:做「Purrdr host agent(窄 API)+ 單一 WSS 連線 + `tailscale serve` 提供 TLS(預設)」;Funnel、Cloudflare Tunnel、自簽憑證列為進階選項,不列入第一版。
- Allymote 的傳輸細節(WebSocket 或 SSE、路徑、訊息格式)**未查得**,Purrdr 應自訂協定,不需要也不應該相容 Allymote。

## 1. Purrdr 現況

### 1.1 產品定位與狀態

- Purrdr 是 iPhone／iPad 原生 SwiftUI app(最低 iOS 26、Universal、要上架),用來看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機。**尚未開始實作**。出處:`AGENTS.md`「專案性質」。
- `src/` 底下只有 `src/App/Purrdr/AppIcon.icon/`(`git ls-files` 實測),沒有 Swift 原始碼。
- clean-room(ADR-0001):不讀 herdrchat 原始碼,只依 `docs/research/herdrchat-behavior-spec.md`、herdr 官方文件與實測。**Allymote 同理:只依公開文件與自己的設計,不抄**。
- 詞彙:「連線方式」現在只有兩種,**Tailscale SSH** 與 **OpenSSH**(`GLOSSARY.md`「連線」)。「主機」定義為「app 透過 SSH 連進去」的電腦,新增 HTTPS 後這個定義與「連線方式」兩條都要改。

### 1.2 SSH 的設計(尚未實作)

| 項目 | 內容 | 出處 |
|---|---|---|
| 主機端零安裝 | 不裝任何常駐程式,全部透過 SSH 執行 herdr 內建指令與讀對話紀錄檔;支援 macOS、Linux、Windows | `docs/adr/0002-zero-install-host-over-ssh.md` |
| SSH 套件 | `apple/swift-nio-ssh`;支援 PTY 與 exec 同 channel、`none` 認證(Tailscale SSH)、Secure Enclave P256;不支援 RSA、SFTP | `docs/adr/0003-swift-nio-ssh-no-rsa.md` |
| herdr 存取 | 每個請求開一個 SSH exec channel 跑 `herdr remote-api-bridge`,stdin 寫一行 JSON、讀一行回應;只有 `events.subscribe` 會持續串流 | `docs/research/herdrchat-behavior-spec.md` §3.3(第 648–659 行) |
| 資料流 | 每台主機一條長駐 SSH 連線,上面分 exec、事件串流、對話紀錄 tail、終端機通道 | 同上 §1.2(第 58–77 行) |
| Pane 終端機 | 全平台統一走 `herdr terminal session control`(NDJSON 畫面更新與輸入,不需 PTY);登入 Shell 才用 PTY | `docs/adr/0005-pane-terminal-via-session-control.md` |
| 網路路徑 | 監看網路路徑改變(Wi-Fi↔行動、Tailscale 上下)就丟棄快取 client、重新撥號 | 規格第 1222 行 |
| 可攜性 | 核心邏輯放進不依賴 Apple 專屬 framework 的 Swift package,之後用 Swift SDK for Android 編譯 | `docs/adr/0006-portable-swift-core-for-android.md` |
| 後台 | Purrdr 後台(Cloudflare Worker + D1)只管會員、訂閱、主機同步、推播轉送;**聊天與終端機不經過它** | `GLOSSARY.md`「推播」、ADR-0004、ADR-0007 |

### 1.3 對 HTTPS 路線的含意

- 上層功能(聊天、Agent 列表、終端機)目前被設計成「在一條 SSH 連線上開許多 exec／PTY channel」。HTTPS 路線要替換的是**這條傳輸層**,不是功能層。可接縫(seam)的最小單位,是規格第 1.2 節列的四種通道:herdr socket 單次請求、事件訂閱串流、對話紀錄尾端追蹤、終端機(Pane／登入 Shell)。
- **登入 Shell 與「在主機執行任意 shell 小指令」(探測檔案、上傳圖片等,規格 §1.2)在 HTTPS 路線下沒有天然對應**:agent 若不提供通用 exec,這些功能要各自變成 API。這是範圍膨脹的主要來源(見 §4、§6)。

## 2. Allymote 是什麼

### 2.1 基本資訊

- Allymote 是 iPhone app,「用 iPhone 看和操作電腦上 herdr 裡的 AI agent,只走你自己的 Tailscale 網路」,支援 Claude Code 與 Codex。出處:release 說明(S1、S3)。
- **與 Purrdr 的競品關係很近**:同樣針對 herdr、同樣 iPhone。名稱沿革:release 標題依序出現 Herdr Remote(≤0.2.34)→ Drover Remote(0.2.35)→ Stockrider Remote(0.2.36–0.2.37)→ Allymote(≥0.2.38),最新 0.2.45(2026-11-10)。出處:`gh release list -R aeronan/allymote-releases`(S1)。
- 發行:安裝檔放在 GitHub release,Apple 晶片 Mac、Intel Mac、Windows 各一個 zip,**內附 Node.js,不用另外裝**;需要先裝 Tailscale(電腦與 iPhone 同帳號)與 herdr。出處:v0.2.45 release 說明(S3)。
- 隱私權政策(生效 2026-11-07,適用 app 1.0):開發者不蒐集資料、不經營 relay／雲端,1.0 沒有推播。出處:S4。
- 自動更新:0.2.3 起電腦端會自動更新(agent 都沒在工作時換版);`latest.json` 內有 sha256 與多組簽章欄位(`sig`、`sig2`、`sig3`)。出處:S3、`latest.json`(S1)。簽章演算法與驗證方式【未查得】。

### 2.2 架構(兩個部分,都由使用者自己執行)

出處:隱私權政策 "Who runs what"(S4)、隨 zip 的 `windows-install.ps1`(S5)。

```
iPhone Allymote app  ──HTTPS──►  tailnet  ──►  [tailscale serve :443, 終止 TLS]
                                                     │ http
                                                     ▼
                                       Allymote server(Node.js)127.0.0.1:8765
                                                     │
                                                     ▼
                                                  herdr(同一台電腦)
```

- **電腦端 daemon:有**。Windows 以排程工作在登入時啟動(並每 5 分鐘重跑一次、`MultipleInstances=IgnoreNew`);macOS 有對應的 `macos-autostart.sh`(S5)。伺服器以隨附的 Node.js 執行,不依賴系統 Node。
- **relay:沒有**。【文件】"The developer of Allymote does not operate a relay, a cloud service or any other server that your data passes through."(S4)
- **只聽本機**:安裝腳本把 `tailscale serve --bg --https=443 http://127.0.0.1:8765` 當作公開方式,伺服器本身在 127.0.0.1:8765(S5)。CLI 有 `--dev-bind 127.0.0.1` 與 `--port N` 選項(S6)。【推論】預設綁 loopback,對外一律經 `tailscale serve`。
- **與 herdr 的整合**:安裝時執行 `herdr integration install claude` 與 `herdr integration install codex`(S5)。【推論】伺服器在同機以 herdr 的本機 socket／CLI 取得狀態,細節【未查得】。
- **PWA**:安裝目錄含 `dist/web`(`manifest.webmanifest`、`sw.js`、`index.html`),安裝腳本註解寫「owner 版本有 web app;公開版本用 app 的 QR code 配對」,並印出「Open on the iPhone (Safari): https://<tailnet DNS 名稱>」(S5)。也就是同一個伺服器同時服務 Safari 用的 Web UI;iOS app 是另一個客戶端。

### 2.3 TLS 與憑證

- **TLS 由 Tailscale 負責,不是 Allymote 自己做**。【文件】`tailscale serve` 讓本機服務在 tailnet 內分享,「By default, the device's Tailscale daemon terminates the HTTPS connection」,憑證為自動配發(S7)。
- 憑證來源:Tailscale 的 HTTPS 憑證是 **Let's Encrypt** 簽發(DNS-01),私鑰在本機產生、Tailscale 看不到;需在 admin console 的 DNS 頁面啟用 MagicDNS 與 HTTPS Certificates。【文件】(S8)
- 安裝腳本在 `tailscale serve` 失敗時提示「turn on HTTPS Certificates in the Tailscale admin console (DNS page)」(S5),與 S8 一致。
- **不是自簽、不是 tunnel**。因為是公共 CA 簽發的憑證,iOS 原生 ATS 預設就接受,app 不需要自訂信任或 pinning。【推論】(Apple 頁面無法取得,見 §7 備註)
- **隱私副作用**:Tailscale 文件指出機器的 FQDN 會寫進公開的 Certificate Transparency 紀錄,機器名稱若含敏感資訊不應啟用 HTTPS。【文件】(S8)
- 使用者若有第二台電腦,安裝腳本支援 `-AllowOrigin https://<first>.<tailnet>.ts.net`,CLI 有 `--allow-origin`(可重複)(S5、S6)。【推論】這是 Web UI 跨來源(Origin)白名單,讓在一台電腦上開的頁面能連另一台電腦的伺服器;RFC 6455 說明 `Origin` 的角色是讓伺服器拒絕不想接受的跨來源請求(S10)。

### 2.4 配對與認證

- 電腦上執行 `allymote pair [--readonly] [--url https://<name>.<tailnet>.ts.net:8443] [--port N]` 顯示配對 QR code;app 的「Add Computer → Scan QR Code」掃描(S5、S6)。
- 隱私權政策:配對時送出一次性 **pairing code** 與裝置名稱(形如 "Allymote on iPhone",不送使用者自訂的手機名稱)(S4)。
- 配對成功後 **每台電腦一組 device token**,存在 iOS Keychain(僅裝置解鎖時可讀、不同步 iCloud、不還原到其他裝置)(S4)。
- 管理:`allymote devices list`、`allymote devices revoke <id>`;app 內「Settings → Paired Devices」也可撤銷(S4、S6)。
- `--readonly`:配對出唯讀裝置(S6)。唯讀的實際範圍【未查得】。
- 電腦端有裝置清單與**稽核紀錄(audit log)**(S4);【實測】`~/.allymote/` 下確有 `auth.json`、`audit.log`、`server.log`、`activity.json`、`uploads/` 等檔(只看檔名)。
- App 端:只接受 `https` 位址;可用 Face ID／Touch ID／裝置密碼鎖定 app;附件上傳到電腦、保存 7 天後自動刪除(S4)。
- 沒有帳號、沒有 Allymote 帳號登入(S4)。

### 2.5 終端機如何走 HTTPS、串流機制

- 隱私權政策只說 app 與電腦之間傳輸「agent、終端機畫面和對話」、輸入文字、按鍵、對 agent 問題的回答、啟動 session、附件(S4)。
- **使用 WebSocket、SSE 還是長輪詢、路徑與訊息格式、終端機是真 PTY 還是 herdr terminal session control:全部【未查得】**(需讀伺服器原始碼或抓封包,本次刻意不做)。
- 【實測】`~/.allymote/vapid.json` 這個檔名存在,配合 CLI 的 `notify-test` 指令,【推論】電腦端可能有 Web Push 功能(PWA 用);隱私權政策明說 app 1.0 沒有推播(S4、S6)。不確定、不採信為事實。

### 2.6 小結:Allymote 的設計選擇

| 面向 | Allymote | 來源 |
|---|---|---|
| 主機端 | 常駐 Node 伺服器 + herdr integration | S5 |
| 網路可達性 | 只在 tailnet 內(`tailscale serve`),明講 "never on the public internet" | S5 |
| TLS | Tailscale 終止;Let's Encrypt 憑證 | S5、S7、S8 |
| 雲端 relay | 無 | S4 |
| 配對 | QR + 一次性碼 → 每台電腦一組 device token | S4、S5、S6 |
| 撤銷、稽核 | `devices revoke`、audit log | S4、S6 |
| 更新 | 電腦端自動更新,失敗自動回復舊版 | S3、S5 |
| 傳輸協定細節 | 未查得 | — |

## 3. 可行的 HTTPS 連線設計

共同前提:**需要主機端 Purrdr agent**(下稱 agent;詞彙上避免與 herdr 的 Agent 混淆,可沿用 GLOSSARY 的「主機外掛」旁另立「主機服務」)。沒有 agent,瀏覽器式 HTTPS 無法碰到 herdr 的本機 socket(herdr API 是本機 Unix socket／Windows named pipe,規格第 650 行)。

### 選項 A:agent + WSS,TLS 由 `tailscale serve` 提供(Allymote 路線)

- agent 只聽 127.0.0.1;`tailscale serve --https=443 http://127.0.0.1:<port>` 提供 `wss://<host>.<tailnet>.ts.net`。
- 優點:憑證公共信任、ATS 預設可過;只在 tailnet 內可達;無需自營 relay;與現有「Tailscale SSH」使用者重疊度高。
- 缺點:需啟用 Tailscale HTTPS Certificates 與 MagicDNS;機器名稱進 CT 紀錄(S8);仍要求手機在 tailnet;沒有 Tailscale 的使用者用不了。
- 對現況的差異:這其實只是把「SSH over Tailscale」換成「自訂協定 over Tailscale TLS」,**不能解決 Windows OpenSSH 或不想裝 Tailscale 的使用者**。

### 選項 B:agent + Tailscale Funnel(公開網路)

- Funnel 讓服務經 Funnel relay 暴露到公網,只能用 443、8443、10000,頻寬有不可設定的限制,Funnel 本身為 beta;relay 無法解密流量(S9)。
- 優點:手機不必在 tailnet。缺點:**服務暴露在公網**,認證必須自己做到位(配對權杖、速率限制、稽核);頻寬限制不利終端機串流;beta 狀態。
- 建議不列入第一版。

### 選項 C:agent + Cloudflare Tunnel(`cloudflared`)

- 以 outbound 連線把 agent 掛到自有網域,可搭 Cloudflare Access。**本次未查官方文件,以下為一般知識,【待驗證】**:使用者需有 Cloudflare 帳號與網域;流量經 Cloudflare;WebSocket 受支援。
- 優點:不需要 Tailscale,手機不用 VPN。缺點:使用者要設帳號與網域、流量經第三方、與「不經過任何雲端」的賣點衝突。
- 適合進階使用者的第二階段。

### 選項 D:agent 自己終止 TLS(自簽或自有憑證)+ 憑證釘選

- agent 產生自簽憑證,配對時把憑證指紋放進 QR code,app 以 `URLSessionDelegate` 做 pinning。ATS 預設不接受自簽憑證,需自行處理 authentication challenge(Apple 文件頁無法取得,內容為一般知識【待驗證】,見 §7)。
- 優點:不依賴 Tailscale 或任何第三方;區網、WireGuard、ZeroTier 等都可用。缺點:自己負責憑證生命週期、釘選實作與 App Review 說明;iOS 無法對自簽憑證使用原生系統信任 UI;使用者誤設時風險由我們承擔。
- 可作為「非 Tailscale 使用者」的第二階段。

### 選項 E:走 Purrdr 後台當 relay

- 與 `GLOSSARY.md`「聊天與終端機不經過它」及 ADR-0002 直接衝突;還會讓後台成為流量與隱私的責任主體(會員制 ADR-0007 的法務、成本全部增加)。**不建議**。

### 選項 F:把 SSH 包進 WebSocket(SSH over WSS)

- 保留 swift-nio-ssh 與全部上層邏輯,agent 只做一個 WebSocket → 本機 sshd(或 agent 內建簡易 SSH server)的 TCP 轉送。
- 優點:改動最小、上層完全不變。缺點:**沒有解決「主機要有 sshd」的問題**(Windows 尤其麻煩,這正是想加 HTTPS 的原因之一);等於 SSH 外面再套一層,認證要做兩次。使用者目標若是「避開 SSH」,此選項不符。【推論】

### 比較

| 選項 | 主機要裝 | 手機需 VPN | 第三方依賴 | 公網暴露 | 實作量 | 備註 |
|---|---|---|---|---|---|---|
| A tailscale serve | Purrdr agent | 需 Tailscale | Tailscale | 無 | 中 | 與 Allymote 同路線,推薦第一版 |
| B Funnel | Purrdr agent | 不需 | Tailscale(beta) | 有 | 中 | 認證負擔大 |
| C Cloudflare Tunnel | agent + cloudflared | 不需 | Cloudflare | 經 CF | 中 | 待驗證 |
| D 自簽 + pinning | Purrdr agent | 不一定 | 無 | 看網路 | 高 | 憑證與釘選自負 |
| E 自營 relay | agent | 不需 | Purrdr 後台 | 有 | 高 | 違反既有原則 |
| F SSH over WSS | agent + sshd | 看網路 | 無 | 看網路 | 低 | 沒解決 sshd 問題 |

## 4. 與現有 SSH 抽象層的對接

SSH 層尚未實作,所以可以直接定義傳輸層介面,讓 SSH 與 HTTPS 兩種實作並存(以下為【推論】的設計草案)。

1. **傳輸層協定**:定義(暫名)`HostConnection`,以「功能」而不是「channel」為單位:
   - `herdrRequest(json) -> json`(單次請求,對應 `remote-api-bridge` 一個 exec)
   - `herdrEvents() -> AsyncStream`(`events.subscribe` 串流)
   - `tailTranscript(path) -> AsyncStream`(對話紀錄尾端追蹤)
   - `openTerminal(target) -> TerminalSession`(Pane 終端機走 session control;登入 Shell 用 PTY)
   - `execSmallCommand(...)`(探測檔案、上傳附件等)
2. **SSH 實作**:每個方法對應一個 exec/PTY channel(沿用規格 §3.3)。
3. **HTTPS 實作**:每個方法對應一條 WSS 上的邏輯 stream(以 stream id 多工),或一般 HTTPS 請求(單次請求類)。agent 在主機端把它們轉成對本機 herdr socket、檔案 tail、`terminal session control` 的呼叫。
4. **窄 API 而非通用 exec**:若 agent 提供「在主機任意執行指令」,等於把整個 shell 暴露在權杖之後,權杖外洩即遠端程式碼執行。建議 agent 只暴露 herdr socket 轉送、對話紀錄讀取(限已知 agent 的紀錄目錄)、`terminal session control`、受限的附件上傳;登入 Shell 要不要做**單獨決策**(見未決問題)。
5. **主機模型**:`主機`新增「連線方式 = HTTPS」,欄位為 URL、裝置權杖(Keychain)、agent 版本;不再有使用者名稱、埠、SSH 金鑰。主機同步(ADR-0007)只同步 URL 與名稱,**權杖永不同步**(與「私鑰與密碼永不同步」一致)。
6. **斷線與網路切換**:沿用規格第 1222 行的作法(網路路徑改變丟棄連線重建),WebSocket 要自己做 ping/pong 與逾時(RFC 6455 的 Ping/Pong 控制幀,S10)。
7. **Android**:ADR-0006 要求核心邏輯可在 Android 編譯,只用 Foundation、swift-nio、swift-nio-ssh、swift-crypto。`URLSessionWebSocketTask` 屬 Foundation 網路層,在 Android 上的 `FoundationNetworking` 行為與可靠性【待驗證】(`docs/research/swift-sdk-for-android.md` 第 73–76 行記錄過 Android 上 URLSession 的已知崩潰 issue);備案是用 swift-nio 的 WebSocket 實作(`NIOWebSocket` 與 TLS)。傳輸層介面放在核心 package,實作放 app 層或核心 package 視此驗證結果而定。

## 5. 建議

1. **第一版做選項 A**:Purrdr host agent + 單一 WSS + 由 `tailscale serve` 提供 TLS。理由:與目標使用者(已使用 Tailscale SSH 的人)重疊、憑證公共信任、沒有 relay 與公網暴露、與 Allymote 驗證過的使用者流程一致。
2. **配對流程**(可借鏡 Allymote 的公開行為,自己設計):`purrdr pair` 在主機印 QR(含 URL 與一次性碼,有效期短、只能用一次)→ app 掃描 → 交換為每台主機一組裝置權杖(Keychain,`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)→ 主機可列出與撤銷裝置 → 保留稽核紀錄 → 提供唯讀配對。
3. **agent 只聽 loopback**,對外一律經 `tailscale serve`;agent 本身不處理 TLS(第一版)。啟動時檢查 Origin 與 Host,預設拒絕瀏覽器跨來源請求。
4. **不要相容 Allymote 的協定**:未查得、也不該逆向;自訂版本化協定(握手時交換版本與能力,像 herdr 的 `ping` capabilities)。
5. **先寫新的 ADR**(例如 ADR-0010「HTTPS 連線需要主機服務」)明確修改 ADR-0002:零安裝仍是 SSH 連線方式的原則,HTTPS 連線方式是**選用**且需安裝;同時更新 `GLOSSARY.md` 的「主機」「連線方式」。
6. **範圍切小**:第一版 HTTPS 只支援聊天、Agent 列表、Pane 終端機;登入 Shell、附件上傳、herdr 更新等放後續。
7. TDD:傳輸層介面的契約測試(同一組測試跑 SSH 假實作與 HTTPS 假實作)先寫,agent 協定用 loopback 整合測試。

## 6. 未決問題

1. **最大的問題:是否接受 HTTPS 連線方式需要在主機安裝 Purrdr agent?** 這推翻 ADR-0002 的核心賣點(零安裝),也增加三平台(macOS、Linux、Windows)的安裝、更新、簽章與支援成本。若不接受,則選項 F 或放棄 HTTPS。
2. agent 用什麼語言與發行方式?(Allymote 用內附 Node.js 的打包檔,約 35–41 MB;Rust 單一執行檔、Swift on Linux/Windows 也是候選。)與 herdr 本身的發行(herdr 官方安裝腳本)如何搭配?
3. agent 如何存取 herdr:直接連本機 socket(Unix socket／Windows named pipe),還是執行 `herdr remote-api-bridge`?herdr socket 為 single-shot(規格第 653 行),多工要在 agent 內做。
4. 登入 Shell 與任意檔案操作要不要做?做了就要處理遠端程式碼執行的風險與權限模型。
5. 非 Tailscale 使用者:第二階段選 Cloudflare Tunnel(C)、自簽+pinning(D),還是不支援?
6. 唯讀配對的語意(Allymote 有 `--readonly`,範圍未查得):Purrdr 要唯讀到什麼程度(能否回覆 prompt?能否開終端機?)
7. 與推播(ADR-0004)的關係:agent 取代「主機外掛」嗎?兩者可否合併,減少主機端安裝物?
8. 會員與訂閱(ADR-0007):HTTPS 連線方式是否屬於免費功能?(目前聊天與終端機不需登入,規則 5.1.1)
9. Allymote 的實際傳輸與 API 細節:本文刻意不查。若需要對照,只能由使用者自行以合法方式觀察自己的流量,並先決定是否影響 clean-room 原則。
10. App Store 審查:非 SSH 的「連到使用者自己電腦的 HTTPS」是否有額外揭露要求(隱私權政策、Local Network 權限說明)?【未查得】

## 7. 備註與未能驗證的項目

- Apple 開發者文件(`URLSessionWebSocketTask`、App Transport Security)的網頁以 WebFetch 抓取時只回傳標題,**本次沒有取得原文**,上文凡涉及這兩者的細節(支援 `ws`/`wss`、`sendPing`、ATS 預設不接受自簽憑證與其例外鍵)都屬一般知識,**實作前須對 Apple 官方頁面逐項核對**:S11、S12。
- Tailscale Serve 頁面沒有說明憑證簽發者、身分標頭與 WebSocket 支援;憑證簽發者以 HTTPS 頁(S8)為準;**身分標頭與 WebSocket 經 serve 轉送是否正常:未查得**,需在原型階段實測(對選項 A 非常關鍵)。
- Cloudflare Tunnel 相關敘述未查官方文件。

## 8. 來源

| 編號 | 來源 | 用途 |
|---|---|---|
| S1 | https://github.com/aeronan/allymote-releases(README、`gh release list`、`latest.json`) | 發行與版本沿革、更新簽章欄位 |
| S2 | https://github.com/aeronan/ShareNotes-releases(同組織,描述「source stays private」) | 推論發行者慣例:原始碼不公開;**Allymote 本身是否公開原始碼,以 S1 只放安裝檔為依據** |
| S3 | https://github.com/aeronan/allymote-releases/releases/tag/v0.2.45 | 下載、安裝、自動更新說明 |
| S4 | https://github.com/aeronan/allymote-releases/blob/main/privacy.html | 隱私權政策(無 relay、僅 https、device token、Keychain、稽核、附件 7 天) |
| S5 | 隨 `allymote-windows-x64.zip`(v0.2.45)的 `app/scripts/windows-install.ps1`、`windows-autostart.ps1`、`run.mjs`;本機 `%LOCALAPPDATA%\allymote\app\scripts\` | 安裝流程、`tailscale serve --https=443 http://127.0.0.1:8765`、排程工作、自動更新與回復 |
| S6 | 本機 `allymote --help`(0.2.45)輸出 | CLI:`start`、`pair`、`devices list/revoke`、`notify-test`、`version`;選項 `--readonly`、`--allow-origin` 等 |
| S7 | https://tailscale.com/kb/1242/tailscale-serve | Serve 於 tailnet 內分享、Tailscale daemon 終止 HTTPS |
| S8 | https://tailscale.com/kb/1153/enabling-https | MagicDNS／HTTPS Certificates 啟用、Let's Encrypt、CT 紀錄 |
| S9 | https://tailscale.com/kb/1223/funnel | Funnel 公網暴露、埠、頻寬、beta |
| S10 | https://www.rfc-editor.org/rfc/rfc6455 | WebSocket 握手、`wss`、`Origin`、Ping/Pong(只讀到前 100000 字元,涵蓋本文所引段落) |
| S11 | https://developer.apple.com/documentation/foundation/urlsessionwebsockettask | 【未取得原文,待核對】 |
| S12 | https://developer.apple.com/documentation/security/preventing-insecure-network-connections | 【未取得原文,待核對】 |
| L1 | `AGENTS.md`、`GLOSSARY.md`、`docs/adr/0002`、`0003`、`0004`、`0005`、`0006`、`0007` | Purrdr 現況與約束 |
| L2 | `docs/research/herdrchat-behavior-spec.md` §1.2、§3.3、第 1222 行 | SSH 資料流、bridge 規則、網路切換 |
| L3 | `docs/research/swift-sdk-for-android.md` 第 73–76 行 | Android 上 URLSession 風險 |
