# HTTPS 主機的 blocked／done 推播改由主機服務直接送(截至 2026-11-21)

> 目的：評估 raychiutw/purrdr.host#48:HTTPS 主機的 Agent `blocked`(需要你)／`done`(完成)推播，改由常駐的主機服務(Agent 觀察者)直接送給 Purrdr 後台，取代或並存於主機服務代裝的 herdr plugin `purrdr.push`。
>
> 標記:**【原始碼】** 本機 repo 原始碼(附檔案:行號);**【實測】** 本機唯讀指令輸出;**【文件】** ADR／研究筆記;**【推論】** 由前述推得、未直接驗證;**【未確認】** 找不到一手來源。
>
> 版本基準:
> - 主機端 `raychiutw/purrdr.host` master `b8e87e4`(主機服務 0.8.0,`host-service/service/Cargo.toml:3`)。下稱 `host/`。
> - app `raychiutw/purrdr.ios`,本機 `purrdr.ios-docs` 的 `docs/herdr-plugin-feasibility`(`bddb314`,以 master `5a303e2` 為基底)。下稱 `app/`。
> - 後台 `raychiutw/purrdr.server` master `706fcb4`(本機 `/Users/ray/Projects/purrdr.server`)。下稱 `server/`。
> - herdr 0.9.5(`herdr status`)。
>
> 研究時只讀原始碼並執行唯讀指令(`herdr plugin list --plugin purrdr.push --json`、`herdr plugin log list`、`herdr status`),沒有修改 `~/.purrdr`、沒有安裝或移除 plugin。

## 摘要

1. **主機服務已經做了大半**:Agent 觀察者已經常駐訂閱 `pane.agent_status_changed`,並且已經用同一份配對檔、同一個後台 API、同樣的 body 形狀直接送 `stuck`／`reminder`(`agent_push.rs:14-24`),靜音與 410 處理都有。`blocked`／`done` 只差「在狀態轉換時呼叫 `agent_push::send`」這一步。【原始碼】
2. **配對資料與偏好完全沿用**:`~/.purrdr/push-<裝置>/pairing` 主機服務本來就讀得懂(`update_push.rs:119-166`);種類偏好(`kinds`)存在後台(`server/src/push.ts:253-256`),靜音存在配對檔。**後台不用改**,隱私保證(只帶 workspace、狀態、pane id)由後台白名單強制，不因寄件者改變。【原始碼】
3. **真正的難題是去重**。主機端無法分辨配對是 SSH 還是 HTTPS 寫的(同一支裝置共用同一個 `push-<裝置>` 資料夾)，後台對狀態推播也**沒有任何去重**。只要主機服務與任何版本的 plugin 同時在送，每個事件就會推兩次。現有 `purrdr.push` 0.1.0 不認得任何讓位機制，所以**舊 plugin 還在時主機服務不能直接送**。【原始碼】【實測】
4. 建議的去重方式:**主機服務寫一個「接手中」的 lease 檔(帶它觀察的 herdr socket 路徑，定期更新 mtime,斷線就刪);新版 plugin 看到新鮮、同一個 socket 的 lease 就讓位**。主機服務只在「沒有 plugin」或「plugin ≥ 0.2.0(會讓位)」時才直接送。這樣主機服務斷線或沒跑時，若 plugin 在，plugin 會自動接回。【推論】
5. **最大的效益在 Windows**:HTTPS 的主要族群是 Windows 主機(ADR-0010),而 Windows 上的 herdr plugin 是 preview、`notify.ps1` 沒有在 Windows 實測過(`host-plugin/notify.ps1:2`),`herdr plugin install` 還需要 git 與 GitHub 連線。直接送可以把 HTTPS 主機的推播變成正式支援。
6. **建議做，分三階段**:先發 plugin 0.2.0(只加讓位檢查，沒有寫 lease 的人時行為不變)→ 主機服務 0.9.0 直接送＋寫 lease(依 plugin 版本決定要不要接手)→ 協定與 app 調整(HTTPS 開推播不再裝 plugin、文案更新)。要改 ADR-0004、ADR-0012 與 GLOSSARY;ADR-0002、ADR-0010 不用改決策。

---

## 1. 現況資料流

### 1.1 共用部分：開推播、配對檔、後台

- **app 開推播**(`app/src/PurrdrFeatures/PushModel.swift:427-456`,`confirm()`):產生配對密鑰 → 向後台註冊**密鑰的雜湊**與 APNs token,`kinds` 預設 `[.blocked, .done]`(`:434-436`、`:353`)→ 經「推播外掛安裝」寫配對檔、必要時裝 plugin → 主機失敗就撤銷剛註冊的配對(`:446-449`,撤銷在 `:448`)。app 依 **hostID** 記 keyHash(`:451-453`)。
- **選 SSH 或主機服務代裝**:`app/src/PurrdrFeatures/HostsModel.swift:943-948`(註解在 `:943`)。連線方式 `usesHostService` 為真(HTTPS)時用 `HostServicePushPluginInstaller`,否則用 `SSHPushPluginInstaller`。
- **配對檔**:`~/.purrdr/push-<裝置 id>/pairing`,一行一個 `名稱=值`(`purrdr-push 1`、`endpoint=`、`key=`、`muted=`)。app 的定義是 `app/src/PurrdrCore/PushPairing.swift:47-97`,主機服務的是 `host/host-service/service/src/push_plugin.rs:291-310`。**資料夾名稱只看裝置 id,不看是哪個主機項目或哪種連線**(`app/src/PurrdrSSH/SSHPushPluginInstaller.swift:39`、`push_plugin.rs:129`)。
- **endpoint 與 plugin 來源**:`app/src/App/Purrdr/BackendConfiguration.swift:18`(`raychiutw/purrdr.host/host-plugin`)、`:21`(`<baseURL>/v1/push`)。
- **後台 `POST /v1/push`**(`server/src/index.ts:111` → `server/src/push.ts:236-283`):
  - 驗證：沒有 header 驗證，body 裡的 `key`(64 位小寫 hex)取 SHA-256 後查 `push_pairings`(`push.ts:49-56`、`:150-161`、`:214-218`)。
  - 狀態推播的 body **只能有** `key`、`workspace`、`status`(`blocked|done|stuck|reminder`)、`pane?`,多一個欄位就 400(`push.ts:19`、`:151-155`、`:163-178`);body 上限 2048 bytes(`:30`)。
  - 檢查會員訂閱(`:249-251`)→ 種類不在配對的 `kinds` 內就回 200 `{delivered:false}`,不算錯(`:252-256`)→ 每組密鑰每分鐘 10 則(`:33`、`:262-267`)→ 後台自己組 APNs payload(標題 = workspace,內文依狀態固定，`:316-342`)。
  - 配對已撤銷回 **410 一次**(`:241-247`),主機端收到要刪配對。
  - **狀態推播沒有去重**;只有主機服務事件(`host_service_*`)有 24 小時去重(`:257-260`、`:287-297`)。
  - 文件版契約：`server/README.md:43`。

### 1.2 SSH 主機

1. app 經 SSH 寫配對檔(`ReversibleHostWrite`),plugin 還沒裝就寫 `~/.purrdr/push-plugin/` 紀錄並執行 `herdr plugin install raychiutw/purrdr.host/host-plugin --yes`;失敗就還原(`SSHPushPluginInstaller.swift:52-64`)。關閉時刪自己的資料夾，最後一支裝置且紀錄存在才 uninstall(`:66-76`)。改靜音只改配對檔(`:78-86`)。
2. herdr 在 `pane.agent_status_changed` 時以新子行程執行 plugin(`host/host-plugin/herdr-plugin.toml:13-22`;macOS／Linux `sh notify.sh`,Windows `powershell … notify.ps1`)。
3. `notify.sh`:
   - 只處理 `blocked`／`done`(`notify.sh:11-15`)。
   - pane id 與 workspace label 取自 `HERDR_PLUGIN_EVENT_JSON`／`HERDR_PLUGIN_CONTEXT_JSON`,沒有 label 就用 workspace id(`:22-28`)。
   - 逐一讀 `~/.purrdr/push-*/pairing`(`:38-42`);有靜音時問一次 `herdr pane get` 取 session 比對(`:43-53`)。
   - `curl` POST `{key, workspace, status, pane?}`,密鑰經 stdin(`:54-56`);410 且期間密鑰沒換就刪配對資料夾(`:57-60`)。失敗不重試(`:8`)。
4. `notify.ps1` 行為相同(`notify.ps1:14-69`),檔頭註明「沒有在 Windows 主機上實測」(`:2`)。

### 1.3 HTTPS 主機(主機服務 0.6.0 起)

1. app 送 `push.install {device_id, pairing}`(`app/src/PurrdrHTTPS/HostServicePushPluginInstaller.swift:29-39`),主機服務版本 < 0.6.0 時丟 `hostServiceOutdated`(`:60-65`、`app/src/PurrdrCore/HostServiceFeature.swift:19, 30`)。
2. 主機服務 `PushPlugin::pair`(`push_plugin.rs:124-152`):寫配對檔，plugin 沒裝就寫紀錄並以本機使用者身分執行 `herdr plugin install … --yes`(`:133-150`),失敗還原。`push.remove` → `unpair`(`:178-192`),`push.update_muted` 只改配對檔、不呼叫 herdr(`:155-175`)。協定定義在 `host/protocol/host-service.schema.json:1197-1299`。
3. 之後的 `blocked`／`done` 推播**與 SSH 完全相同**:由 herdr 執行 plugin 送出。主機服務在這條路徑上只負責「代裝」。
4. 主機服務執行的 herdr 子指令被測試鎖死成 `plugin list|install|uninstall` 三個(`host/host-service/service/tests/no_command_execution.rs:10, 62-77`)。

### 1.4 主機服務已經自己送的推播

| 推播 | 觸發 | 程式 |
|---|---|---|
| `stuck`(可能卡住) | working 期間畫面指紋 10 分鐘不變 | `attention.rs:10`、`agent_observer.rs:306-324` |
| `reminder`(仍在等你) | blocked 持續 15 分鐘 | `attention.rs:12`、`agent_observer.rs:315` |
| `host_service_update_available`／`updated`／`update_rolled_back` | 自動更新流程 | `update_push.rs:67-103` |

- 觀察者**一律啟動**(`host/host-service/service/src/lib.rs:130`、`:186-190`),不論 app 是否連線、也不論這台主機在 app 裡是 SSH 還是 HTTPS 項目。所以 **SSH 寫的配對檔，只要主機上有跑主機服務，現在就已經會收到 stuck／reminder**。【原始碼】
- 送法:`push()` 先讀 `session.snapshot` 取 workspace label 與 session(`agent_observer.rs:327-354`),再 `agent_push::send` 對每組配對送 `{key, workspace, status, pane}`,靜音跳過、410 刪配對(期間重新配對的不刪)(`agent_push.rs:14-24`、`update_push.rs:169-173`)。HTTP 是 `ureq`,逾時 10 秒,User-Agent `purrdr-host-service/<版本>`(`update_push.rs:20-41`)。
- 狀態事件的處理點已經存在(`agent_observer.rs:271-279`),目前只用在 Send When Done。

## 2. 改由主機服務直接送：要改什麼

### 2.1 已經有的部分(可直接重用)

| 需要的能力 | 現有程式 |
|---|---|
| 常駐訂閱 `pane.agent_status_changed`、斷線退避重連 | `agent_observer.rs:242-290` |
| 讀配對檔(含 muted)、410 刪配對 | `update_push.rs:119-173` |
| 送 `{key, workspace, status, pane}`、靜音比對 | `agent_push.rs:14-24`(`status` 是字串參數，直接傳 `"blocked"`／`"done"` 即可) |
| workspace label(沒有就 id,同 plugin)、session | `agent_observer.rs:331-354` |
| 不擋事件處理的非同步送出 | `agent_observer.rs:319-323`(另開 task) |
| 測試骨架(假 herdr 事件＋假推播後台) | `host/host-service/service/tests/attention_push.rs`(`FakePushBackend`) |

結論:`agent_push.rs`／`update_push.rs` 已經做完「送」的部分，缺的只有**觸發**與**去重／讓位**。

### 2.2 主機服務

1. 在 `agent_observer.rs:273-279` 的狀態轉換處，新狀態是 `blocked` 或 `done` 且與前一個狀態不同時呼叫既有的 `push()`。【推論】
   - **只在「事件」上送，不依 snapshot 補送**:重連後的 snapshot 對帳(`:251-266`)不推播，因為斷線期間 plugin 可能已經接手(見 3.2)。
   - 「前後狀態相同不送」是比 plugin 更嚴的條件(plugin 每個事件都送，`notify.sh:11-15`)。herdr 會不會連續送同狀態事件【未確認】,見第 6 節。
2. **寫 lease 檔**(第 3 節):訂閱成功後寫、每次 `checks.tick()`(預設 30 秒，`agent_observer.rs:54`)更新 mtime、訂閱斷掉時刪、服務停止時刪。
3. **決定要不要接手**:用已允許的 `herdr plugin list --plugin purrdr.push --json` 讀已安裝 plugin 的 `version`(【實測】輸出有 `"version":"0.1.0"` 與 `source.resolved_commit`)。沒裝或 ≥ 0.2.0 才接手;0.1.0 時不寫 lease、不送 blocked／done(維持現況，由 plugin 送)。`lists_plugin` 目前只比對 id(`push_plugin.rs:251-258`),要擴充成回傳版本。
4. `push.install`(第三階段):主機服務會接手時**不再執行 `herdr plugin install`**,只寫配對檔;`push.status.result` 加一個選用欄位(例如 `direct_push: true`)讓 app 顯示正確的確認文字。`push.remove` 的 uninstall 規則不變(只移除 Purrdr 裝的)。
5. `no_command_execution.rs` 不需放寬：不增加新的 herdr 子指令(只要不做「主機服務自動 `herdr plugin update`」)。

### 2.3 主機外掛(`host-plugin/`)

- `notify.sh`／`notify.ps1` 加讓位檢查：在讀配對檔之前，若 lease 檔存在、mtime 在門檻內(例如 120 秒)、且內容的 `socket=` 等於 `$HERDR_SOCKET_PATH`(herdr 會注入給 plugin,見 `docs/research/herdr-plugin-feasibility.md` 2.4 節)就 `exit 0`。版本升到 0.2.0。【推論】
- 測試加在 `host/host-service/plugin-tests/tests/notify_script.rs`。

### 2.4 協定(`protocol/host-service.schema.json`)

- `PushInstall` 描述(`:1207`)改成「主機服務會直接送時只寫配對、不裝 plugin」。
- `PushStatusResult`／`PushInstallResult`(`:1240-1274`)加選用 `direct_push`(boolean)。Rust 端沒有 `deny_unknown_fields`(`grep` 計數 0),新增欄位對舊版相容;Swift 端的產生型別是否忽略未知欄位【未確認】,但新欄位只出現在新主機服務的回覆，舊 app 收到多一個欄位的情況要在 app 的 decode 測一次。

### 2.5 app

- `HostServiceFeature` 加 `directPush`(門檻 0.9.0)(`HostServiceFeature.swift:5-32`)。
- `PushPluginStatus` 加 `directPush`(`app/src/PurrdrCore/PushPluginInstalling.swift:4-20`)。
- 文案:`app/src/PurrdrFeatures/HostPushSection.swift:32`(「Purrdr adds a small herdr plugin to each host…Notifications from Windows hosts are best-effort.」)與 `:272-282` 的確認文字，HTTPS＋新主機服務時改成「主機服務會直接通知，不安裝 plugin」,而且不再說 Windows 是 best-effort。
- `PushKind` 目前只有 `blocked`、`done`、`host_service`(`app/src/PurrdrCore/PushKind.swift:4-10`),跟這題無關但要注意 stuck／reminder 的 app 端還沒進 master。
- 開關、keyHash、kinds、靜音同步的流程**都不用改**。

### 2.6 後台

**不需要改**。body 形狀相同(`agent_push.rs:19` 與 `notify.sh:54` 送的欄位一致，後台白名單 `push.ts:19`),後台本來就不知道也不在乎寄件者是誰。可選：用 User-Agent(`curl/*` vs `purrdr-host-service/*`)做匿名計數，觀察過渡期的重複比例;但這會新增後台記錄，要先確認不違反 ADR-0004「後台不保存能回推使用者身分的資料」【推論】。

### 2.7 配對資料與偏好能否沿用

| 資料 | 存哪裡 | 主機服務直接送時 |
|---|---|---|
| 配對密鑰、endpoint | `~/.purrdr/push-<裝置>/pairing` | 直接讀(`update_push.rs:153-166`),格式不變 |
| 靜音清單 | 配對檔的 `muted=` | 已支援(`agent_push.rs:16`) |
| 要收的種類(`kinds`) | 後台 `push_pairings.kinds`(`push.ts:84-95`) | 不用知道，後台過濾 |
| 推播裝置 id、keyHash ↔ 主機 | app(Keychain／UserDefaults) | 不變 |

不需要任何資料遷移。**不要**在配對檔加「寄件者」之類的新欄位當去重依據：app 的解析會丟掉不認得的行(`PushPairing.swift:88-93`),SSH 改靜音時整檔重寫(`SSHPushPluginInstaller.swift:78-86`),主機服務改靜音也只寫回三種行(`push_plugin.rs:169`、`:305-308`),標記會被洗掉。【原始碼】

## 3. 去重與過渡

### 3.1 會重複的情境

主機端每個寄件者都讀**同一組** `push-*/pairing`,所以重複與「是誰寫的配對」無關，只與「這台主機上同時有幾個寄件者在送」有關:

| 情境 | plugin | 主機服務 | 結果(沒有去重時) |
|---|---|---|---|
| 現況(主機服務 ≤ 0.8) | 送 blocked／done | 只送 stuck／reminder | 不重複 |
| 升級後，舊 plugin 0.1.0 還在 | 送 | 送 | **每則兩次** |
| HTTPS 主機開推播時已裝 plugin(別的裝置或 SSH 路徑裝的) | 送 | 送 | **每則兩次** |
| 同一台機器在 app 裡同時設成 SSH 與 HTTPS 兩個主機項目 | 送 | 送 | **每則兩次**(配對檔只有一份，見下) |
| 主機服務沒跑、plugin 在 | 送 | — | 一次 |
| 主機服務在跑、plugin 不在 | — | 送 | 一次 |

重複的代價：使用者收到兩則一樣的通知，而且吃掉兩倍的每分鐘 10 則額度(`push.ts:33`),可能擠掉真正的「需要你」。

附帶觀察(與 #48 無關的既有現象，【推論】):同一支裝置把同一台機器設成 SSH 與 HTTPS 兩個主機項目並都開推播時，後開的會覆寫 `push-<裝置>/pairing` 的密鑰(資料夾只看裝置 id),先開的那個主機項目在 app 裡仍顯示「開著」,但後台那組配對再也收不到推播;任一邊關閉還會刪掉共用的資料夾。建議另開 issue 確認。

### 3.2 去重方案比較

| 方案 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| **A. lease 讓位(建議)** | 主機服務寫 `~/.purrdr/host-service/push-sender`(內容 `socket=<它觀察的 herdr socket>`),定期更新 mtime、斷線就刪;plugin 0.2.0 看到新鮮且同 socket 的 lease 就不送。主機服務只在沒有 plugin 或 plugin ≥ 0.2.0 時才接手 | 一個事件只有一個寄件者;主機服務斷線或當掉時 plugin 自動接回(lease 過期);named session 各自判斷;不改後台與配對檔 | 要協調 plugin 與主機服務兩邊的版本;接手／交還的瞬間可能多一則或少一則;lease 門檻(例如 120 秒)內主機服務剛掛掉會漏推 |
| B. 主機服務接手時移除 plugin | 主機服務遇到 Purrdr 裝的 plugin(`push-plugin/` 紀錄)就 uninstall | 簡單，不用改 plugin | SSH 路徑之後再開推播會把 plugin 裝回來，又重複;使用者自己裝的 plugin 不能動;失去主機服務沒跑時的備援 |
| C. 配對檔加寄件者標記 | 每組配對指定由誰送 | 精確 | 標記會被 app／主機服務改靜音時洗掉(2.7);舊 plugin 不認得 |
| D. 後台短時間去重 | 同 key＋pane＋status 在 N 秒內只轉一次 | 涵蓋所有組合，包含舊 plugin | 「需要你」常在幾秒內連續出現(核准一個工具後下一個又要核准),會被吃掉;若 herdr 事件有唯一 id 可以改成精確去重，但事件裡有沒有這種欄位【未確認】(測試 fixture `attention_push.rs:102` 只有 agent、agent_status、pane_id、workspace_id;`herdr plugin log list` 不含事件內容【實測】) |

lease 檔放在 `~/.purrdr/host-service/` 底下(由家目錄推出，不跟 `--state-dir`;前例是 `update_push.rs:61` 的 `update-push.json`),這個位置已在主機取檔排除清單(`schema` 的 `x-excluded-file-locations` 含 `.purrdr/host-service`)。**不能**用 `push-` 開頭的名稱：裝置 id 只禁止 `plugin`(`push_plugin.rs:260-271`),`push-*` 會被當成某支裝置。

### 3.3 版本相容

| 組合 | 行為(採方案 A 時) |
|---|---|
| 舊主機服務(≤ 0.8)＋新 app | 現況：主機服務代裝 plugin,plugin 送。app 依 `HostServiceFeature.directPush` 判斷，舊版就顯示舊文案。無影響 |
| 新主機服務(0.9)＋舊 app | 舊 app 照樣送 `push.install`。第二階段的主機服務仍照舊代裝 plugin(新 plugin 會讓位),功能正確;第三階段改成不裝 plugin 後，舊 app 的確認文字會說「會執行 herdr plugin install」(`HostPushSection.swift:275`),文字不準但推播正常。舊 app 看到 `plugin_installed: false` 只影響文案(`PushModel.swift` 的 `pluginAlreadyInstalled`) |
| 新主機服務＋舊 plugin 0.1.0 | 主機服務偵測到 0.1.0 就**不接手**,維持現況;使用者執行 `herdr plugin update` 或關掉再開推播後才接手 |
| 新 plugin 0.2.0＋舊主機服務 | 沒有 lease 檔，plugin 照常送。無影響 |
| SSH 主機(沒有主機服務)＋新 plugin | 沒有 lease 檔，照常送。ADR-0002 不受影響 |

**怎麼讓舊 plugin 升級**是過渡期的主要問題。`herdr plugin update` 會「重新抓安裝時記錄的 ref」(`herdr-plugin-feasibility.md` 2.6 節);現有安裝沒有指定 `--ref`,只記錄 `resolved_commit`(【實測】`7d821c3`),update 會不會跟著預設分支前進【未確認】。可行的做法(擇一，進 grilling 決定):
- 什麼都不做：舊 plugin 在的主機繼續由 plugin 送，等使用者關掉再開推播(新主機服務那時不裝 plugin)。最安全，過渡最慢。
- app 在 HTTPS 主機看到「主機服務可接手但 plugin 是舊版」時提示一鍵重新開啟推播。
- 主機服務執行 `herdr plugin update purrdr.push`:要放寬 `no_command_execution.rs:62-77` 的白名單，不建議。

## 4. 取捨

### 4.1 主機服務沒跑就沒推播

- HTTPS 主機沒有主機服務時 app 本來就連不上，stuck／reminder 與 Send When Done 也已經依賴主機服務(ADR-0012)。blocked／done 跟著依賴，不會讓使用者多一種「壞掉」的狀態。【推論】
- 主機服務由 OS 在登入時啟動;macOS／Linux 當掉會重啟，Windows 的 HKCU Run 不會(`herdr-plugin-feasibility.md` 4.B 節)。Windows 主機服務當掉到下次登入之間會沒有推播，這是比 plugin 差的地方。【文件】
- herdr server 沒開時兩者都沒有事件，一樣。
- 方案 A 下，若主機上還有 plugin,主機服務斷線或沒跑時 lease 過期，plugin 接回;只有「HTTPS 新開推播、從來沒裝過 plugin」的主機才完全依賴主機服務。
- **named session**:主機服務只觀察一個 herdr session(`lib.rs:96-115`、`herdr_socket.rs:69-79`),plugin 則在每個 server 執行。不過 HTTPS 的 app 也只看得到主機服務那個 session,其他 session 的推播點了也開不到對應聊天，所以不算退步。【推論】

### 4.2 Windows

- herdr plugin 在 Windows 是 preview,事件 hook 是 best-effort(`herdr-plugin-feasibility.md` 2.7 節);`notify.ps1` 沒有實測(`notify.ps1:2`);`herdr plugin install` 需要 git(`herdr-plugin-feasibility.md` 2.6 節),app 的錯誤訊息也預期「主機沒有 git」(`PushPluginInstalling.swift:24`)。
- 主機服務是三平台正式支援的元件，觀察者的行為規定要在三平台測(ADR-0012 Consequences)。直接送等於讓 Windows HTTPS 主機的推播脫離 preview 機制，也省掉 git／GitHub 相依。這是做這題最主要的理由。

### 4.3 隱私

不變。主機服務送的 body 與 plugin 相同(`agent_push.rs:19`),後台白名單拒絕任何多的欄位(`push.ts:19`、`:151-155`),APNs payload 由後台組、只有 workspace 標題、固定內文與 pane(`push.ts:325-342`)。密鑰只放 HTTP body(`agent_push.rs:3-4`)。主機服務本來就讀配對密鑰(stuck／reminder、更新事件),沒有擴大接觸範圍。

### 4.4 對 ADR 的影響

- **ADR-0004**(推播：主機上的 herdr plugin 通知自營 relay):要補一段「更新」:有主機服務的主機，blocked／done 由主機服務的 Agent 觀察者直接送;plugin 仍是 SSH 主機的寄件者，並在主機服務接手時讓位(lease)。「Windows 推播只做 best-effort」改成只適用於經 plugin 送的情況。「配對方式」一段說「app 透過 SSH 安裝主機外掛」本來就已過時(0.6.0 起有主機服務代裝)。
- **ADR-0012**(主機服務常駐 Agent 觀察者):「觀察者只做三件事」要加第四件(blocked／done 推播);「考慮過但不採用」可以補一行「blocked／done 繼續交給 plugin:Windows preview、需要 git」。
- **ADR-0010**:決策不變。若第三階段 HTTPS 開推播不再裝 plugin,主機服務執行的 herdr CLI 範圍反而縮小。
- **ADR-0002**:不變(SSH 仍用 plugin)。
- **GLOSSARY**:「主機外掛」(`GLOSSARY.md:186-187`)要註明有主機服務時由觀察者送;「推播外掛安裝」(`:194-195`)的「HTTPS 主機由主機服務代為執行」要改成「主機服務能直接送時只寫推播配對」。

## 5. 建議

**做，分三階段**。程式改動小(送的部分已存在),主要工作在去重與過渡;效益集中在 Windows HTTPS 主機，正好是 HTTPS 的主要族群。

- **第一階段：只發 plugin 0.2.0**(讓位檢查)。沒有寫 lease 的程式時行為完全不變，可以先發、先讓新安裝與 update 的主機帶上。
- **第二階段：主機服務 0.9.0 直接送＋寫 lease**,只在「沒有 plugin」或「plugin ≥ 0.2.0」時接手;`push.install` 行為暫不改(仍代裝 plugin,新 plugin 會讓位)。這階段不需要 app 改版。
- **第三階段：協定與 app**:HTTPS＋新主機服務開推播時不裝 plugin,`push.status.result` 加 `direct_push`,app 改文案與門檻。
- **不做**:後台去重(會吃掉連續的「需要你」)、主機服務自動 `herdr plugin update`(放寬執行白名單)、移除 SSH 路徑的 plugin。

### 建議的票

| # | repo | 票 | blocked-by |
|---|---|---|---|
| T0 | purrdr.ios | grilling 決策寫回：ADR-0004「更新」段、ADR-0012 第四件事、GLOSSARY「主機外掛」「推播外掛安裝」,另記 lease 的術語 | — |
| T1 | purrdr.host | 驗證前提(spike):plugin 收到的 `HERDR_SOCKET_PATH` 與主機服務解析出的 socket 路徑在三平台是否逐字相同;herdr 會不會對同一 pane 連續送同狀態事件;`herdr plugin update` 對未指定 `--ref` 的安裝是否前進到最新 commit | — |
| T2 | purrdr.host | host-plugin 0.2.0:`notify.sh`／`notify.ps1` 的 lease 讓位檢查(新鮮度＋socket 比對)與 `plugin-tests` | T1 |
| T3 | purrdr.host | 主機服務：觀察者在轉換成 blocked／done 時直接送(只依事件、不依 snapshot 補送)、lease 寫入／更新／刪除、依 plugin 版本決定接手;測試涵蓋轉換去重、靜音、410、舊 plugin 不接手、斷線刪 lease | T1、T2(要知道讓位版本號，plugin 要先發) |
| T4 | purrdr.host | 協定＋`push_plugin.rs`:可接手時 `push.install` 不裝 plugin、`push.status.result`／`push.install.result` 加 `direct_push`、schema 描述與範例;發 0.9.0 | T3 |
| T5 | purrdr.ios | app:同步協定、`HostServiceFeature.directPush`(0.9.0)、`PushPluginStatus.directPush`、`HostPushSection` 文案(不裝 plugin、Windows 不再 best-effort)、舊主機服務維持舊文案 | T4 |
| T6(選用) | purrdr.ios | 舊 plugin 0.1.0 的升級提示(HTTPS 主機、主機服務可接手時提示重新開啟推播) | T4 |
| T7(另開 issue) | purrdr.ios | 確認並處理「同一台機器同時是 SSH 與 HTTPS 主機項目時，推播配對互相覆寫」(3.1 附帶觀察) | — |

## 6. 未確認事項

1. **socket 路徑能不能逐字比對**:plugin 拿到的 `HERDR_SOCKET_PATH` 與主機服務 `HerdrSocket::resolve` 的結果(尤其 Windows named pipe、macOS 的 symlink 化 config 目錄)是否相同。不同就要改比 session 名稱或正規化。【未確認】
2. **herdr 是否對同一 pane 連續送同狀態事件**:plugin 每個事件都送，主機服務打算只在狀態改變時送;若 herdr 會重送，現況其實已經在重複推播。【未確認】
3. **herdr 事件 envelope 有沒有唯一 id／時間戳**:有的話後台可以做精確去重(方案 D 的變體)。fixture 與 `plugin log list` 都看不到。【未確認】
4. **`herdr plugin update` 對沒指定 `--ref` 的安裝怎麼做**:決定舊 plugin 的升級路徑。【未確認】
5. **Swift 產生型別遇到未知欄位會不會 decode 失敗**:決定 `direct_push` 對舊 app 是否安全。Rust 端確定不拒絕未知欄位。【未確認】
6. **lease 門檻的取值**:30 秒更新、120 秒過期是推論值;接手／交還瞬間的一則重複或遺漏是否可接受，要在 grilling 決定。【推論】
7. **Windows 主機服務當掉後的空窗**:HKCU Run 不重啟，直接送後這段時間沒有 blocked／done;是否要補 Windows 的重啟機制另議。【文件】`herdr-plugin-feasibility.md` 4.B
8. **同機 SSH＋HTTPS 兩個主機項目互相覆寫配對**(3.1 附帶觀察)只由程式推得，沒有實測。【推論】

## 附錄：來源

- Issue:raychiutw/purrdr.host#48(`gh issue view 48 -R raychiutw/purrdr.host`)
- 前一份研究:`docs/research/herdr-plugin-feasibility.md`(選項 D 的附帶觀察，2.4、2.6、2.7、4.B 節)
- ADR:`docs/adr/0002-zero-install-host-over-ssh.md`、`0004-push-via-host-plugin-and-relay.md`、`0010-https-via-host-service-and-tailscale-serve.md`、`0012-host-service-resident-agent-observer.md`;`GLOSSARY.md`
- 主機端(`raychiutw/purrdr.host` `b8e87e4`):`host-plugin/{herdr-plugin.toml,notify.sh,notify.ps1,README.md}`;`host-service/service/src/{push_plugin,agent_observer,agent_push,attention,update_push,lib,herdr_socket,herdr_cli,state_directory}.rs`;`host-service/service/tests/{no_command_execution,attention_push}.rs`;`protocol/host-service.schema.json`
- 後台(`raychiutw/purrdr.server` `706fcb4`):`src/push.ts`、`src/index.ts:111`、`README.md:43`
- app(`raychiutw/purrdr.ios` `bddb314`):`src/PurrdrFeatures/{PushModel,HostsModel,HostPushSection}.swift`、`src/PurrdrCore/{PushPluginInstalling,HostServiceFeature,PushKind,PushPairing}.swift`、`src/PurrdrHTTPS/HostServicePushPluginInstaller.swift`、`src/PurrdrSSH/SSHPushPluginInstaller.swift`、`src/App/Purrdr/BackendConfiguration.swift`
- 本機唯讀指令:`herdr plugin list --plugin purrdr.push --json`(`version` 0.1.0、`resolved_commit` 7d821c3)、`herdr plugin log list`(只有 command／event／exit code／輸出)、`herdr status`(0.9.5)
