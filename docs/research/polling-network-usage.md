# Purrdr 的輪詢與行動網路流量(截至 2026-11-18)

> **結論**
> 1. **SSH 連線方式**最耗流量的是兩件事，兩者都不是「心跳」:
>    - **Agent 列表預覽**:每個事件都重讀全部 Agent 對話紀錄的檔尾，每個 Agent 最多 48,000 bytes。
>    - **對話畫面輪詢**:每 2 或 4 秒讀一次完整的 `session.snapshot`,只為了取得一個 Agent 的狀態。
>
>    估算一小時前景使用(1 台主機、約 10 個 pane、開著一個聊天):約 **20～45 MB**;列表可見、多個 Agent 在工作時可能**再多 50～150 MB**。
> 2. **HTTPS 連線方式**(`origin/integration/https`,尚未合併)的對話紀錄尾端已改由主機服務推送(`transcript.follow`)。對話輪詢剩下 `agents.list`,約 2 KB。同樣情境估算約 **3～5 MB／小時**(加上新增的對話內容)。
>    - 預覽、`pane.read`、在場回報在 HTTPS 尚未支援，不送就不耗流量，但功能也還沒有。
> 3. herdr 能推送的只有**結構與狀態**(`events.subscribe`、`agent.wait`、`pane.wait_for_output`)。對話紀錄、pane 文字、Claude 用量 herdr 推不了，要靠主機端追檔(HTTPS 主機服務已這樣做；SSH 可用長駐 `tail -f` 式通道，HerdrChat 就是這樣做)。
> 4. 架構上，輪詢間隔分散寫死在 7 個畫面 model 裡，也沒有任何地方讀 `NWPath.isExpensive`／`isConstrained`。建議收斂成每台主機一個「主機更新來源」:推送、long-poll、輪詢都藏在它後面，並依網路狀態調整頻率(第 6 節)。
> 5. **實作後(§7)**:SSH POSIX 約 5～12 MB／小時、HTTPS 約 0.1 MB 加新增內容;SSH 剩下最大的是 working 時每 2 秒的 `pane.read`,Windows 是主機檔案讀取每次上傳的 stub 與腳本。流量守門測試(#168)守住請求次數與位元組。

> 標記:**【程式】** 本 repo 檔案與行號(master `0f4fc51`,HTTPS 分支 `origin/integration/https` `3d27565`);**【文件】** 官方文件或規格;**【原始碼】** 第三方官方原始碼固定連結;**【規格】** `docs/research/herdrchat-behavior-spec.md`(下稱「行為規格」，依 ADR-0001 只讀這份，不讀 herdrchat 原始碼);**【估算】** 由程式推算、未實測;**【未查得】** 找不到一手來源。

---

## 1. 估算方法與共同假設【估算】

- **情境**:1 台主機，約 10 個 pane(8 個 Agent),開著一個 Claude Code 聊天，前景使用一小時，一半時間 Agent 在 working。
- **`session.snapshot`**:錄製檔 `tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/session.snapshot.ndjson` 是 5,312 bytes,內容是 2 workspace、4 tab、4 pane、4 layout、3 agent,約每 pane 1.3 KB。10 個 pane 估約 **13 KB**。【程式】
- **`pane.read`(visible)**:錄製檔 844～2,809 bytes(`pane.read.visible.ndjson`、`pane.read.agents-pane.ndjson`)。真實終端機畫面估 **2～8 KB**。【程式】【估算】
- **SSH 每次請求的固定開銷**:每個 herdr 請求、每次讀對話紀錄都開一條新的 exec 通道(AGENTS.md「herdr client」;`src/PurrdrCore/SSHHostConnection.swift:28`)。每條通道的開銷估約 **1.5 KB**,不含指令與回應:
  - SSH 封包：channel open／confirm、exec request、資料、EOF、exit-status、close,約 10～14 個。
  - 每個封包的加密與 MAC 開銷，加上 TCP/IP 與 Tailscale WireGuard 標頭，約 100～150 bytes。
  - 讀對話紀錄的腳本本身約 0.8～1 KB(`src/PurrdrCore/TranscriptCommand.swift:176-185` 加 `pathPrefix`、`probe`、`stripImages`)。
  - **實測修正(SSH 對話紀錄通道技術評估的實測，見 §7.0)**:SSH 層(含加密與 MAC,不含 TCP/IP 與 WireGuard)POSIX 讀尾端每輪送出 1,792 B(指令 1,660 B)、收到 264 B,扣掉內容後每條通道約 **0.4 KB**。【實測】
  - **Windows 主機大得多**:經 stdin 的腳本(對話紀錄、主機檔案、預覽)每次都要上傳固定 stub(3,250 B)加腳本本身(讀尾端是 4,363 B),實測讀尾端每輪送出 **7,876 B**(約 **7.6 KB** 是 stub 與腳本)、合計 8,176 B,不是上面估的 1.5 KB。herdr 請求在 Windows 包成 `-EncodedCommand`,每次的位元組數**【未實測】**。
- **SSH 沒有壓縮**:swift-nio-ssh 只協商 `"none"` 壓縮演算法。【原始碼】[`SSHKeyExchangeStateMachine.swift`(commit d198592)](https://github.com/apple/swift-nio-ssh/blob/d1985926494b624e751b379009dc83f3395fd88a/Sources/NIOSSH/Key%20Exchange/SSHKeyExchangeStateMachine.swift)
- **WSS 每則訊息的開銷**:WebSocket frame、TLS record、TCP/IP、WireGuard 加起來估約 **100～200 bytes**。WSS 有沒有 permessage-deflate:**【未查得】**(Apple `NWProtocolWebSocket.Options` 沒有相關選項，見 §5.5;主機服務的 tungstenite 設定未查)。

---

## 2. SSH 連線方式的輪詢盤點(master `0f4fc51`)

| # | 輪詢點 | 間隔 | 每次內容與大小【估算】 | 前景／背景 | 增量? | 每小時【估算】 |
|---|---|---|---|---|---|---|
| S1 | **對話畫面**:snapshot → 讀畫面(視情況)→ 對話紀錄尾端 | working／blocked／背景 agents 窗格執行中 **2 秒**，否則 **4 秒**(`ConversationModel.swift:75-78`) | snapshot 約 15 KB;tail 約 2.5 KB+新增行;working 時再加 `pane.read` 約 5 KB(`:1078-1081`,blocked 或面板監看時也讀，`:768-777`) | 只在 `scenePhase == .active` 且畫面可見(`ConversationView.swift:70-72`) | snapshot **全量**;尾端**有游標增量**(`TranscriptReader.swift:144-153`,一次最多 64 KB) | working:約 22 KB × 30 次/分 ≈ **40 MB**;閒置:約 17.5 KB × 15 次/分 ≈ **16 MB** |
| S2 | **在場回報**(`pane.report_metadata`,`phone:on`) | **20 秒**(`ConversationModel.swift:575-584`;ttl 45 秒，`HerdrClient.swift:43-47`) | 約 2 KB(請求約 250 B) | 同 S1 | 不適用 | ≈ **0.4 MB** |
| S3 | **Agent 列表**:`events.subscribe` 長駐通道；每個事件等 250 ms 後重讀 snapshot **加全部預覽** | 事件觸發(`AgentListModel.swift:100-117`、`:233`);失敗退避 1→30 秒(`:236-237`) | snapshot 約 15 KB,**預覽每個 Agent 最多 48,000 bytes**(`TranscriptCommand.swift:274`、`AgentListModel.swift:253-268`):8 個 Agent 最壞約 **390 KB／次** | 列表可見且前景(`AgentListView.swift:99-103`);iPhone 推入聊天後停止(`ComposerView.swift:54` 的註解);iPad 三欄時兩者並行 | snapshot 全量;預覽**每次全量重讀所有 Agent** | 每分鐘 2～6 個事件 ≈ **50～140 MB**(視事件頻率；只有 Agent 列表畫面可見時) |
| S4 | **Subagent 畫面** | 尾端 **2 秒**;結束檢查 **3 秒**(`SubagentModel.swift:66-80`) | 各約 2.5 KB | 前景、畫面可見(`DelegationViews.swift:305-307`) | 尾端有游標 | ≈ **7 MB**(開著時) |
| S5 | **Workflow 卡片** | **3 秒**(`WorkflowModel.swift:49-54`) | 約 2.5 KB(帶 `knownChecksum`,沒變回 `unchanged`) | 執行中或展開、前景(`DelegationViews.swift:212-214`、`:424-426`) | 有 checksum | ≈ **3 MB**(每張追蹤中的卡) |
| S6 | **Claude 用量** | **5 秒**(`ClaudeUsageModel.swift:29`、`:120-128`) | 讀一個小檔，約 3～4 KB(讀檔腳本加開銷) | 同意後、前景(`ClaudeUsageFooter.swift:33-35`) | **無**,每次全檔 | ≈ **2.5 MB** |
| S7 | **主機主題**(`config.toml`) | **10 秒**(`HostThemeModel.swift:27`、`:98-101`) | 約 4～6 KB | 同意後；**沒有 scenePhase 判斷**(`HostThemeViews.swift:31`) | **無** | ≈ **2 MB** |
| S8 | **You should know 註記** | **10 秒**;定位最新檔每 10 分鐘(`YouShouldKnowModel.swift:29-30`、`:56`、`:72-76`) | 約 4 KB | 列表可見時每台主機一份(`AgentListView.swift:92-95`);聊天輸入列**另跑一份**,沒有 scenePhase 判斷(`ComposerView.swift:55`) | **無** | 每台主機 ≈ **1.5 MB**;iPad 兩者同時可見時**加倍** |
| S9 | **SSH keepalive**(`cancel-tcpip-forward` global request) | **20 秒**,15 秒內沒回應就斷線(`SSHHostChannel.swift:37`、`:356-375`) | 約 0.3～0.4 KB 來回 | 連線存在時 | 不適用 | ≈ **0.07 MB** |
| S10 | **事件觸發的額外輪詢** | 回答提示後 0.4 + 0.8 秒(`ConversationModel.swift:745-749`);送 slash 後 0.4 + 0.8 秒、送面板按鍵後 0.3 秒(`:1003`、`:1012`、`:1017-1025`) | 每次同 S1 | 前景 | 同 S1 | 跟操作次數成正比 |
| S11 | **回前景喚醒探測**(`true`) | 背景超過 60 秒才跑一次，期限 3 秒(`WakeProbe.swift:11-12`、`HostsModel.swift:422-433`) | 約 1.5 KB | 回前景 | 不適用 | 可忽略 |
| S12 | **網路路徑改變** | 每次 `NWPathMonitor` 簽章改變都丟掉所有連線並重連(`HostsModel.swift:403-414`、`NetworkPaths.swift`) | 重新握手 SSH(估 5～10 KB)+ S3 一次全量重讀 | 前景 | 全量 | 行動網路切換頻繁時明顯 |

不是輪詢的部分:
- **Pane 終端機**經 `herdr terminal session control` 長駐串流(`PaneTerminal.swift:20`、ADR-0005),畫面有變才送。
- **登入 Shell** 是互動 PTY。

### 2.1 SSH 一小時前景估算【估算】

| 情境 | 主要組成 | 估算 |
|---|---|---|
| 只開一個聊天，一半時間 working | S1(28 MB)+ S2 + S9 | **約 28～30 MB** |
| 再開 Claude 用量、主題、註記 | 再加 S6～S8 | **約 34～37 MB** |
| 列表可見、3～4 個 Agent 交替工作(iPad 三欄) | 再加 S3 | **再多約 50～150 MB** |

不確定性最大的是 S3。每小時的事件數、每份對話紀錄是否超過 48 KB(大於 48 KB 才會滿額)都會影響結果。herdr 對 `workspace.updated` 等事件多常觸發沒有官方說明，下面以實測補上(#159)。

#### 2.1.1 herdr 事件頻率實測(#159)【實測】

- **條件**:2026-11-18,Ray PC(Windows 11)的 herdr 0.9.5(protocol 22),本機 `herdr remote-api-bridge` 唯讀訂閱 42.0 分鐘。主機有 1 個 workspace、7 個 pane;每 2 分鐘讀一次 snapshot 確認狀態，期間 1～2 個 Claude Code Agent 在工作，其餘閒置，使用者也有切換 pane。只送 `session.snapshot` 與 `events.subscribe`,只記事件名稱、加鹽雜湊的 pane id、狀態列舉與時間，不記內容。
- **訂閱**:全部不需 pane 的型別(workspace／worktree／tab／pane 的建立、關閉、改名、移動、更新、focus,`pane.updated`、`pane.exited`、`pane.agent_detected`、`workspace.metadata_updated`、`layout.updated`),加上 7 個 pane 各自的 `pane.agent_status_changed`。
- **snapshot 大小**:7 個 pane 的 `session.snapshot` 回應 10,152 bytes(約 1.45 KB／pane),與 §2 估的 15 KB(8 個 Agent)同量級。

| 事件(wire 名稱) | 42 分鐘總數 | 每分鐘平均 | 每分鐘尖峰 | 10 秒尖峰 |
|---|---|---|---|---|
| `pane.agent_status_changed`(working 8、idle 6、done 3、blocked 1;2 個 pane) | 18 | 0.43 | 3 | 1 |
| `workspace_focused` | 27 | 0.64 | 8 | 3 |
| `tab_focused` | 27 | 0.64 | 8 | 3 |
| `pane_focused` | 27 | 0.64 | 8 | 3 |
| `workspace.updated` | 0 | 0 | 0 | 0 |
| `pane.updated` | 0 | 0 | 0 | 0 |
| `workspace.metadata_updated` | 0 | 0 | 0 | 0 |
| 結構事件(workspace／tab／pane 的建立、關閉、改名、移動,`pane.agent_detected`、`pane.exited`)、`layout.updated`、worktree 事件 | 0 | 0 | 0 | 0 |

- 三個 focus 事件總是同時成組出現(使用者切 pane 一次就各一個),集中在使用者操作的幾分鐘內。
- **wire 名稱不一致**:focus 事件是底線(`pane_focused`),狀態事件是點(`pane.agent_status_changed`),與 `HerdrEvents.swift` 註解與 Fixtures README 假設的 `pane_agent_status_changed` 不同。主機更新來源若要依事件名稱決定是否觸發 snapshot,兩種寫法都要認，並補錄一份真實事件行的 fixture。
- **限制**:只有一台 Windows 主機、單一 workspace、沒有建立或關閉 pane。`pane.updated` 在這台是 0,但 Heeler 在忙碌主機實測 6 秒 34 個(§5.2),終端機標題變動的頻率因平台與 Agent 而異。`workspace.metadata_updated` 是 0,是因為錄製期間沒有 client 回報 metadata;Purrdr 自己的在場回報(S2,每 20 秒、ttl 45 秒)就會讓它出現。

依實測修正 S3:實際 Agent 狀態事件約每分鐘 0.4 個(尖峰 3 個),低於 §2 假設的 2～6 個。以目前「每事件重讀 snapshot 加全部預覽」計算，8 個 Agent 約 0.43 × 60 × 390 KB ≈ **10 MB／小時**(尖峰時段約 70 MB／小時);改成只讀狀態變化的那個 Agent(snapshot 約 15 KB + 一份預覽最多 48 KB)後約 **1.6 MB／小時**。【推論】

---

## 3. HTTPS 連線方式的輪詢盤點(`origin/integration/https` `3d27565`)

| # | 輪詢點 | 間隔 | 每次內容與大小【估算】 | 增量? | 每小時【估算】 |
|---|---|---|---|---|---|
| H1 | **對話畫面**:仍是同一份 `ConversationModel` 輪詢迴圈(`src/PurrdrAgentFeatures/ConversationModel.swift:75-77`、`:375-396`) | 2／4 秒 | snapshot 改走主機服務的 `agents.list`(`src/PurrdrHTTPS/HTTPSHostConnection.swift:54-80`):請求 41 B,回應約每 Agent 250 B(`protocol/examples/server.agents-list-result.json` 2 個 Agent 為 521 B),8 個 Agent 約 **2.3 KB** | 全量，但很小 | working ≈ **4 MB**,閒置 ≈ **2 MB** |
| H2 | **對話紀錄尾端**:`tail` 改由推送的行回答，不經網路(`src/PurrdrHTTPS/HTTPSTranscripts.swift:3-5`、`:52-81`) | 推送;主機服務本機每 250 ms 看一次檔案(`host-service/service/src/transcript_session.rs:18`、`:184`),**這個成本在主機上，不在網路上** | `transcript.update` 只帶新增行，約為實際內容加 100 B(`protocol/examples/server.transcript-update.json` 225 B) | **增量** | 約等於新增的對話內容 |
| H3 | **WSS 心跳** | app 每 15 秒 ping、10 秒內要回 pong(`src/PurrdrHTTPS/HostServiceHeartbeat.swift`);主機服務也每 15 秒 ping、45 秒沒收到任何 frame 就斷線(`host-service/service/src/lib.rs:51-64`、`connection.rs:80`、`:107-125`) | 每次約 150 B,兩個方向都有 | 不適用 | ≈ **0.07 MB** |
| H4 | **Agent 列表**:事件經同一條 WSS(`HTTPSHostConnection.swift:122-180`),每個事件重讀 `agents.list` | 事件觸發 | 約 2.3 KB;預覽 `previews` 在 HTTPS 丟 `unsupported`(`HTTPSTranscripts.swift:25-26`、`AgentListModel.swift:274-284`),**沒有網路流量，但列表也沒有預覽** | snapshot 全量(小) | 可忽略 |
| H5 | `pane.read`、`pane.report_metadata`(在場)、subagent／workflow 讀取 | — | `herdrRequest` 只支援 5 個 method,其他在送出前就丟 `unsupported`(`HTTPSHostConnection.swift:56-72`、`:185-186`) | — | 0(功能缺) |
| H6 | **Pane 終端機** | 推送 `pane.terminal.frame`(`protocol/examples/server.pane-terminal-frame.json`) | 依畫面變化 | 增量 | 依使用 |

**HTTPS 一小時前景估算**:H1 約 3 MB + H3 + 新增對話內容，總計約 **3～5 MB**。【估算】

要注意的是，HTTPS 把 `pane.read`、在場回報、預覽補上後，如果直接沿用 SSH 的輪詢形狀，流量會回升。可以參考:HerdrChat 每次輪詢讀 visible 40 行(行為規格 L328)。

---

## 4. herdr 本身能推什麼

版本:herdr 最新 release v0.9.5 指向 commit `2ecf19a`。下表依 `docs/next/website/src/content/docs/socket-api.mdx`(protocol 22,與 0.9.5 實測相同)與 `docs/next/api/herdr-api.schema.json`。【文件】[socket-api.mdx @2ecf19a](https://github.com/herdrdev/herdr/blob/2ecf19a92fc3a7fff75b6ce3655ef04f4625ec01/docs/next/website/src/content/docs/socket-api.mdx)

- **`events.subscribe`**:長駐，第一行是 ack,之後一行一個事件；不重播訂閱之前的事件；讀太慢會收到 `events_lost` 並斷線，要重訂閱後用 `session.snapshot` 對帳；事件只當「該重讀了」的訊號(L774-817)。
- **可訂閱的事件**(L819-839):
  - workspace／tab／pane 的建立、關閉、改名、移動
  - `pane.updated`(標題變更，不含 spinner)
  - `pane.agent_status_changed`(必須指定 `pane_id`,沒有萬用字元)
  - `pane.output_matched`、`pane.scroll_changed`、`layout.updated`、`workspace.metadata_updated`、worktree 事件
- **沒有** pane 輸出內容的增量串流。`pane.read` 只有 `source`／`lines`／`format`／`strip_ansi`,**沒有** since／cursor／offset(schema `PaneReadParams`;socket-api.mdx L843-855)。
- **等待類 API**:
  - `events.wait`(`match_event` + `timeout_ms`)
  - `agent.wait`(伺服器以事件等狀態)
  - `agent.prompt` 可帶 `wait`(L110-114)
  - `pane.wait_for_output`(等某段文字出現)
- `session.snapshot` 是一次性快照，「不是訂閱」(L118-128)。官方沒有大小說明。**【未查得】**
- `pane.report_metadata` 的 token 有 `ttl_ms`;過期或變更會發 `workspace.metadata_updated`(L727-769)。
- Purrdr 目前只訂閱 16 種事件(`src/PurrdrCore/HerdrEvents.swift`)。Spaces 檢視另加版面事件，以免拖動調整大小時每一步都重讀(同檔 `layout` 的註解)。

| 現在的輪詢 | herdr 能取代嗎 |
|---|---|
| 對話畫面每 2～4 秒的 snapshot(S1、H1) | **可以**。訂閱這個 pane 的 `pane.agent_status_changed` 加 `pane.exited`／`pane.updated`,事件到了才重讀，另留 30 秒安全網(HerdrChat 的作法，見 §5.1) |
| Agent 列表的狀態(S3) | 已經是事件驅動;**預覽**不是 herdr 的東西，取代不了，但事件帶 `pane_id`,可以只重讀那一個 pane 的預覽 |
| 對話紀錄尾端(S1 的 tail、S4) | **不能**,herdr 不管對話紀錄檔。改由主機端追檔推送(HTTPS 已做；SSH 用長駐串流通道) |
| working 時的即時預覽、提示偵測(`pane.read`) | 部分。`pane.wait_for_output` 只能等特定字串，一般畫面內容仍要讀 |
| 在場回報(S2) | 寫入端本來就要定期送(ttl 45 秒)。可以把 20 秒拉長到接近 ttl,例如 30 秒、ttl 45 秒。【推論】 |
| 主題、註記、Claude 用量(S6～S8) | 不在 herdr API 裡;可改成「檔案版本沒變就不回內容」(見 §6) |

---

## 5. 其他實作的做法

### 5.1 HerdrChat(只依行為規格，ADR-0001)

- **對話狀態輪詢的頻率**:快速 = 2000 ms × 使用者選的倍率(1／2／5);**事件串流活著且不需要快速時降到 30 秒**(L324)。參數總表:對話 2 秒×倍率、事件活著 30 秒;列表 3 秒×倍率;失敗退避上限 60 秒(L1666-1667)。
  - Purrdr 閒置時固定 4 秒，沒有 30 秒這一檔，也沒有倍率設定。
- **事件只用來「踢」一次輪詢**:250 ms 去抖；輪詢進行中被踢，做完再補一次(L326、L1405)。
- **指令預算**(R-F01,L1582):每個開著的聊天，working ≤60 次/分、閒置無事件 ≤30 次/分、**閒置有事件 ≤2 次/分**。
- **列表預覽**:每個聊天同樣讀檔尾 48,000 bytes,但**只在第一次、每第 5 次、強制時做完整掃描**;其他時候只掃 active、seq 有變、事件指名或沒有快取的 agent(L967)。
  - Purrdr 每次事件都掃全部 Agent。
- **對話紀錄尾端在 SSH 上是長駐串流**(`tail -c +<游標+1> -f` 等效，逐行 flush),不是輪詢(L72、L950-953)。
  - 陷阱：通道關閉時要停掉主機上的程序。HerdrChat 把 stdin 留給看門程序，讀到 EOF 就殺掉;Windows 沒有對應工具(L953)。
- **只在前景且畫面在最上層時輪詢與訂閱**(L1226、R-S26 L1380)。

### 5.2 Heeler

[ZingerLittleBee/Heeler](https://github.com/ZingerLittleBee/Heeler)(iOS／iPadOS,Swift,Apache-2.0)。依 main 的原始碼 **`9315069`**(2026-11-17)。以下連結都固定在這個 commit;只標檔名與行號的，指同一 commit 的同一檔案。內容只用自己的話描述做法，不引用程式碼。

Heeler 支援三種主機：Herdr TUI(就是 Purrdr 連的 herdr)、herdr-core、tmux([CONTEXT.md L3、L23-29](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/CONTEXT.md#L23-L29))。下面只比對 **Herdr TUI 主機、macOS／Linux** 的路徑。

**傳輸層**【原始碼】
- SSH 用 libssh2(ADR 0011),建置時關掉 zlib 壓縮([`build-native.sh` L122](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Packages/HeelerSSH/Scripts/build-native.sh#L122))。跟 Purrdr 一樣，SSH 層沒有壓縮。
- 每個 herdr RPC 開一條 **direct-streamlocal** 通道直連 herdr socket,寫一行、讀一行就關([`HeelerSSHTransport.swift` L2569-2578](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/HeelerSSHTransport.swift#L2569-L2578)),主機上不起程序。Windows 主機才改成每請求一條 exec `herdr remote-api-bridge`(同檔 L2530-2540)。單一回應上限 1 MiB(L316)。
- 讀對話紀錄等主機檔案用 **SFTP**,而且**保留一條 SFTP 通道**重複使用，不是每次讀檔都開新通道。原始碼註解說明，畫面每幾秒看一次時，每次重開 SFTP 子系統太浪費([L838-850](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/HeelerSSHTransport.swift#L838-L850)、L879-891)。

**1. Agent 列表與狀態**【原始碼】
- **訂閱**:每台主機一個 `EventsSession`,維持一條 `events.subscribe` 通道([`EventsSession.swift` L681](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/EventsSession.swift#L681))。訂閱內容是 15 種全域結構事件、`pane.updated`,再加上**每個 Agent pane 各一個** `pane.agent_status_changed`([`HostConsoleProjection.swift` L1085-1105](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Console/HostConsoleProjection.swift#L1085-L1105))。
- **對帳(snapshot)的時機**:
  - 每次 `.connected`(含重連、重訂閱)讀一次 `session.snapshot`(同檔 L803-809)。
  - 狀態事件先就地更新那個 Agent 的狀態，再排一次 snapshot,用來補標題、最近活動等欄位(L814-821)。
  - 結構事件與 `events_lost` 也排一次 snapshot(L824-826、L1092-1093)。
  - `pane.updated` **只就地套用，不觸發 snapshot**(L822-823)。理由：它每次終端機標題變動都會發，作者實測忙碌主機 6 秒 34 個事件，拿來觸發 snapshot 會一直重讀(L744-750)。
- **合併(coalescing),不是去抖**:同一時間只跑一個 snapshot,跑的期間再來的事件只合併成跑完後的「再一次」(L839-857)。沒有 250 ms 之類的延遲。snapshot 失敗 2 秒後重試([`ConsoleStore.swift` L267](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Console/ConsoleStore.swift#L267)、`HostConsoleProjection.swift` L902-915)。
- **沒有定期安全網輪詢**:列表完全靠事件與 `.connected` 時的 snapshot。所有 `Task.sleep` 都只用在退避、keepalive、重試，沒有固定間隔的 snapshot。
- **pane 集合改變時**:換一組訂閱，做法是關掉事件通道後，在同一條 SSH 連線上立刻重訂閱;接著的 `.connected` 再觸發一次 snapshot([`EventsSession.swift` L368-387](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/EventsSession.swift#L368-L387))。斷線時丟掉以 pane 為範圍的訂閱，因為 herdr 只要其中一個 pane 已經結束就會拒絕整個訂閱(L791-805)。
- **重連退避**:1 秒起、每次 ×2、上限 30 秒、不限次數([L7-27](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/EventsSession.swift#L7-L27))。需要使用者處理的錯誤直接停下，不重試(同處註解;ADR 0011 L37-52)。
- **列表沒有對話預覽**。替代做法是**對話預取**:Agent 的「世代:terminal:種類:狀態:session」鍵改變時(實際上就是每次狀態變化),替那一個 Agent 跑一輪對話讀取(`agent.get` + 對話紀錄增量讀取，見第 2 點)。一次只處理一台主機的一個 Agent,讀到裝置上的快取([`ConsoleStore.swift` L3241-3330](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Console/ConsoleStore.swift#L3241-L3330)、L3355-3357)。要用查詢讀的程式(OpenCode 用 sqlite)不預取(L3283-3286)。

**2. 對話紀錄與 pane 內容**【原始碼】
- **對話畫面的迴圈**([`AgentChatStore.swift` L89-145](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Conversation/AgentChatStore.swift#L89-L145)、L1252-1275、L1324-1353):
  - working、blocked、15 秒內有變化或送出、或背景工作還在跑時，每 **1 秒**一次;其他時候每 **4 秒**一次。
  - 用查詢讀的程式(OpenCode),作用中是 2 秒，逾時一次就加倍，上限 30 秒。
  - **迴圈裡不讀 `session.snapshot`**。Agent 狀態來自列表的事件流。
- **每一輪只對對話紀錄做 SFTP `stat`**,大小與修改時間都沒變就結束([`TranscriptFollower.swift` L189-215](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L189-L215))。
  - 有變化時，先讀游標前 64 bytes 的錨點，確認檔案沒有被改寫，再從**位元組游標**往後讀新增的部分，一次最多 2 MiB(同檔 L17-23、L43、L261-283)。
  - 檔案變小或錨點不符才整份重開。
- **第一次開啟讀檔尾 1 MiB**(L19、L117-160)。之後對話存進裝置快取，保存 30 天([`ChatTranscriptCache.swift` L181](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Cache/ChatTranscriptCache.swift#L181))。下次開啟只核對開頭、錨點與大小，就從快取的游標接著讀，不重讀檔尾([`TranscriptFollower.swift` L162-186](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Source/TranscriptFollower.swift#L162-L186))。
- **不是推送**:SSH 上沒有 `tail -f` 式的長駐串流，也沒有主機端追檔服務。對話紀錄還是輪詢，只是每輪很便宜(一次 stat,沒變就不讀)，又走保留的 SFTP 通道。
- **閒置時補讀 Agent 紀錄**:Agent idle、畫面可見時，每 5 秒以 `agent.get` 重讀這個 Agent 一次。原因是在終端機裡 `/clear`、`/resume` 會換 session,卻沒有狀態事件(`AgentChatStore.swift` L106-110、L1366-1380;`HeelerSSHTransport.swift` L986-989)。
- **Blocked 卡片**:畫面可見而 Agent blocked 時(另有幾種需要看畫面的 idle 情況),每 **1 秒**讀一次 `agent.read` visible、ANSI 格式;回答按鍵後改成每 150 ms 確認(`BlockedCardStore.swift` [L70-78、L90-93](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Chat/Blocked/BlockedCardStore.swift#L70-L93)、L661-675;`HostConsoleProjection.swift` L427-433)。
- **Attach 終端機畫面的用量條**:每 5 秒以 SFTP 增量讀 session 檔([`AgentTerminalView.swift` L467](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Console/AgentTerminalView.swift#L467)、`AgentSessionUsageStore.swift` L34-43)。
- 沒有在場回報(`pane.report_metadata`)。原始碼搜尋不到這個 method。

**3. 前景／背景、網路類型與 keepalive**【原始碼】
- **背景寬限 15 秒**:進背景後，app 以 UIKit 背景執行權限保留連線 15 秒。逾時或被系統收回，就關掉所有事件通道與 SSH 連線;回前景時，每台主機都重新驗證連線([`AppActivityCoordinator.swift` L5-13、L95-100](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Support/AppActivityCoordinator.swift#L5-L100);`ConsoleStore.swift` L445-505;`EventsSession.swift` L340-346)。
- 對話畫面只有在 `scenePhase == .active`、畫面在台上時才算「可見」([`AgentFocusCoordinator.swift` L15-21](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Console/AgentFocusCoordinator.swift#L15-L21)、`AgentDetailView.swift` L407)。不可見就停迴圈，只有 Antigravity 有背景工作時例外(`AgentChatStore.swift` L1240-1250)。
- **網路類型不影響頻率**:整個 repo(含 HeelerSSH、HeelerOverlay)找不到 `NWPathMonitor`、`isExpensive`、`isConstrained`、`allowsConstrainedNetworkAccess`。和 Purrdr 現況一樣，沒有行動網路或 Low Data Mode 的降頻。
- **Keepalive 是 herdr `ping` RPC,不是 SSH keepalive**:每 30 秒檢查一次，**30 秒內有任何成功的 RPC 或事件就跳過**。15 秒沒回應先警告，30 秒判定斷線([`EventsSession.swift` L29-53](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/Sources/Heeler/Transport/EventsSession.swift#L29-L53)、L931-944、L1067-1072)。HeelerSSH 沒有用 libssh2 的 keepalive(原始碼搜尋不到)。

**4. 推播與 Live Activity**【原始碼】
- **觸發點**:Herdr TUI 主機上的 Heeler herdr 外掛，用兩個 `[[events]]` hook 掛在 `pane.agent_status_changed` 上([`herdr-plugin.toml` L44-50](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/herdr-plugin.toml#L44-L50))。每個事件起一個短命的 node 程序，主機上沒有常駐 watcher(ADR 0008 [L3](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0008-agent-notifications-via-plugin-hooks-and-push-relay.md#L3)、L19)。
  - herdr-core 與 tmux 主機才另裝常駐的 Host Helper([`plugin/helper/main.js` L1-2](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/helper/main.js#L1-L2))。
- **通知流程**:等 5 秒去抖，用 herdr 重查狀態，同一狀態去重，用裝置的通知金鑰加密，再對每個裝置 token POST 一次到 relay([`notify-hook.js` L1-14、L194-196](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/src/notify-hook.js#L1-L14);[`notification-config.js` L4、L13-15](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/src/notification-config.js#L4-L15))。失敗最多送 3 次，間隔 1 秒([`push.js` L10、L43-57](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/src/delivery/push.js#L10-L57))。只有 Blocked 與 Done 會通知(ADR 0008 L7)。
- **中繼伺服器**:**有**。開發者架的無狀態 Push Relay(預設 `heeler-apns.bybee.dev`),持有 APNs 金鑰，只轉送密文(ADR 0008 L11-12)。app 在前景時不跳系統通知，改用 app 自己事件流的橫幅(ADR 0008 L9)。
- **Live Activity**:每台主機一個。第二個 hook 去抖 1.5 秒、取最新狀態，計數不變就不送，經同一個 relay 送 update／end。平常 priority 5,只有新出現 Blocked 時用 10(ADR 0014 [L36-49](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/docs/adr/0014-lock-screen-live-activities.md#L36-L49);[`activity-hook.js` L263](https://github.com/ZingerLittleBee/Heeler/blob/9315069f27a5670f2861e0d76f2fbb97575b56f2/plugin/src/activity-hook.js#L263))。
- relay 本身的原始碼不在這個 repo(repo 內的 Worker 是 `adhoc-host/`,用來發佈 ipa)。**【未查得】**
- 這和 Purrdr 的 ADR-0004(主機外掛 + 後台轉送)是同一種架構。

**5. 每小時流量(同 §1 情境)【估算】**

每次 direct-streamlocal RPC 的固定開銷估約 **0.8～1 KB**:channel open／confirm、資料、EOF、close,約 6～8 個 SSH 封包，比 Purrdr 的 exec 通道少了 exec request、exit-status 與啟動指令。保留的 SFTP 通道上，一次 `stat` 來回估約 **0.3～0.4 KB**。

| 項目 | Heeler 做法 | Heeler／小時【估算】 | 對照 Purrdr SSH(§2) |
|---|---|---|---|
| Agent 列表 | 事件 + 每個狀態／結構事件一次 snapshot(約 14 KB),一次只跑一個 | 每分鐘 2～6 個事件 ≈ **1.7～5 MB** | S3:每事件 snapshot **加全部預覽** ≈ 50～140 MB |
| 對話預取 | 狀態變化時只讀那一個 Agent:`agent.get` + stat + 新增內容 | ≈ **0.4～1 MB** + 新增內容 | S3 的預覽是每次全部 Agent × 最多 48 KB |
| 對話畫面 | 1／4 秒一次 SFTP stat;idle 時每 5 秒 `agent.get`;**不讀 snapshot** | working 半小時 ≈ 0.6 MB、idle 半小時 ≈ 0.6 MB,合計 ≈ **1～1.5 MB** + 新增內容 | S1:每 2／4 秒 snapshot + tail(+ `pane.read`)≈ 28 MB |
| Blocked 畫面 | 每 1 秒 `agent.read` ANSI(估 5～15 KB) | **每 blocked 分鐘** ≈ 0.3～0.9 MB | S1 在 blocked 時 2 秒一次 snapshot + `pane.read` |
| 在場回報 | 無 | 0 | S2 ≈ 0.4 MB |
| Keepalive | herdr `ping`,30 秒內有流量就跳過 | ≤ **0.1 MB** | S9 ≈ 0.07 MB |
| 主題、註記、用量 | 用量條只在 Attach 畫面時，每 5 秒增量讀 | 只開 Attach 時才有 | S6～S8 ≈ 6 MB,每次全檔 |
| 首次開啟對話 | 檔尾 1 MiB,之後走快取 | 每個新對話一次 ≤ 1 MB | 每次開啟讀尾端，有游標 |

**估計合計**:Heeler 同情境約 **3～8 MB／小時**,加上新增對話內容;Blocked 的時間越長越多。Purrdr SSH 是 28～37 MB,列表可見時再多 50～150 MB。差距主要來自兩點:**對話迴圈不讀 snapshot**,以及**沒有全量預覽**。Heeler 並沒有比 Purrdr 少輪詢。

- 其他 herdr 行動端 client(Kelpie、herdr-mobile-relay、herdr-remote、shepherdr、herdrm)只看到 GitHub 搜尋簡介，未讀 README。**【未查得】**

### 5.3 聊天協定

- **Discord Gateway**【文件】[docs.discord.com/developers/events/gateway](https://docs.discord.com/developers/events/gateway)
  - Hello(op 10)帶 `heartbeat_interval`,範例 `45000` ms;每次心跳回 Heartbeat ACK(op 11);兩次心跳之間沒收到 ACK 視為「zombied」連線，要斷線並 Resume。
  - Resume(op 6)帶 `session_id` 與 `seq`,只補送漏掉的事件。
  - Transport compression 有 `zlib-stream`、`zstd-stream`。
  - Gateway intents「help you lower the computational burden」:沒選的 intent 那一組事件就不送。
- **Matrix `/sync`**【文件】[spec.matrix.org client-server-api #get_matrixclientv3sync](https://spec.matrix.org/latest/client-server-api/#get_matrixclientv3sync)
  - `since`:「A point in time to continue a sync from」,值是上次的 `next_batch`。
  - `timeout`:「The maximum time to wait, in milliseconds, before returning this request」,預設 0。
  - 也就是 long poll 加上增量 token。Filtering 與 lazy-loading members 用來減少回應內容([#filtering](https://spec.matrix.org/latest/client-server-api/#filtering))。
  - Sliding Sync(MSC4186)仍是提案。**【未查證】**
- **Telegram**【文件】[core.telegram.org/api/updates](https://core.telegram.org/api/updates)
  - 以 `pts`／`qts`／`seq` 偵測缺口。
  - 啟動時、發現缺口、session 遺失、15 分鐘以上沒有更新、收到 `updatesTooLong` 時呼叫 `updates.getDifference` 補增量。
  - 沒有連線時的事件靠推播。
- **Slack**:Socket Mode 以 WebSocket 推送事件。這次沒有開官方頁核對細節。**【未查證】**
- **Signal**:找不到官方對行動端 keepalive 或推播喚醒的說明。**【未查得】**

### 5.4 Apple 平台

- **Low Data Mode**【文件】[`allowsConstrainedNetworkAccess`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowsconstrainednetworkaccess)
  - 原文:「Limit your app's use of constrained network access to user-initiated tasks, and put off discretionary tasks until a nonconstrained interface becomes available」。
  - 做法：把 `allowsConstrainedNetworkAccess`、`allowsExpensiveNetworkAccess` 設為 false,並把 `waitsForConnectivity` 設為 true。
- **`NWPath.isConstrained`**:「whether the path uses an interface in Low Data Mode」(iOS 13+)。【文件】[isConstrained](https://developer.apple.com/documentation/network/nwpath/isconstrained)
  - `isExpensive`(行動網路或熱點)同一系列。Purrdr 的 `NetworkPaths.swift` 只把 `status` 與介面類型做成簽章，**沒有讀這兩個欄位**。【程式】
- **背景推播**【文件】[Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
  - `apns-push-type: background`、`apns-priority: 5`;系統可能節流。
  - 原文:「don't try to send more than two or three per hour」。所以背景推播不能拿來取代即時輪詢，只能當喚醒或通知。
- **`NWProtocolWebSocket.Options`** 只有 `autoReplyPing`、`maximumMessageSize`、`setAdditionalHeaders`、`setSubprotocols`、`skipHandshake` 等，**沒有壓縮或擴充選項**。【文件】[NWProtocolWebSocket.Options](https://developer.apple.com/documentation/network/nwprotocolwebsocket/options)
  - `URLSessionWebSocketTask` 是否協商 permessage-deflate,官方文件沒有寫。**【未查得】**
- 背景執行時 socket 被暫停、前景才保持連線的細節，這次沒有開官方頁核對。**【未查證】**
  - Purrdr 本來就只在 `scenePhase == .active` 時輪詢，回前景跑喚醒探測(`HostsModel.swift:420-433`)。

### 5.5 共通做法(歸納)【推論】

1. 前景用一條推送通道(WebSocket／長駐串流／long poll)取代固定間隔輪詢，事件只當「該重讀」的訊號。
2. 一律用游標或 token 做增量(Discord `seq`、Matrix `next_batch`、Telegram `pts`),斷線後補洞，不重抓全量。
3. 在伺服器端先過濾(Discord intents、Matrix filter),只送需要的東西。
4. 心跳間隔由伺服器決定，量級是數十秒(Discord 範例 45 秒)。背景時斷線，回前景再同步。
5. 行動網路與 Low Data Mode 下，非使用者發起的工作延後或降頻(Apple 原文)。

---

## 6. 架構建議:deepening opportunities(依優先順序)

詞彙採 codebase-design:**module**、**interface**、**depth**、**seam**、**adapter**、**leverage**、**locality**。

現況的問題是**輪詢節奏分散在 7 個淺 module**:`ConversationModel`、`AgentListModel`、`SubagentModel`、`WorkflowModel`、`ClaudeUsageModel`、`HostThemeModel`、`YouShouldKnowModel`。

- 每個都自己 `while … sleep(固定秒數)`,自己判斷前景。
- 每個都直接問 `HerdrClient`／`TranscriptReader` 全量或尾端。
- 網路狀態只用在「路徑變了就重連」。

結果「這台主機一分鐘要送幾次請求」沒有任何地方能回答，也沒有任何地方能依網路狀態調整。

### 6.1 列表預覽改成增量(最便宜、省最多)

- **現況**:`AgentListModel.refresh()` 每個事件都呼叫 `refreshPreviews()`,讀全部 Agent 的檔尾(`AgentListModel.swift:242-268`)。事件帶的 `pane_id`(`HerdrEvent.event(name:paneID:)`)被丟掉。
- **建議**:預覽的決策收進 `TranscriptReader.previews` 背後，或一個小的「預覽快取」module。interface 只有「這次哪些 pane 可能變了」,由它決定要讀誰:
  - 事件指名的 pane、snapshot 中狀態或 seq 有變的、沒有快取的;
  - 完整掃描只在第一次與每 N 次。這是行為規格 L967 的規則，目前 Purrdr 沒有實作。
  - 可再把每檔 48,000 bytes 改成先讀較小的檔尾，找不到可讀訊息才放大。【推論】這一點要另外驗證預覽正確率。
- **好處**:S3 從「每事件 × 全部 Agent × 48 KB」降成「每事件 × 1 個 Agent」,估計省 80～90% 的列表流量。【估算】
- **成本**:小。只改 Features 的 model 與 `TranscriptReader`,不動協定。
- **風險**:漏更新預覽。完整掃描與 30 秒安全網可以兜住。
- **測試接點**:既有 seam 主機通道的 `FakeHost`。用 `expect(TranscriptCommand.previews…)` 斷言送出的請求只含指名的 pane;HTTPS 用 `FakeHostConnection.send(event:toSubscription:)` 推事件。

### 6.2 「主機更新來源」:每台主機一個 deep module,統一狀態推送

- **現況**:
  - `ConversationModel.poll()` 每 2～4 秒讀完整 snapshot,只為了取得一個 Agent(`ConversationModel.swift:390-404`)。
  - 同一台主機的 `AgentListModel` 已經有事件訂閱與 snapshot,但兩者不共用;iPad 三欄時兩條路同時跑。
- **建議**:新增每台主機一個 module(暫名 `HostUpdates`,名稱要先進 GLOSSARY)。
  - **interface**:`agents: 最新 HostSnapshot` 加 `changes(for paneID) -> AsyncStream`(或 `updates() -> AsyncStream<HostSnapshot>`)。
  - **implementation 藏起來的東西**:
    - `events.subscribe`、ack 與 `events_lost` 對帳、退避、250 ms 去抖(目前在 `AgentListModel.run()`,`:100-140`)
    - 訂閱清單變更時重訂閱
    - 事件串流不健康時退回輪詢，健康時只留 30 秒安全網(HerdrChat L324)
  - `AgentListModel` 與 `ConversationModel` 都改成讀它;已有的 `SharedRun`(多視窗共用一份迴圈)也收進來。
  - 對話畫面只在 working／blocked 時才另外讀 `pane.read`。
- **好處**:
  - SSH 對話閒置流量從約 16 MB/h 降到接近 0.5 MB/h(只剩尾端與安全網)。
  - **locality**:「同一台主機只有一份 snapshot」,事件規則只寫一次。
- **成本**:中。要搬移 `AgentListModel` 的訂閱迴圈；`ConversationModel` 改成等事件而非 sleep。
- **風險**:
  - herdr 在背景 agent 執行時回報 idle(`ConversationModel.swift:73-74` 的註解)、多題 AskUserQuestion 期間一直是 blocked 沒有事件(行為規格 L476)。這些情況仍要保留快速輪詢。
  - 要把這些條件寫成 module 內的規則與測試。
- **測試接點**:
  - `FakeHostConnection` 的 `events.subscribe` 保持開著加 `send(event:toSubscription:)`(AGENTS.md「測試慣例」);
  - 注入的 `sleep`(各 model 已有);
  - 斷言「事件之間沒有額外的 `session.snapshot` 請求」。

### 6.3 網路感知的節奏政策(cadence policy)

- **現況**:2、3、4、5、10、20 秒寫死在各 model;`NetworkPaths` 不讀 `isExpensive`／`isConstrained`。
- **建議**:一個 in-process 的純函式 module(暫名 `PollingCadence`)。
  - 輸入：Agent 狀態、推送是否健康、網路(`expensive`、`constrained`)、畫面種類。
  - 輸出：間隔，或「暫停」。
  - 例子：Low Data Mode 時暫停 Claude 用量、主題、註記，在場回報拉到 30 秒以上，閒置對話只留安全網。這樣符合 Apple「discretionary tasks 延後」的建議(§5.4)。
  - `NetworkPaths` 的簽章加上這兩個欄位，由 Seam 3 平台服務注入。
  - 可再提供使用者的「輪詢倍率」設定(HerdrChat 有 1／2／5,行為規格 L324)。【推論】
- **好處**:**leverage**,一個 module 決定所有節奏;測試只要表格式的純函式測試。
- **成本**:小～中。純函式很便宜，接線到 7 個 model 是主要工作；6.2 做完後要接的地方會變少。
- **風險**:Low Data Mode 下「需要你」變慢。working 或 blocked 仍維持快速。
- **測試接點**:純函式直接測(依賴類別 1:in-process)；畫面 model 測試沿用注入的 `sleep`,用 `RecordingSleeper` 斷言間隔(`tests/PurrdrTestSupport/RecordingSleeper.swift`)。

### 6.4 對話紀錄尾端改成「追蹤」interface,讓 SSH 也能推送

- **現況**:
  - `HostConnection.readTranscript(.tail)` 是輪詢形狀。
  - HTTPS adapter 為了配合這個形狀，把推送來的行存進緩衝區，等下一次輪詢來取(`HTTPSTranscripts.swift:52-81`)。所以 `ConversationModel` 仍然每 2 秒醒來一次。
  - 這個 seam 的 interface 比兩個 adapter 都淺：推送的能力被藏起來，卻沒有帶來 leverage。
- **建議**:interface 改成 `followTranscript(path:from:) -> AsyncThrowingStream<TranscriptChunk>`,搭配 `stopFollowingTranscript`(已存在)。
  - HTTPS adapter 直接轉 `transcript.update`。
  - SSH adapter 用長駐 exec 串流(`tail -f` 等效，HerdrChat 的作法，行為規格 L950-953),並處理「通道關閉要殺主機程序」;Windows 先退回在 adapter 內部輪詢。
  - `ConversationModel` 與 `SubagentModel` 不再自己 sleep。
- **好處**:
  - SSH 對話尾端從每 2 秒約 2.5 KB(≈ 4.5 MB/h)降為只傳新增內容；延遲也更低。
  - 兩個 adapter 的形狀一致，「一個 adapter 是假想的 seam,兩個才是真的」這條在這裡成立。
- **成本**:中～大。要寫 SSH 長駐追蹤腳本與 Windows 退路，`FakeHostConnection` 也要補對話紀錄支援(目前丟 `unsupported`)。
- **風險**:
  - 主機殘留 `tail -f` 程序(HerdrChat #4);
  - mawk 緩衝(行為規格 L950);
  - 背景時 iOS 先殺長駐通道(L745)。
- **測試接點**:
  - `FakeHost` 的 `.recorded(…, keepsOpen: true)` 加 `send(stdout:toExecution:)`／`finish(execution:)`;
  - HTTPS 用 `tests/PurrdrCoreTests/Support/FakeHostService.swift`;
  - 主機腳本用 `LocalShellHost` 實跑。

### 6.5 主機檔案的定期讀取改成條件式，並去掉重複迴圈

- **現況**:
  - Claude 用量 5 秒、主題 10 秒、註記 10 秒，每次都回整個檔(S6～S8)。
  - 註記在列表與聊天輸入列各跑一份(`AgentListView.swift:92-95`、`ComposerView.swift:55`)。
  - 主題與輸入列的迴圈沒有 scenePhase 判斷(`HostThemeViews.swift:31`、`ComposerView.swift:55`)。
- **建議**:
  - `HostFiles` 的讀取 interface 加「已知版本」參數，版本沒變就只回一行 `unchanged`。主機檔案讀寫已經有 SHA-256:大小 的版本概念(AGENTS.md「Windows 主機」段)。
  - 註記的輪詢只由每台主機一個 owner 執行(可併入 6.2 的 module)。
  - 前景判斷一致化。
- **好處**:這三項合計從約 6 MB/h 降到 1～2 MB/h【估算】;行為一致。
- **成本**:小。
- **風險**:版本計算本身要讀檔(在主機上，不耗網路)。
- **測試接點**:`LocalShellHost` 實跑讀檔腳本;畫面 model 用 `FakeHost` 斷言帶了已知版本。

### 6.6(較後)SSH 傳輸的每請求開銷

- **現況**:每個 herdr 請求開一條 exec 通道，並在主機上啟動一個 `remote-api-bridge` 程序(行為規格 §3.3)。
- **選項**(都藏在 `SSHHostConnection` adapter 內,**interface 不變**):
  - Heeler 的 direct-streamlocal 直連 socket(§5.2);
  - 一條長駐 bridge 通道多工多個請求。這要確認 herdr 的 bridge 是否接受同一條 stdin 多個請求。**【未查得】**
- **好處**:每請求約 1.5 KB 的開銷變小；延遲降低。
- **成本與風險**:大。Tailscale SSH 是否允許 streamlocal 轉送、Windows named pipe 都要實測，也牽涉 ADR-0002／0003。
- 6.1～6.5 做完後，請求次數已經大幅減少，這項的邊際效益較低。【推論】

### 6.7 讀 Heeler 原始碼後的修正(§5.2)

前面的建議大多以 HerdrChat 行為規格為依據。Heeler 原始碼證實了其中幾點，也有幾處不同:

- **6.1、6.2 方向一致，而且有現成的實作可對照**:
  - Heeler 的對話迴圈完全不讀 snapshot,Agent 狀態只從每台主機一條事件流取得。
  - 列表沒有全量預覽，狀態變化時只讀那一個 Agent。
  - 單靠這兩點，同情境估算就從 Purrdr 的數十 MB 降到個位數 MB。6.1、6.2 應該維持最高優先。
- **30 秒安全網不是必要條件**:
  - Heeler 的列表沒有定期輪詢。它靠三件事保證正確:每次 `.connected` 都 snapshot、事件期間只合併成一次 snapshot、`events_lost` 也觸發 snapshot。
  - HerdrChat 有 30 秒安全網(§5.1)。6.2 可以先不放安全網，改把「重連即對帳」寫成測試;遇到 herdr 漏事件的實際案例再加。【推論】
- **6.2 的去抖可改成合併(single-flight)**:Heeler 不延遲 250 ms,只保證同時一個 snapshot、期間的事件併成一次。延遲較低，請求數上限一樣受控。
- **高頻事件不要拿來觸發 snapshot**:
  - Heeler 實測忙碌主機的 `pane.updated` 6 秒 34 個，所以只就地套用(§5.2)。Purrdr 沒有訂 `pane.updated`(`src/PurrdrCore/HerdrEvents.swift:36-51`),這點沒問題。
  - Purrdr 有訂 `workspace.updated`(同檔 :39),Heeler 的訂閱清單沒有它。§2.1.1 實測 42 分鐘 0 次。
  - **依實測(§2.1.1)的觸發建議**:
    - **觸發 snapshot**(經 single-flight 合併):`pane.agent_status_changed`(每分鐘約 0.4 個、尖峰 3 個)、結構事件(workspace 建立／關閉／改名、`pane.agent_detected`、`pane.exited`;實測 0 次，屬罕見事件)、`events_lost`、連上與重連。
    - **`workspace.updated` 可以保留為觸發**:實測 0 次，single-flight 也限住了最壞情況。不訂也可以(Heeler 不訂);保留的話，主機更新來源的測試要涵蓋「短時間大量 `workspace.updated` 只產生一次 snapshot」。
    - **不觸發，也不必訂閱**:`pane.updated`(Heeler 實測忙碌時 6 秒 34 個)、`*_focused`(使用者切 pane 時成組出現，每分鐘最多 8 組，與 Agent 狀態無關)、`workspace.metadata_updated`(Purrdr 自己的在場回報就會觸發它，訂了會自己觸發自己)、`layout.updated`、`pane.scroll_changed`、`pane.output_matched`。
    - 版面事件(tab／pane 建立關閉、移動)只在 Spaces 檢視需要，維持現狀。
    - 依事件名稱判斷時要同時認點與底線兩種 wire 寫法(§2.1.1)。【推論】
- **6.4 有一個較便宜的替代方案**:
  - Heeler 沒有做 SSH `tail -f` 推送。它用**保留的 SFTP 通道**每 1／4 秒 `stat` 一次，沒變就不讀，有變才從游標讀增量。
  - 這樣避開了 6.4 列的風險：主機殘留程序、mawk 緩衝、Windows 沒有對應工具。代價是每秒一次約 0.3 KB 的 stat。
  - Purrdr 的 swift-nio-ssh 本身不提供 SFTP client,要自己實作 SFTP v3 子集，或改成在一條長駐 exec 通道上跑「stat + 讀增量」的小腳本。【推論】
  - 建議 6.4 的 SSH adapter 先做「保留一條通道、先 stat 再讀」,長駐 `tail -f` 列為之後的選項。interface 仍照 6.4 設計成 `followTranscript`,讓 adapter 自己決定推或輪。
- **6.6 的 direct-streamlocal 已有人在 App Store 等級的 app 用了**:Heeler 每 RPC 一條 streamlocal 通道，碰到 `AllowStreamLocalForwarding no` 就直接請使用者處理，不退回 exec(ADR 0011)。Tailscale SSH 是否允許 streamlocal 仍需實測。**【未查證】**
- **6.3 網路感知超出兩者現況**:Heeler 也沒有讀 `isExpensive`／`isConstrained`。6.3 不是追上同類 app,而是額外的差異化。優先順序可放在 6.1、6.2 之後。
- **Keepalive 可以「有流量就跳過」**:Heeler 的 herdr `ping` 在 30 秒內有任何 RPC 或事件就不送。Purrdr S9 的 20 秒 global request 可以照做，不過現在的量本來就小(≈ 0.07 MB/h)。【推論】
- **背景**:Heeler 進背景保留連線 15 秒，之後全部關閉，回前景時重新驗證。Purrdr 目前是回前景後才探測(`WakeProbe`,背景超過 60 秒)。兩者都靠推播補背景的空窗，推播架構相同(外掛 hook + 無狀態 relay)。

---

## 7. 實作後(spec #154 完成後，integration/polling,2026-11-18)

spec #154 的票都合併後，各輪詢點的新做法與每小時估算。情境同 §1(1 台主機、10 個 pane／8 個 Agent、開著一個聊天、一半時間 working),再加上列表同時可見(iPad 三欄)與每分鐘約 0.43 個 Agent 狀態事件(§2.1.1 實測，一小時約 26 個)。

位元組一律是 **SSH／TLS 層**(含加密與 MAC,不含 TCP/IP 與 WireGuard),與技術評估(§7.0)的量法相同。加上 TCP/IP 與 WireGuard 時，小封包多的項目(追蹤每輪、在場回報)約再多一倍。【推論】

### 7.0 SSH 對話紀錄通道技術評估(摘要)

spec #154 的票(#159～#168)引用的 `docs/research/ssh-transcript-channel-evaluation.md` 從沒有進 repo,完整報告(含它的 §4 量測方法與 §7)已找不到;本文件原本引用它的兩處(§1 的「實測修正」、本節的量法)改指這裡。以下只轉錄 [#154 的留言(2026-11-18)](https://github.com/raychiutw/purrdr.ios/issues/154#issuecomment-6968571128)中的結論，不補寫報告沒留下的內容:

> SSH 對話紀錄通道技術評估完成：建議 **方案 B**——每台主機保留一條 exec 通道跑有自我時限(閒置＋總長)的小腳本，有變才回新增內容。SFTP(自寫、Citadel、libssh2)都不採用：不能在主機剝圖片、Windows 上 sftp-server 開著讀取會擋住換檔、Citadel 與現用 swift-nio-ssh 版本衝突且有出口合規問題、libssh2 需 OpenSSL。實測沒變時每輪 88 B(Windows 現狀 8,176 B)。Windows PowerShell 必須沿用 repo 既有的原始 handle 讀 stdin(#77)。

§1 引用的 POSIX 讀尾端每輪 1,792 B／264 B 也出自這份評估的實測，留言沒有附原始紀錄。方案 B 的實作見 #166(POSIX)、#167(Windows),腳本是 `TranscriptCommand.follow` 與 `WindowsScripts.follow`。

### 7.1 各輪詢點新舊對照

| # | 輪詢點 | 實作前 | 實作後(PR) | 每次大小 |
|---|---|---|---|---|
| S1 快照 | 聊天每 2／4 秒讀整份 `session.snapshot` | 聊天不讀快照，從主機更新來源取得(#163,PR #182);主機更新來源只在連上、訂閱對帳、狀態與結構事件、`events_lost` 時讀，期間的事件合併成一次(#160,PR #171) | 約 13 KB【估算】 |
| S1 畫面 | working／blocked 每 2 秒讀 `pane.read` | **不變**:working 每 2 秒、blocked 與背景 agent 執行中的例外快速路徑仍每 2 秒;閒置時每段最多 3 次找建議 | 2～8 KB【估算】 |
| S1 尾端 | 每 2／4 秒開一條通道讀尾端 | 追蹤(#165,PR #184):SSH 一條長駐通道每輪送一行、沒變只回 `unchanged`(#166 PR #193、Windows #167 PR #197);HTTPS 主機服務推送 | POSIX 每輪 248 B、Windows 296 B【實測】;新增 1 KiB 時 1.4～1.5 KB【實測】 |
| S2 在場回報 | 每 20 秒 | 每 30 秒,ttl 45 秒(#162,PR #169) | 約 0.8 KB(含通道開銷)【估算】 |
| S3 列表預覽 | 每個事件重讀全部 Agent 的檔尾(每個最多 48 KB) | 第一次讀全部，之後只讀事件指名、狀態變化或沒讀過的 Agent,一次一個(#164,PR #181) | 每個 Agent 最多 48 KB |
| S6～S8 用量、主題、註記 | 每 5／10 秒回整個檔;註記列表與輸入列各一份;主題與輸入列沒有背景判斷 | 帶已知版本，沒變只回 `unchanged <i>`;註記與主題每台主機一個讀取者;進背景一律停(#161,PR #170) | 回應從 3～6 KB 降到一行;**請求仍要送讀檔腳本** |
| S9 keepalive | 每 20 秒 | 20 秒內主機傳過任何資料就跳過(#162,PR #169)。聊天開著時追蹤每 2～4 秒就有回應，幾乎不送 | 約 0.3 KB |
| H1 快照 | 聊天每 2／4 秒讀 `agents.list` | 同 S1,聊天不讀 | 約 2.3 KB(8 個 Agent)【估算】 |
| H2 尾端 | 推送進緩衝，聊天每 2 秒醒來取 | 推送直接轉成追蹤事件，聊天不再定時醒來(#165,PR #184) | 新增內容約加 15%【程式:流量守門測試】 |

### 7.2 每小時估算

| 項目 | SSH POSIX | SSH Windows | HTTPS |
|---|---|---|---|
| 快照(連上與對帳 2 + 事件 26) | 約 0.4 MB | 約 0.4 MB + `-EncodedCommand` 開銷【未實測】 | 約 0.07 MB |
| 畫面 `pane.read`(working 每 2 秒約 900 次 + 閒置找建議) | 約 2.3～7.6 MB | 同左 + `-EncodedCommand` 開銷【未實測】 | 0(HTTPS 尚未支援) |
| 尾端追蹤(約 1,360 輪) | 0.34 MB + 新增內容 | 0.40 MB + 每 10 分鐘重開通道 15.7 KB【實測】+ 新增內容 | 只有新增內容 |
| 在場回報(120 次) | 約 0.1 MB | 約 0.1 MB 以上 | 0(尚未支援) |
| 列表預覽(第一次 8 個 + 事件 26 個) | 最多約 1.6 MB | 最多約 1.6 MB + 每次 stub 與腳本約 8 KB【估算】 | 0(尚未支援) |
| 用量、主題、註記(每小時約 1,440 次讀取) | 約 1～2 MB【估算】 | 約 9～12 MB(每次上傳 stub 與腳本約 6～8 KB)【估算】 | 0(尚未支援) |
| WSS 心跳 | — | — | 約 0.03 MB |
| **合計(不含新增內容)** | **約 5～12 MB**(不開用量等三項約 4～10 MB) | **約 5～10 MB,開用量等三項再加 9～12 MB** | **約 0.1 MB** |
| 實作前(§2.1、§3) | 約 34～37 MB,列表可見再加約 10 MB(§2.1.1 依實測修正) | 尾端每輪 8,176 B,單這項就約 11 MB | 約 3～5 MB |

- 新增的對話內容兩種連線方式都另計，每 KiB 約多 0.2 KB 開銷(SSH 實測 1 KiB → 1.4 KB,含請求行)。
- SSH 剩下最大的一項是 **working 時每 2 秒的 `pane.read`**(即時預覽、背景 agents 窗格、提示判斷)。§4 已說明 herdr 沒有畫面增量，要再降只能拉長間隔或只在畫面可見的區塊需要時讀。【推論】
- Windows 剩下最大的是**主機檔案讀取**:條件式讀取省了回應，但每次請求仍上傳約 6～8 KB 的 stub 與腳本。改成長駐通道(同 #167 的做法)可以降到每次幾百 bytes。【推論】
- 與 Heeler 同情境估算的 3～8 MB/小時(§5.2)同量級。

### 7.3 流量守門測試的實測次數【程式:模擬時間】

`tests/PurrdrCoreTests/TrafficGuardTests.swift`(#168)以模擬時間跑本節情境的一小時。用錄製檔(3 個 Agent 的快照 5.3 KB、`pane.read` 0.84 KB、對話紀錄 29 KB),所以位元組比上表小;次數與上表的設計一致。SSH 用 `SSHHostConnection` 經假的 bridge 與本機 shell 實跑對話紀錄腳本，HTTPS 用 `HTTPSHostConnection` 經真的 WebSocket 連假的主機服務。

| 種類 | SSH 次數 | SSH 估算位元組 | HTTPS 次數 | HTTPS 估算位元組 |
|---|---|---|---|---|
| 快照(`session.snapshot`／`agents.list`) | 26 | 155 KB | 26 | 17 KB |
| `pane.read` | 924 | 1,422 KB | 0 | 0 |
| 在場回報 | 121 | 93 KB | 0 | 0 |
| 尾端追蹤 | 1 條通道、1,362 輪 | 600 KB(含新增約 180 行) | 1 次開追蹤、180 次推送 | 206 KB |
| 列表預覽 | 24 | 1,045 KB | 0 | 0 |
| 定位、視窗、訂閱(含 23 個事件)、握手 | 3 | 39 KB | 4 | 5 KB |
| 心跳 | — | — | — | 34 KB(估算) |
| **合計** | | **3.35 MB** | | **0.26 MB** |

測試的上限是 SSH 4.5 MB、HTTPS 0.4 MB,各種類另有次數上限(推算見測試常數的註解)。聊天改回每輪讀快照時，SSH 多約 1,350 次快照(約 8 MB)、HTTPS 多約 1,350 次 `agents.list`(約 0.9 MB),兩個測試都會紅燈(PR #199 附證據)。

---

## 8. 未查得與未查證清單

- 每次請求的位元組數全部是**估算**(由錄製檔大小與 SSH／TLS／WireGuard 封包結構推算)，沒有用實機抓封包量測。建議用 Xcode Network instrument 或主機端 `nettop` 實測一次。
- herdr 各事件的觸發頻率已在 Windows 主機實測(§2.1.1);macOS／Linux 主機、建立與關閉 pane 時、`pane.updated` 在忙碌主機的頻率還沒實測。`session.snapshot` 大小沒有官方說明(實測 7 個 pane 約 10 KB)。
- v0.9.5 定版的 socket-api 文件：§4 依的是 `docs/next`(protocol 同為 22)。
- `URLSessionWebSocketTask`／主機服務(tungstenite)是否協商 permessage-deflate。
- 其他 herdr client(Kelpie 等)的輪詢間隔。Heeler 已依原始碼補上(§5.2);它的 Push Relay 原始碼不在 repo 內，未查得。
- Signal 行動端 keepalive 的官方說明。
- Slack Socket Mode、Matrix Sliding Sync、iOS 背景 socket 暫停的細節(這次沒有開官方頁核對)。
- herdr `remote-api-bridge` 能否在同一條 stdin 處理多個請求。
- iPhone 上推入聊天後列表 `.task` 是否一定取消：只有 `ComposerView.swift:54` 的註解這樣寫，沒有實測。
