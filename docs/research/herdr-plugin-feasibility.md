# 把主機端功能寫進 herdr plugin 的可行性(截至 2026-11-21)

> 目的：評估能不能把主機服務(`purrdr.host/host-service/`)的功能改寫成 herdr plugin,或讓 plugin 承擔一部分(安裝、啟動、監督、事件)，以及各種做法的取捨。
>
> 標記:**【文件】** herdr 官方文件;**【原始碼】** herdr 官方原始碼;**【實測】** 本機唯讀指令輸出;**【推論】** 由前述推得、未直接驗證;**【未確認】** 找不到一手來源。
>
> 版本:herdr repo `herdrdev/herdr` tag `v0.9.5`(tag 物件 `7573e82`,指向 commit `2ecf19a`,2026-10-14);下面的檔案路徑都相對這個 commit,文件在 `docs/next/website/src/content/docs/`(下稱 `docs/`,https://herdr.dev/llms.txt 列出的 stable 0.9.5 文件就是這個路徑)。本機 herdr client 與 server 都是 0.9.5(`herdr status`)。主機服務以 `purrdr.host` 的 `integration/temp-uploads-and-logs`(`35b0ba0`)為準。
>
> 研究時只執行唯讀指令(`--help`、`plugin list`、`plugin log list`、`plugin action list`、`status`),沒有安裝、移除或改動任何 plugin 與設定。

## 摘要

1. **herdr plugin 不是執行環境，而是「herdr 幫你在特定時機執行一個 argv 指令」**:啟動時(`[[startup]]`)、事件發生時(`[[events]]`)、使用者觸發 action 時，以及開 plugin pane 時。每次都是新的子行程，沒有 shell,沒有沙箱，以使用者身分執行，可呼叫整個 herdr CLI。【文件】`docs/plugins.mdx:6-52`
2. **官方明講 startup hook 是「一次性初始化，不是受監督的 daemon」**,herdr 不會重啟、不會設時限，也不會替 plugin 管背景行程;plugin 自己要在父指令結束前停掉背景行程。【文件】`docs/plugins.mdx:220-222, 256-260`
3. 所以主機服務最核心的部分(對 tailnet 提供 WSS、配對與裝置權杖、Pane 終端機串流、對話紀錄追蹤、Agent 觀察者的計時器)**沒辦法以 plugin 的原生模型實作**。唯一的辦法是讓 startup hook 拉起一支常駐程式，而那支程式就是現在的主機服務，只是換成由 herdr server 帶起來、生命週期綁在 herdr server 上，而且沒有人監督。
4. 真正適合 plugin 的只有「事件觸發、跑完就結束」的功能。現有的 Agent `blocked`/`done` 推播已經是這樣做;Send When Done 的觸發理論上也可以，但佇列的增刪還是要經過手機 → 主機服務。
5. **建議維持現狀**:主機服務維持獨立的常駐程式(LaunchAgent／systemd／HKCU Run),plugin 繼續只負責事件推播。可以考慮另外加一個「便利用」plugin entrypoint(例如在 herdr 裡用 popup pane 顯示配對 QR code),但不要讓 plugin 負責啟動或監督主機服務。
6. Windows 的 herdr plugin 仍是 preview【文件】`docs/windows-beta.mdx:46, 69`,而 HTTPS 連線方式最主要的目標族群正是 Windows 主機(ADR-0010)。把服務綁到 plugin 上，等於把最需要穩定的平台放在最不穩的機制上。

---

## 1. 當初為什麼選常駐服務

- ADR-0002:SSH 連線方式主機端零安裝，只用 herdr 內建指令。
- ADR-0004:推播一定要主機主動通知，所以用 herdr 官方的 plugin 機制，在 `pane.agent_status_changed` 時執行腳本。Windows 的 plugin 仍是 preview,所以 Windows 推播只做 best-effort。
- ADR-0010:HTTPS 連線方式**必須有網路介面**,但 herdr 的 API 只有本機 socket,官方多機連線也只走 SSH,所以需要 Purrdr 自己的常駐程式。它只綁 127.0.0.1,由 `tailscale serve` 公開;對手機只提供窄 API,不提供任意指令執行;用 Rust 寫，是因為跨平台本機 IPC(named pipe)與單一執行檔發行的條件較好。ADR 沒有討論「做成 herdr plugin」這個選項，這份筆記補上這個比較。

## 2. herdr plugin 系統的實際能力

### 2.1 定位與信任模型

- plugin 是「可分享、可執行的工作流程套件」,可以是 Bash、JS、Lua、Rust binary 或任何 argv 指令。herdr 負責安裝、manifest 驗證、快捷鍵、終端機 pane、事件、呼叫 context 與 socket 存取;plugin 自己負責實作語言、相依、檔案與持久狀態。【文件】`docs/plugins.mdx:6-11`
- **沒有另外的 plugin SDK,也沒有受限的指令集，整個 herdr CLI 就是 plugin API**。建議經 `HERDR_BIN_PATH` 呼叫 herdr(Unix socket 與 Windows named pipe 的差異由 CLI 處理),要送原始 JSON 時才用 socket API。【文件】`docs/plugins.mdx:23-29, 291-297`
- **沒有沙箱**:build 與 runtime 指令以使用者身分執行、繼承使用者的環境、可以呼叫整個 herdr CLI。herdr 只驗證 manifest、替每個 plugin 準備自己的 config 與 state 資料夾,「不審查也不隔離 plugin 程式碼」。【文件】`docs/plugins.mdx:35-52`
- manifest **沒有任何權限宣告欄位**(網路、檔案、port 都沒有)。【原始碼】`src/app/api/plugins/manifest.rs:11-99`(`RawPluginManifest` 與各 entrypoint 的欄位)
- v1 不支援在執行期登錄 action,也沒有原生的非終端機 UI;action、事件 hook、pane、link handler 都要在 manifest 宣告。【文件】`docs/plugins.mdx:31-33`;`docs/socket-api.mdx:451-456`
- v1 沒有 herdr 管理的儲存 API,plugin 自己管檔案。【文件】`docs/plugins.mdx:373-376`;`docs/socket-api.mdx:578-580`

### 2.2 Manifest 欄位

【原始碼】`src/app/api/plugins/manifest.rs:11-99`;【文件】`docs/plugins.mdx:54-121`

| 區段 | 欄位 | 說明 |
|---|---|---|
| 頂層 | `id`、`name`、`version`、`min_herdr_version`(必填)、`description`、`platforms` | `min_herdr_version` 比目前 binary 新時拒絕 link／install(`docs/plugins.mdx:101-104`、`docs/socket-api.mdx:521-522`) |
| `[[build]]` | `command`、`platforms` | 只在 GitHub install 時、確認之後執行;**拿不到 runtime context 與 herdr socket 環境變數**;失敗就中止安裝(`docs/plugins.mdx:232-245`) |
| `[[startup]]` | `command`、`platforms` | 每個啟用的 plugin 在 server 還原 session、socket 就緒後執行一次(2.4) |
| `[[actions]]` | `id`、`title`、`description`、`contexts`、`command`、`platforms` | 由快捷鍵、`herdr plugin action invoke`、link handler 觸發 |
| `[[events]]` | `on`、`command`、`platforms` | 事件 hook(2.3) |
| `[[panes]]` | `id`、`title`、`description`、`placement`(`overlay`/`popup`/`split`/`tab`/`zoomed`)、`width`、`height`、`command`、`platforms` | plugin 擁有的終端機 pane(2.5) |
| `[[link_handlers]]` | `id`、`title`、`pattern`、`action`、`platforms` | Ctrl-click 符合的網址時改呼叫 action |

`command` 是 argv 陣列，**不經過 shell**(`docs/plugins.mdx:119-121`)。相對路徑的程式以 plugin 根目錄解析(【原始碼】`src/plugin_command.rs:5-27`)。

### 2.3 可以掛 hook 的事件

只有下列 22 種事件會觸發 plugin hook(【原始碼】`src/api/schema/events.rs:286-309` `PLUGIN_HOOK_EVENT_KINDS`;不在清單裡的事件直接略過，見 `src/app/api/plugins/runtime.rs:203-207`):

- workspace:`created`、`updated`、`closed`、`renamed`、`moved`、`reordered`、`focused`
- worktree:`created`、`opened`、`removed`
- tab:`created`、`closed`、`renamed`、`moved`、`focused`
- pane:`created`、`closed`、`focused`、`moved`、`exited`、`agent_detected`、`agent_status_changed`

link 時會比對 `on` 是不是已知的事件名稱，不認得只回 warning、不擋 link。【文件】`docs/socket-api.mdx:466-470`

### 2.4 執行模型

| 項目 | 實際行為 | 來源 |
|---|---|---|
| 每次觸發 | 開一條 thread spawn **新的子行程**,cwd 是 plugin 根目錄;stdout／stderr 用 pipe 收 | 【原始碼】`runtime.rs:121-142`;【文件】`plugins.mdx:267` |
| 注入的環境變數 | `HERDR_SOCKET_PATH`、`HERDR_BIN_PATH`、`HERDR_ENV=1`、`HERDR_PLUGIN_ID`、`HERDR_PLUGIN_ROOT`、`HERDR_PLUGIN_CONFIG_DIR`、`HERDR_PLUGIN_STATE_DIR`、`HERDR_PLUGIN_CONTEXT_JSON`,以及能取得的 `HERDR_WORKSPACE_ID`／`TAB_ID`／`PANE_ID`;事件 hook 另有 `HERDR_PLUGIN_EVENT`、`HERDR_PLUGIN_EVENT_JSON`(整個事件 envelope 序列化) | 【文件】`plugins.mdx:265-289`;【原始碼】`runtime.rs:39-81, 226` |
| 時限 | **沒有逾時**:worker thread 只是 `child.wait()` 等它結束 | 【原始碼】`runtime.rs:264-307`(整個 runtime 沒有 timeout) |
| 同時執行上限 | 全部 plugin 合計最多 32 個指令在跑，超過就記一筆失敗 log,回 `plugin_command_limit_reached` | 【原始碼】`runtime.rs:12, 82-102, 157`;`src/app/api.rs:173-174` |
| 輸出 | stdout 與 stderr 各保留前 64 KiB,超過標 truncated,但會繼續讀到 EOF(不會因 pipe 滿而卡住);**以子行程結束為準**,子孫行程握著 pipe 不影響完成時間 | 【原始碼】`runtime.rs:11, 284-294, 337-364` |
| 錯誤處理 | 只記錄 exit code／spawn 錯誤，不重試、不通知使用者;startup 失敗不影響 server | 【原始碼】`runtime.rs:130-141, 295-306`;【文件】`plugins.mdx:252-254` |
| Log | 記憶體裡最多 200 筆(`herdr plugin log list`),內容含 command、event、exit code、stdout、stderr | 【原始碼】`runtime.rs:13, 253-259`;【實測】`herdr plugin log list` 回 `plugin_log_list`,現有 `purrdr.push` 每次執行約 10 ms、`succeeded` |
| Log 是否跨 server 重啟保留 | 只看到存在 `AppState`,persist 模組沒有引用 | 【推論】`src/app/state.rs:881` 一帶;`src/persist*` 搜不到 `plugin_command_logs` |
| 事件 hook 的觸發點 | `emit_event` 先同步跑 `run_plugin_event_hooks`(每次先重讀 plugin registry)再推給事件訂閱者;每個 hook 各自一條 thread,**不保證同一 pane 多個事件的 hook 依序完成** | 【原始碼】`src/app/api.rs:795-798`;`runtime.rs:203-251`;順序部分是【推論】 |
| 子行程的 process 設定 | Unix 沒有額外設定(沒有 setsid、沒有另開 process group);Windows 只加 `CREATE_NO_WINDOW` | 【原始碼】`src/noninteractive_process.rs:4-8`;`src/platform/mod.rs:235-240`;`src/platform/windows.rs:1358-1362` |

### 2.5 能不能常駐、開 port／socket、呼叫 herdr API

- **常駐**:官方定位明確是否定的。「startup hook 是一次性的初始化指令，不是受監督的 daemon。hook 應該還原 plugin 擁有的狀態、呼叫需要的 herdr API,然後結束。」【文件】`docs/plugins.mdx:256-260`。技術上 startup hook 可以不結束(沒有逾時，2.4),但這樣會:
  - 永久佔掉 32 個指令名額中的一個，log 永遠停在 `running`【原始碼】`runtime.rs:82, 104-117`;
  - 沒有人在它掛掉時重啟(只有 server 啟動與 live handoff 時跑)【文件】`docs/plugins.mdx:249-254`;【原始碼】`src/server/headless/bootstrap.rs:93, 206`;
  - **live handoff 時新 server 會再跑一次 startup hook**,而舊 server 底下的那支是否還活著【未確認】,要自己做單例鎖;
  - 官方要求「plugin 必須在父指令或 pane 結束前停掉 detach 的背景行程」,server 結束後還活著的行程「不受 cleanup 保護」(安裝檔可能被清掉)【文件】`docs/plugins.mdx:217-223`。
- **plugin pane** 是另一種長時間執行的方式：pane 指令跑在一般的 herdr 終端機 pane(或 popup)裡，跟著 pane 存活。不過它出現在使用者的版面上，使用者關掉就結束;server 重啟後 pane 的原行程也不在了(session 只還原形狀)。【文件】`docs/plugins.mdx:299-338`;`docs/session-state.mdx:31`。適合互動式 UI(例如顯示 QR code),不適合當背景服務。
- **開 port／socket**:herdr 不限制，因為沒有沙箱(2.1)。但 manifest 沒有網路權限宣告，herdr 也不提供任何網路介面給 plugin。【文件】`docs/plugins.mdx:35-52`;【原始碼】`manifest.rs:11-99`
- **呼叫 herdr API**:可以，而且是整個 CLI／socket API,包含 `events.subscribe`、`pane.send_text`、`agent.prompt`、`pane.read`,與主機服務現在用的介面相同。【文件】`docs/plugins.mdx:23-29`;`docs/socket-api.mdx:112`(plugin 方法表)
- **生命週期綁在 herdr server 上**:plugin 只在有 herdr server 時被呼叫。herdr server 由 `herdr` 指令帶起，detach 後繼續跑，`herdr server stop` 才停。【文件】`docs/persistence-remote.mdx:12-16`。官方文件沒有提到登入時自動啟動 herdr server 的機制【未確認】。另外，官方疑難排解提到舊版 server 跨登出存活時會失去使用者查詢與 DNS,handoff 會沿用來源 server 的服務環境【文件】`docs/troubleshooting.mdx:94`:掛在 server 底下的網路服務也會繼承這種環境問題。
- **named session**:每個 named session 是獨立的 server 與 socket,plugin 卻是全使用者共用、每個 server 都會跑 startup hook。【文件】`docs/plugins.mdx:204-206`;`docs/socket-api.mdx:632-641`(socket 路徑)。常駐程式若由 startup hook 帶起，同時開多個 session 就要處理多實例。【推論】

### 2.6 安裝、更新、移除

- `herdr plugin install <owner>/<repo>[/subdir]`:**只接受 GitHub 簡寫，用 `git` clone**,互動終端機會先顯示預覽，`--yes` 跳過，`--ref` 固定版本，在新的 herdr 管理安裝資料夾裡 build 後登錄。【文件】`docs/plugins.mdx:169-199`;【實測】`herdr plugin install --help`
- `herdr plugin update`:重新抓安裝時記錄的 ref,commit 沒變就跳過;**執行中的指令與 pane 繼續用舊檔，不重啟;startup hook 等下次 server 啟動才跑**。沒有自動更新。【文件】`docs/plugins.mdx:195-203`
- `herdr plugin uninstall <id|source>`:取消登錄;安裝檔保留到下次成功安裝／更新或 server 啟動、且使用中的 server 都結束後才清;config 與 state 保留。【文件】`docs/plugins.mdx:214-223`;【原始碼】`src/plugin_installations.rs:178-240`(lease 檔與 `cleanup`)
- 另有 `link`/`unlink`(本機開發)、`enable`/`disable`、`list [--json]`、`config-dir`、`action list|invoke`、`log list`、`pane open|focus|close`。【實測】`herdr plugin --help` 與各子指令的 `--help`。註：`herdr --help` 的指令列表沒有列出 `plugin`,但子指令存在。【實測】
- 沒有 herdr server 時也能 install／link(寫 `plugins.json`)。【文件】`docs/plugins.mdx:204-206`;`docs/socket-api.mdx:458-465`
- 本機現況:`purrdr.push` 0.1.0 已安裝、啟用，來源 `github:raychiutw/purrdr.host/host-plugin@7d821c3`,目前沒有任何 action。【實測】`herdr plugin list`、`~/.config/herdr/plugins.json`、`herdr plugin action list`

### 2.7 跨平台

- macOS／Linux:正式支援。
- **Windows:Plugins 是 preview**。「GitHub install、local link、build 指令、action、事件與 plugin pane 在 Windows 都是 best-effort」;指令必須是 Windows argv,`sh`／Bash 範例要另寫 Windows 版本。【文件】`docs/windows-beta.mdx:46, 69`。上面這句沒有提到 startup hook,Windows 上 startup hook 的支援程度【未確認】。
- Windows 的 build／action／事件指令會依 `PATHEXT` 解析 `npm.cmd` 這類 shim,`.bat`／`.cmd` 經 `cmd /d /c` 執行;pane 指令走一般的 pane launcher。【文件】`docs/plugins.mdx:340-343`;【原始碼】`src/plugin_command.rs:34-54`
- Windows 上 herdr server 的子行程會不會在 server 結束時被 job object 一起收掉【未確認】(`src/platform/windows.rs:1364-1369` 顯示 server 本身會避開會在關閉時殺子行程的 job,但沒有查到 plugin 子行程的處理)。

### 2.8 版本相容

- `min_herdr_version` 必填，比執行中的 binary 新就拒絕 link／install。【文件】`docs/plugins.mdx:101-104`
- plugin API 在官方文件裡標為「early interface」。【文件】`docs/socket-api.mdx:451`。從 0.7 起逐版擴充(startup hook、全域登錄、`plugin update` 等都是後來加的)。【文件】`CHANGELOG.md:20, 421, 426, 615-619`

## 3. 主機服務的功能逐項對照

判斷基準：能不能用 plugin 的**原生模型**(startup／event／action／pane 指令，跑完就結束)完成。「需要常駐」代表只能靠 startup hook 帶起常駐程式，也就是 2.5 說的「換一個監督者」,不算真的搬進 plugin。

| 功能(主機服務模組) | 可否搬進 plugin | 理由 |
|---|---|---|
| WSS 伺服器與 HTTP `/v1/pair`(`http.rs`) | **不能**(只能「常駐程式由 plugin 帶起」) | 手機發起的請求需要一直在聽的 listener;plugin 沒有網路介面也沒有常駐模型(2.5) |
| 配對、裝置權杖、唯讀、撤銷(`device_store.rs`、`management.rs`、`devices.*`) | **不能**(驗證本身)／**部分可以**(顯示 QR) | 權杖驗證跟 listener 綁在一起。主機上的 `pair` 指令可以做成 plugin popup pane,在 herdr 裡直接顯示 QR code(`docs/plugins.mdx:306-326`) |
| `tailscale serve` 設定、自動啟動、PATH(`install/`) | **不能**取代 | 是安裝時的一次性系統設定。plugin 的 build 指令拿不到 runtime 環境，而且只在 GitHub install 時跑;startup hook 只在 herdr server 啟動時跑，取代不了登入自動啟動 |
| 自動更新與退回(`update.rs`、`auto_update.rs`、`remote_management.rs`) | **不能**(會退步) | `herdr plugin update` 要手動執行，不重啟執行中的行程(2.6);目前的 SHA256SUMS、Developer ID 驗證、起不來就退回都得自己再做 |
| Agent 列表、事件串流轉接(`agents.list`、`events.subscribe`) | **不能** | 要把 herdr 的訂閱串流轉給 WSS 連線，需要常駐 |
| 送按鍵、送文字、送 prompt、送出前比對(`pane_guard.rs`) | **不能**(單獨) | 是手機發起的請求;plugin 只能由 herdr 事件、快捷鍵或 CLI 觸發 |
| 讀 Pane 畫面(`pane.read`) | **不能** | 同上 |
| Pane 終端機(`pane_terminal.rs`,執行 `herdr terminal session control|observe` 並轉接 NDJSON) | **不能** | 長時間雙向串流 |
| workspace／worktree 建立、改名、關閉、`agent.start`(`structure_operations.rs`) | **不能** | 手機發起的請求 |
| 對話紀錄定位、視窗、追蹤、預覽、subagent、workflow、delegation(`transcript*.rs`) | **不能** | 追蹤需要常駐監看檔案;連線內的「定位過的路徑」狀態是存取規則的一部分(ADR-0010) |
| 可續接 session 列表(`session_history.rs`) | **不能** | 手機發起的請求 |
| git 變更與 diff(`git.*`) | **不能** | 手機發起的請求 |
| 主機取檔(`file.stat`／`file.read`) | **不能** | 手機發起;每條連線的快照與「Agent 寫出的路徑」索引都是連線狀態 |
| 上傳(`uploads.rs`) | **不能**;定期清理**可以折衷** | 上傳是手機發起。7 天清理可以改成 startup hook(每次 server 啟動清一次),但 server 很少重啟時就幾乎不會清 |
| Send When Done 佇列(`agent_observer.rs`) | **折衷** | 觸發可以改成 `pane.agent_status_changed` hook:讀 state 資料夾的佇列、以 `herdr pane get` 比對 session、以 `herdr agent prompt` 送出。但(1)增刪重排仍由手機經主機服務寫入;(2)hook 之間沒有保證順序(2.4),要自己加檔案鎖;(3)「`blocked` 之後的 idle 不算做完」要知道前一個狀態，事件 hook 得自己存狀態;(4)`queue.changed` 要推給連線中的手機，還是要經主機服務 |
| 可能卡住(畫面指紋 N 分鐘不變)、仍在等你(blocked 持續 N 分鐘)提醒(`attention.rs`、`agent_push.rs`) | **不能**(實務上) | 需要計時器與定期讀畫面。用事件 hook `sleep` 到時間再檢查，會長時間佔用 32 個名額(2.4),而且每次狀態變化都疊一支 |
| `blocked`／`done` 推播 | **已經是 plugin** | `host-plugin/` 的 `notify.sh`／`notify.ps1`,事件觸發、跑完就結束，是 plugin 的理想用法 |
| 推播外掛代裝(`push_plugin.rs`、`push.*`) | 不適用 | 這是主機服務替 HTTPS 使用者執行 `herdr plugin install|uninstall`,方向剛好相反 |
| 更新事件推播(`update_push.rs`) | **不能** | 跟著自動更新流程 |
| 稽核紀錄、服務 log(`audit_log.rs`、`service_log.rs`) | 不適用 | 附屬於常駐程式。plugin 自己的 log 只有記憶體裡 200 筆、每筆輸出 64 KiB(2.4),不能取代 |

**小結**:22 項裡只有 1 項(`blocked`／`done` 推播)天生適合 plugin,而且已經是 plugin;2 項可以折衷(Send When Done 的觸發、上傳清理);其餘都需要常駐的網路服務。

## 4. 架構選項

### A. 全部改成 plugin(startup hook 帶起主機服務，取代 LaunchAgent／systemd／HKCU Run)

- 做法:manifest 的 `[[build]]` 下載 Release 執行檔(或要求使用者有 cargo),`[[startup]]` 執行 `purrdr-host-service serve`(不結束)。
- 安全性：沒有改善，也沒有變差。程式以同一個使用者身分執行;`no_command_execution` 是「手機能觸發什麼」的原則，跟誰把行程帶起來無關。但 build 階段要自己下載並驗證 binary(SHA256SUMS、macOS 簽章),現在 `install.sh` 的驗證要搬過去，而 build 指令拿不到 runtime 環境(`docs/plugins.mdx:242-245`)。
- 可維護性：變差。要自己處理單例(live handoff 會重跑 startup hook、named session 各跑一次)、崩潰後沒人重啟、永久佔一個 plugin 指令名額、違反官方「不是受監督的 daemon」的定位(`docs/plugins.mdx:256-260`),之後 herdr 若加上逾時或清理政策就會壞。
- 安裝體驗：看起來變簡單(一行 `herdr plugin install`),但 `tailscale serve` 設定與配對還是要另外做;而且 install 需要 `git`(`docs/plugins.mdx:192-194`),Windows 不一定有。
- 可用性：主機服務只在 herdr server 跑著時存在。server 沒開時手機連不到，連「herdr 沒開」都看不到，也不能撤銷裝置、看更新狀態。現在主機服務對這種情況回 `herdr_unavailable`(`protocol/host-service.schema.json` 的 `ErrorCode`)。
- Windows:建立在 preview 機制上(2.7),而 HTTPS 連線方式就是為了 Windows 而做。
- 升級路徑：失去自動更新;`plugin update` 不重啟執行中的行程，等於下次 herdr server 重啟才換版。
- **結論：不建議。**

### B. plugin 只負責「確保主機服務在跑」(startup hook 執行一次性的 `ensure-running`)

- 做法:自動啟動仍由 OS 負責，startup hook 只在 herdr server 起來時檢查並 kickstart 主機服務，然後結束。這符合官方的一次性定位。
- 取捨：增加的價值很小。LaunchAgent／systemd／HKCU Run 本來就會在登入時啟動並(macOS／Linux)在崩潰後重啟;多一個元件、多一條執行指令的路徑(要更新 `no_command_execution` 測試的例外清單),Windows 還是 preview。
- **結論：不建議，除非實測發現「主機服務比 herdr server 早起而連不上 socket 卻不重試」這類問題**(這應該在主機服務裡修，而不是靠 plugin)。

### C. 只把事件類功能放到 plugin(現況加上 Send When Done 觸發)

- 現況已經是這樣(推播)。再把 Send When Done 的觸發搬過去，會把同一份佇列拆成兩個寫入者(主機服務寫、hook 讀並送出),需要跨行程鎖與狀態檔，而主機服務的 Agent 觀察者反正為了卡住／等你提醒還是要常駐訂閱事件。
- **結論:Send When Done 不值得搬**。事件類只保留推播。

### D. 維持現狀(主機服務獨立常駐,plugin 只推播),可選加「便利 entrypoint」

- 主機服務的生命週期、自動更新、退回、log、稽核都已經做好而且跨三平台一致;herdr plugin 只承擔它最擅長、也已經驗證過的事件推播。
- 可選的加分項(不影響架構):在 `purrdr.push` 或另一個 plugin 裡加 `[[panes]] placement = "popup"` 執行 `purrdr-host-service pair`,搭配 `[[keys.command]] type = "plugin_action"`(`docs/plugins.mdx:345-355`),讓使用者在 herdr 裡按鍵就顯示配對 QR code;或加一個 action 顯示 `purrdr-host-service version`。這只是 UI 捷徑，主機服務沒裝時要給清楚的錯誤。
- 附帶觀察(反方向):HTTPS 主機已經有常駐的 Agent 觀察者，`blocked`／`done` 推播其實可以由主機服務直接送，省掉代裝 plugin 這一步;SSH 主機仍需要 plugin(ADR-0002 零安裝)。這跟本題相反，只是記錄下來，要做的話另開題目評估(包含兩邊同時送時怎麼去重)。
- **結論：建議採用。**

### 比較表

| | 安全性 | 可維護性 | 安裝體驗 | Windows | 升級 | herdr 沒開時 |
|---|---|---|---|---|---|---|
| A 全 plugin | 持平(binary 驗證要重做) | 差(單例、無監督、違反官方定位) | 表面較簡單，仍需 tailscale 與 git | preview | 失去自動更新 | 整個服務消失 |
| B plugin 監督 | 持平(多一條執行路徑) | 稍差(多一個元件) | 不變 | preview | 不變 | 不變 |
| C 事件移 plugin | 持平 | 稍差(佇列兩個寫入者) | 不變 | preview(best-effort) | 不變 | 不變 |
| D 維持現狀 | 現況 | 最好 | 現況 | 不依賴 plugin | 自動更新＋退回 | 回 `herdr_unavailable`,管理功能照常 |

## 5. 結論與建議

- herdr plugin 的設計是「herdr 在特定時機執行一支跑完就結束的指令」,沒有沙箱、能用整個 herdr CLI,但**沒有常駐、監督、網路介面與逾時**。主機服務的核心價值(對 tailnet 提供窄 API 的常駐 WSS 服務)剛好落在 plugin 模型以外。
- 把主機服務「寫進」plugin,實際上只是把監督者從 OS 換成 herdr server,而且是官方明說不支援的用法;換來的是失去自動更新與崩潰重啟、生命週期綁在 herdr server、Windows 依賴 preview 功能。
- **建議**:維持 ADR-0010 的常駐主機服務,plugin 繼續只負責 ADR-0004 的事件推播(選項 D)。如果想讓主機上的操作更順，可以另外加 popup pane／action 當配對 QR 與狀態的捷徑。
- 不需要改 ADR;若要記錄「考慮過但不採用」,可以在 ADR-0010 補一行「做成 herdr plugin:plugin 不是受監督的 daemon,生命週期綁 herdr server,Windows 仍是 preview」並連到這份筆記。

## 6. 未確認、需要實驗驗證的點

1. **herdr server 結束(`server stop`、當機、登出)時，執行中的 plugin 子行程會不會被結束**。原始碼裡沒看到明確 kill;Unix 沒有另開 process group(2.4),Windows 有 job object 的可能性。【未確認】
2. **live handoff 後，舊 server 底下由 startup hook 帶起的行程是否存活**,以及新 server 重跑 startup hook 造成的重複。【未確認】(只有 Unix 支援 handoff:`src/platform/mod.rs:249-252`)
3. **Windows 上 startup hook 的支援程度**:`docs/windows-beta.mdx:69` 的 preview 列表沒有提到 startup。【未確認】
4. **plugin 指令 log 是否跨 server 重啟保留**:目前只看到存在記憶體。【推論】
5. **官方是否有登入時自動啟動 herdr server 的機制**:文件裡找不到。【未確認】
6. **plugin pane 是否計入 32 個指令名額**:從程式看 pane 走 PTY 路徑、不經過 `start_plugin_command`,應該不計。【推論】`src/app/api/plugins/panes.rs`
7. **同一 pane 連續事件的 hook 完成順序**:每個 hook 各自一條 thread,推論不保證順序。若之後要把任何有狀態的邏輯放進 hook,要先實測。【推論】
8. **plugin 子行程的環境(`TMPDIR`／`TEMP`、`PATH`)與 LaunchAgent／systemd／HKCU Run 的差異**:它繼承 herdr server 的環境，而 server 可能從 GUI 終端機、SSH 或 handoff 帶起(`docs/troubleshooting.mdx:94`),會影響上傳資料夾與 `x-temporary-file-locations` 的判斷。只有選項 A／B 才需要驗證。【未確認】
9. 若採用 D 的 popup pane 捷徑:`purrdr-host-service pair` 在 popup(預設半螢幕、可設大小)裡 QR code 是否完整顯示，以及 Windows pane launcher 能否直接執行它。【未確認】

## 附錄：來源

- herdr 文件(stable 0.9.5 索引):https://herdr.dev/llms.txt
- Plugins:https://github.com/herdrdev/herdr/blob/v0.9.5/docs/next/website/src/content/docs/plugins.mdx
- Socket API(Plugin APIs 一節):https://github.com/herdrdev/herdr/blob/v0.9.5/docs/next/website/src/content/docs/socket-api.mdx
- Windows support:https://github.com/herdrdev/herdr/blob/v0.9.5/docs/next/website/src/content/docs/windows-beta.mdx
- Session state、Persistence、Troubleshooting:同目錄的 `session-state.mdx`、`persistence-remote.mdx`、`troubleshooting.mdx`
- 原始碼(tag `v0.9.5`,commit `2ecf19a`):`src/app/api/plugins/runtime.rs`、`src/app/api/plugins/manifest.rs`、`src/app/api/plugins/panes.rs`、`src/api/schema/events.rs`、`src/plugin_command.rs`、`src/plugin_installations.rs`、`src/noninteractive_process.rs`、`src/platform/{mod,windows}.rs`、`src/server/headless/bootstrap.rs`、`src/app/api.rs`、`CHANGELOG.md`
- 本機唯讀指令(herdr 0.9.5):`herdr --help`、`herdr plugin --help` 與各子指令 `--help`、`herdr plugin list`、`herdr plugin log list`、`herdr plugin action list`、`herdr status`;`~/.config/herdr/plugins.json`
- Purrdr:`docs/adr/0002`、`0004`、`0010`、`GLOSSARY.md`;`purrdr.host` 的 `host-plugin/`、`host-service/service/src/`、`host-service/service/tests/no_command_execution.rs`、`protocol/host-service.schema.json`
