# HTTPS 連線方式：主機服務加 Tailscale Serve

除了 Tailscale SSH 與 OpenSSH,新增第三種連線方式 **HTTPS**,目的是讓不想開放 SSH 的主機(尤其是要另外裝 OpenSSH Server 的 Windows)也能使用 Purrdr。HTTPS 沒辦法只靠 herdr 內建指令做到:herdr 的 API 只有本機 socket(Unix socket／Windows named pipe),官方的多機連線也只走 SSH,沒有網路介面，所以主機上必須有一個 Purrdr 自己的常駐程式，也就是**主機服務**。這是 ADR-0002「主機端零安裝」的例外：零安裝仍是 SSH 連線方式的原則，主機服務只在使用者選 HTTPS 時才安裝。

## 決策

- 主機服務只綁定 127.0.0.1 的固定預設埠(可設定),不自己做 TLS;由 `tailscale serve` 把它公開成 `https://<主機>.<tailnet>.ts.net`,憑證是 Tailscale 代為申請的 Let's Encrypt 憑證，只在 tailnet 內可達。不經過 Purrdr 後台，也沒有其他 relay。app 用系統的公共 CA 信任，不做憑證 pinning。
- 主機服務直接連 herdr 官方的本機 socket(NDJSON API),不呼叫 `herdr remote-api-bridge`。最低支援 herdr 0.9.5,可用功能以 herdr server `ping` 回報的能力為準。
- Pane 終端機沿用 ADR-0005 的 `terminal session control`。它只有 CLI 形式(走 herdr 另一條 client socket,NDJSON API 沒有對應方法),所以主機服務以**子行程執行這支 CLI** 並轉接其 NDJSON;這是主機服務唯一會執行的 herdr CLI。唯讀裝置改執行同一組 CLI 的 `terminal session observe`(只能看、不接管 Pane、不改尺寸),讓唯讀在 herdr 這一層就成立，不只靠主機服務擋輸入。
- 對手機只提供窄 API(Agent 列表與狀態、送 prompt 與按鍵、對話紀錄尾端追蹤、Pane 終端機),**不提供任意指令執行**。因此 HTTPS 連線方式不支援登入 Shell。
- Agent 狀態用 `events.subscribe` 推送，連線與重連時用 `session.snapshot` 對帳。降級例外：herdr server 沒有事件訂閱能力(`herdr_capability_missing`)時，app 每 30 秒重讀 snapshot。沒有推送就無從得知狀態變化，30 秒的間隔讓主機與網路負擔維持在低水準;主機服務本身仍不輪詢。
- 連線配對：主機顯示含 HTTPS 位址與短效一次性配對碼的 QR code,app 換得這台主機專屬的裝置權杖，存在 Keychain;主機只存權杖的雜湊。權杖可撤銷、可設成唯讀，主機服務留下不含 prompt 與終端機內容的稽核紀錄。Tailscale Serve 的身分標頭只識別使用者、不識別裝置，且同機程式可偽造，不能取代裝置權杖，最多當額外檢查。
- 手機與主機服務之間：連線配對與撤銷走一般 HTTPS 請求，其餘全部走單一 WSS 連線，以請求識別碼與串流識別碼多工。
- **主機服務用 Rust 實作**。herdr 本身是 Rust,named pipe 等跨平台本機 IPC 有成熟的 crate(herdr 自己用 `interprocess`),單一執行檔好發行;SwiftNIO 官方只在 macOS、Linux 開發與測試,Windows named pipe 支援查不到。
- 協定以 **JSON Schema** 為唯一定義，放在 repo 中;Rust 端與 app 可攜核心的 Swift 型別都由它產生，並以同一組協定範例做兩端的相容測試。
- **主機取檔**(#227)是窄 API 裡唯一讀任意路徑的操作，只有唯讀的「查狀態」與「依版本分塊讀取」。存取規則由主機服務判定，不信任 app 送來的範圍：工作目錄以 herdr `session.snapshot` 當下回報的 Agent cwd 為準，或路徑以 JSON 字串值完整出現在這條連線定位過的對話紀錄裡;先以請求的路徑比對，再以解析 symlink 後的實際路徑比對解析後的工作目錄;拒絕相對路徑與 `.`／`..`;排除清單(SSH 金鑰、雲端與套件憑證、keychain、Purrdr 主機服務與推播配對等)定義在協定 schema 的 `x-excluded-file-locations`,主機服務、app 與 SSH 取檔腳本共用同一份。上限 25 MiB;版本是內容的 SHA-256,從頭讀時建這條連線的記憶體快照，之後的分塊從快照讀，與 SSH 取檔的語意相同。稽核紀錄記路徑、大小與結果，不記內容。
- 檔案放在 `~/.purrdr/`(Windows 為 `%USERPROFILE%\.purrdr\`);解除安裝會移除自動啟動與 `tailscale serve` 設定，可完整還原。

## 考慮過但不採用

- **Tailscale Funnel**:服務會暴露在公網，頻寬有限制，而且仍是 beta。
- **Cloudflare Tunnel**:使用者要有帳號與網域，流量經過第三方。
- **自簽憑證加 pinning**:憑證生命週期與信任都要自己處理。
- **經 Purrdr 後台轉送**:違反「聊天與終端機不經過後台」。
- **把 SSH 包進 WebSocket**:主機仍然需要 sshd,沒有解決原本的問題。
- **`tailscale serve --tcp`**:不帶身分標頭，也沒有比 HTTPS 模式多得到什麼。
- **Go + tsnet(主機服務自己成為 tailnet 節點)**:tailnet 會多一台裝置，還要另外認證。
- **Swift + swift-nio 寫主機服務**:可共用 Swift 型別，但 Windows 支援未經官方驗證，風險最大。

以上選項未來可另立 ADR 再評估。

## Consequences

- 使用者要啟用 Tailscale 的 MagicDNS 與 HTTPS Certificates,手機也必須在 tailnet 內;沒有 Tailscale 的使用者仍只能用 OpenSSH。
- 主機 FQDN 會進入公開的 Certificate Transparency 紀錄，安裝流程要先告知使用者。
- 我們要為 macOS、Linux、Windows 發行並維護主機服務，處理自動啟動與版本相容;第一版不做自動更新。
- repo 多一個 Rust 專案與 CI;協定變更必須先改 JSON Schema,再重新產生兩端型別。
- app 可攜核心的 HTTPS 實作需要 ADR-0006 清單以外的相依(WSS 的 TLS,例如 swift-nio-ssl),要在 Android 交叉編譯驗證。
- `tailscale serve` 的 HTTPS 模式能否轉送 WebSocket,官方文件沒有明寫，主機服務骨架要先實測。
- 上層功能(Agent 列表、聊天、Pane 終端機)只依賴可攜核心的「主機連線」介面,SSH 與 HTTPS 各有一個實作。
- 設計只依據 herdr 官方文件與實測。研究時曾在使用者授權下閱讀 Allymote 的散布檔(`docs/research/allymote-herdr-communication.md`),僅作比較，不相容也不沿用其協定。
