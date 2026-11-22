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
- **主機取檔**(#227)是窄 API 裡唯一讀任意路徑的操作，只有唯讀的「查狀態」與「依版本分塊讀取」。存取規則由主機服務判定，不信任 app 送來的範圍(app、主機服務、SSH 的 POSIX 與 PowerShell 取檔腳本跑同一組案例 purrdr.host 的 `protocol/host-file-access.json`,app 讀同步來的 `vendor/purrdr-host/protocol/`):
  - 工作目錄以 herdr `session.snapshot` 當下回報的 Agent cwd 為準;cwd 是根目錄、家目錄或家目錄的上層時不算(Agent 在家目錄啟動很常見，否則等於放行整個家目錄)。
  - 工作目錄以外，只放行 Agent 在這條連線定位過的對話紀錄裡**自己寫出**的路徑：assistant 訊息文字中以訊息內路徑規則認得的路徑(#229)、工具呼叫參數的檔案路徑、圖片生成的 `saved_path`、MCP 圖片的 `[Image: source: …]`。使用者 prompt、工具結果內容、讀到的檔案與網頁不算——它們可能被 prompt injection 寫進路徑。而且只限系統暫存目錄(schema 的 `x-temporary-file-locations` 與主機的 `TMPDIR`／`TEMP`)、家目錄的 `.purrdr/uploads` 與這段對話紀錄的附檔資料夾(`<資料夾>/<檔名去掉副檔名>/tool-results`):Agent 寫到家目錄其他地方的檔案，就算被提到也不讀。
  - 先以請求的路徑比對，再以解析 symlink 後的實際路徑比對;開檔時最後一段不跟隨 symlink、不阻塞(FIFO 不會卡住),開檔後以 handle 取得實際路徑(macOS `F_GETPATH`、Linux `/proc/self/fd`、Windows `GetFinalPathNameByHandle`)再核對一次，檢查與開檔之間被換掉也讀不到外面。拒絕相對路徑與 `.`／`..`;Windows 只收磁碟機路徑(UNC 會對外送出 NTLM、ADS 讀到別的資料流)。
  - 排除清單(SSH 金鑰、雲端與套件憑證、keychain、瀏覽器設定與 cookie、shell 歷史、`.env`、git 設定、Windows 認證管理員與 DPAPI、Purrdr 主機服務與推播配對等)定義在協定 schema 的 `x-excluded-file-locations`,主機服務、app 與 SSH 取檔腳本共用同一份;主機服務另外拒讀它實際的 `--state-dir`。
  - 上限 25 MiB(schema 的 `x-maximum-file-size`);版本是內容的 SHA-256,大小與修改時間沒變時沿用不重算;從頭讀時建這條連線的記憶體快照，之後的分塊從快照讀，與 SSH 取檔的語意相同。對話紀錄裡的路徑在連線內增量索引，取檔請求有頻率上限。稽核紀錄記路徑、大小與結果，不記內容。
  - **SSH 連線方式**:「是否 Agent 寫出的路徑」由 app 判斷，取檔腳本只在主機端檢查工作目錄、暫存／上傳／附檔資料夾(以路徑樣式比對 Claude 的 `tool-results`,不知道是哪段對話紀錄)、排除清單與開檔後的核對，也不寫稽核紀錄。理由：SSH 的使用者本來就有這台主機的 shell 權限，取檔規則只是避免 app 誤讀敏感檔案，不是權限邊界;為了驗證對話紀錄而讓腳本解析各種 Agent 的對話紀錄格式，成本高而沒有增加防護。不寫稽核紀錄是因為 ADR-0002 的主機端零安裝：會寫入主機的功能要經同意且可還原，而登入紀錄本來就由 sshd 留下。POSIX 腳本以「先 cd 進檢查過的資料夾再以相對路徑開檔、核對 inode」防止資料夾被換成 symlink;FIFO 在檢查後被換入時，開檔會卡到腳本的閒置時限才結束。
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

## 更新(2026-11-19):主機端搬到 raychiutw/purrdr.host

主機服務(`host-service/`)、主機外掛(`host-plugin/`)、協定(`protocol/` 的 JSON Schema 與範例)、codegen 與主機服務的 Release 都搬到公開 repo [`raychiutw/purrdr.host`](https://github.com/raychiutw/purrdr.host)(保留歷史)。上面「repo 多一個 Rust 專案與 CI」改成在那個 repo;協定仍是先改 JSON Schema 再產生兩端型別，只是 app 這邊以 `scripts/sync-purrdr-host.sh` 拉回產生的 Swift 型別與 `vendor/purrdr-host/protocol/`,CI 以 `--check` 確認沒被手改。一行安裝指令改從 purrdr.host 的 Release 下載;推播外掛來源改成 `raychiutw/purrdr.host/host-plugin`。

## 更新(2026-11-21):上傳檔改放系統暫存目錄(raychiutw/purrdr.host#40、purrdr.ios#326)

聊天上傳的圖片與檔案只是給 Agent 讀一次的暫存檔，不該和設定、配對、推播外掛一起放在家目錄的 `.purrdr/uploads/`(使用者翻家目錄會看到不認得的圖片，主機服務沒在跑時也只有 7 天清理收尾)。主機服務(app 同步的 0.9.0 已含)與 SSH 上傳腳本改寫到**系統暫存目錄**底下的上傳資料夾，兩條連線方式共用同一個位置：

- 位置:macOS／Linux 取 `TMPDIR`(沒設定用 `/tmp`),Windows 取 `%TEMP%`;資料夾名稱在協定 schema 的 `x-upload-folder`(`purrdr-uploads`),Unix 後接 `-<uid>`(例如 `purrdr-uploads-501`),app 讀同步來的 `HostServiceProtocol.uploadFolder`,不自己寫死。系統自己的暫存清理也會收，主機重開機或清暫存時一起清掉。
- 安全:`/tmp` 是共用的，所以 Unix 資料夾權限 0700,且已存在時必須是自己的真資料夾(不是 symlink、擁有者是自己、權限剛好 0700),否則上傳失敗、不寫入(SSH 腳本 exit 71);別的使用者事先在 `/tmp` 放同名資料夾或 symlink 不能讓檔案寫進別人控制的地方。Windows 的 `%TEMP%` 在使用者設定檔底下、繼承它的 ACL,資料夾是 reparse point 時失敗。
- 清理:每次 SSH 上傳順手刪掉新資料夾與舊 `~/.purrdr/uploads/` 裡超過 7 天的檔案,舊資料夾清空後移除;舊資料夾不再寫入。
- 辨識與取檔:聊天認得「上傳的圖片」同時接受新路徑與舊的 `.purrdr/uploads` 路徑(歷史對話紀錄裡還是舊路徑)。主機取檔的放行規則(app 的 `HostFileAccessPolicy`、SSH 取檔腳本、主機服務)對對話紀錄提到的檔案同時放行新資料夾(暫存目錄底下，TMPDIR 不在標準位置時也靠名稱認得)與舊資料夾；**舊資料夾的放行只保留一個版本**，之後移除。排除清單不變：`.purrdr/host-service`、`.purrdr/push-*` 仍拒讀。

## 更新(2026-11-22):使用者 prompt 裡的上傳檔可以讀回

聊天要顯示使用者自己送出的圖片與檔案縮圖(換了手機或重新讀取對話紀錄後，手機上已經沒有原圖),所以主機取檔多放行一種路徑:**使用者 prompt 裡、位在 Purrdr 上傳資料夾之下的路徑**(暫存目錄的 `x-upload-folder`,以及仍在相容期的舊 `.purrdr/uploads`)。

- 只放行上傳資料夾：那裡只有 Purrdr 會寫入，內容就是使用者自己送上去的。prompt 裡的其他路徑仍然不算，避免在 prompt 打一個任意路徑就讓 app 讀主機檔案。
- 排除清單、symlink 解析與開檔後核對照舊;app 的 `HostFileAccessPolicy`、SSH 取檔腳本(POSIX 與 PowerShell)與主機服務一起改，共用案例 `host-file-access.json` 加上對應案例。
- 上傳檔超過 7 天會被清理，之後讀回得到「找不到」,畫面顯示原本的「主機上已找不到」狀態。
