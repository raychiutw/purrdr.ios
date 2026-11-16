# HTTPS 連線方式：主機服務加 Tailscale Serve

除了 Tailscale SSH 與 OpenSSH,新增第三種連線方式 **HTTPS**,目的是讓不想開放 SSH 的主機(尤其是要另外裝 OpenSSH Server 的 Windows)也能使用 Purrdr。HTTPS 沒辦法只靠 herdr 內建指令做到:herdr 的 API 只有本機 socket(Unix socket／Windows named pipe),沒有網路介面，所以主機上必須有一個 Purrdr 自己的常駐程式，也就是**主機服務**。這部分取代 ADR-0002「主機端零安裝」:零安裝仍是 SSH 連線方式的原則，主機服務只在使用者選 HTTPS 時才安裝。

## 決策

- 主機服務只綁定 127.0.0.1,不自己做 TLS;由 `tailscale serve` 把它公開成 `https://<主機>.<tailnet>.ts.net`,憑證是 Tailscale 代為申請的 Let's Encrypt 憑證，只在 tailnet 內可達。不經過 Purrdr 後台，也沒有其他 relay。
- 主機服務直接連 herdr 官方的本機 socket(NDJSON API),不呼叫 `herdr remote-api-bridge`。最低支援 herdr 0.9.5,可用功能以 herdr 伺服器 `ping` 回報的能力為準。
- 對手機只提供窄 API(Agent 列表與狀態、送 prompt 與按鍵、對話紀錄尾端追蹤、Pane 終端機),**不提供任意指令執行**。因此 HTTPS 連線方式不支援登入 Shell。
- Agent 狀態用 `events.subscribe` 推送，連線與重連時用 `session.snapshot` 對帳;Pane 終端機沿用 ADR-0005 的 `terminal session control`。
- 連線配對：主機顯示含 HTTPS 位址與短效一次性配對碼的 QR code,app 換得這台主機專屬的裝置權杖，存在 Keychain;主機只存權杖的雜湊。權杖可撤銷、可設成唯讀，主機服務留下不含 prompt 與終端機內容的稽核紀錄。
- 手機與主機服務之間：連線配對與撤銷走一般 HTTPS 請求，其餘全部走單一 WSS 連線，以請求識別碼與串流識別碼多工。
- 主機服務用 Swift + swift-nio 實作，協定訊息型別放在 ADR-0006 的可攜核心 package,app 與主機服務共用同一份定義。
- 檔案放在 `~/.purrdr/`(Windows 為 `%USERPROFILE%\.purrdr\`);解除安裝會移除自動啟動與 `tailscale serve` 設定，可完整還原。

## 考慮過但不採用

- **Tailscale Funnel**:服務會暴露在公網，頻寬有限制，而且仍是 beta。
- **Cloudflare Tunnel**:使用者要有帳號與網域，流量經過第三方。
- **自簽憑證加 pinning**:憑證生命週期與信任都要自己處理。
- **經 Purrdr 後台轉送**:違反「聊天與終端機不經過後台」。
- **把 SSH 包進 WebSocket**:主機仍然需要 sshd,沒有解決原本的問題。

以上選項未來可另立 ADR 再評估。

## Consequences

- 使用者要啟用 Tailscale 的 MagicDNS 與 HTTPS Certificates,手機也必須在 tailnet 內;沒有 Tailscale 的使用者仍只能用 OpenSSH。
- 主機 FQDN 會進入公開的 Certificate Transparency 紀錄，安裝流程要先告知使用者。
- 我們要為 macOS、Linux、Windows 發行並維護主機服務，處理自動啟動與版本相容;第一版不做自動更新。
- 上層功能(Agent 列表、聊天、Pane 終端機)只依賴可攜核心的「主機連線」介面,SSH 與 HTTPS 各有一個實作。
- 設計只依據 herdr 官方文件與實測。研究時曾在使用者授權下閱讀 Allymote 的散布檔(`docs/research/allymote-herdr-communication.md`),僅作比較，不相容也不沿用其協定。
