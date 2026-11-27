# App 進背景 SSH 就斷：原因、平台限制與改善選項(截至 2026-11-25)

> 標記:**【文件】** Apple／Tailscale 官方文件;**【論壇】** Apple Developer Forums 上 Apple DTS 工程師(Quinn "The Eskimo!")的回答;**【原始碼】** 第三方官方原始碼固定連結;**【程式】** 本 repo 檔案與行號(master `15dc383c`);**【推論】** 由前者推得、未實測;**【未證實】** 找不到一手來源。
>
> 第三方原始碼版本:swift-nio `b003027f`、Blink Shell `66691814`(2026-11-25 取用)。

---

## 1. 結論摘要

1. **TCP 連線在 app 被 suspend 時斷，是 iOS 的規則，不是 bug。** Apple DTS 2025～2026 年的說法是：現在的 iOS「app 一被 suspend 就立刻 defunct」連線，不必等鎖螢幕;對端會看到連線關閉。BSD socket(swift-nio 的 `NIOPosix` 用的就是它)與 Network framework 在這點行為相同。沒有通用的背景模式能讓一般 app 的 TCP 一直活著(§2)。
2. **「一進背景就斷」比平台規定的更早，這部分是 app 自己造成的**。Purrdr 進背景時沒有替 SSH 連線申請 background task:只有關 Pane 終端機(最多等 3 秒)和寫流量檔兩個短 background task。所以進背景後幾秒內 app 就被 suspend,連線也跟著 defunct(§3.2)。用 background task 本來可以多撐約 30 秒，Apple 也明說這是正當用途:「使用者離開後很快回來時，不必重新連線」。
3. 其他 app 自己造成、**體感上像斷線**的行為:
   - **Pane 終端機一進背景就主動掛斷**(#357,刻意設計)。
   - **`scenePhase` 一離開 `.active`(含 `.inactive`,例如拉下控制中心)**,Agent 列表的事件訂閱、聊天的輪詢與對話紀錄追蹤都會取消。
   - **網路路徑一變就丟棄所有主機連線**。路徑變化包含 Tailscale 的 utun 介面上下線，以及待機時 Wi-Fi 被系統斷開。
4. **回前景的重連**:背景超過 60 秒時先跑 3 秒的喚醒探測。背景不到 60 秒時不探測，只能等 keepalive 或指令期限發現連線已死(最壞約 15～20 秒)。這段時間畫面顯示「連線中」。
5. **建議(§5)**:
   - 先看診斷紀錄確認實際的斷線原因。
   - 進背景時以 `beginBackgroundTask` 保留連線一小段時間(約 25 秒，期間不輪詢)。
   - 回前景時改成「被 suspend 過就直接重撥」並預先撥號，畫面先顯示快取內容。
   - 長時間背景交給推播補位(現有的推播，進一步可加 Live Activity)。
   - 不用 VoIP、audio、location 背景模式撐連線，有審查風險。mosh 式重寫成本太高，而且 Purrdr 的狀態本來就在主機上。

---

## 2. iOS 平台的限制

### 2.1 背景執行：預設是 suspend

- **【文件】** 「通常 app 在背景時處於 suspended 狀態」;只有少數背景執行模式(播放音訊、位置更新、VoIP…)能讓 app 在背景執行，而且「請節制使用……若有替代方案就用替代方案」。— [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- **【文件】** 進背景時 `applicationDidEnterBackground(_:)`「有五秒可以執行工作並返回。返回後不久，系統就把 app 放進 suspended 狀態」。— [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- **【文件】** 背景中的 app「必須做越少事越好，最好什麼都不做」;UIKit「隨時可以中斷背景或 suspended 的 scene 以回收資源」。— [Managing your app's life cycle](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle)
- **【論壇】** 「答案是你做不到。iOS 嚴格限制背景執行，預設在使用者把 app 移到背景後不久就 suspend 它」。沒有通用機制可以「在背景持續執行程式」,也不能「因網路或 IPC 請求在背景恢復執行」。每種背景機制都有特定用途，「不要用在其他用途。使用背景 API 前先讀 App Review Guidelines 2.5.4」。— Quinn,[iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525)(2021-07 起，最後更新 2026-01-09)
- **【論壇】** 使用者在多工畫面滑掉 app,iOS 會解讀為「使用者不要這個 app 執行」,沒有文件化的方法可以推翻。— 同上

### 2.2 `beginBackgroundTask` 的時限

- **【文件】** 這個 API「向系統要額外的背景執行時間」,用在「工作沒做完會傷害使用者體驗」的時候。執行時間有限：時間到之前沒呼叫 `endBackgroundTask(_:)`,「系統會殺掉 app」。要盡早呼叫，最好在進背景之前;快被 suspend 時才呼叫，可能拿不到。— [beginBackgroundTask(withName:expirationHandler:)](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))
- **【文件】** `backgroundTimeRemaining`:「系統狀況可能提早結束背景執行，方式是呼叫 expiration handler 或終止 app」。— [backgroundTimeRemaining](https://developer.apple.com/documentation/uikit/uiapplication/backgroundtimeremaining)
- **【論壇】** 「在目前的系統上，預期約 **30 秒**」。這段時間是整個 app 共用的，「連開兩個 background task 也不會變成 60 秒」;系統隨時可以呼叫 expiry handler 收回,handler 要在約 1 秒內結束，否則被看門狗殺掉。— Quinn,[UIApplication Background Task Notes](https://developer.apple.com/forums/thread/85066)(2017 起，最後更新 2023-06)
- **【論壇】** Quinn 列出 background task 的正當用途之一:「延後 app 被 suspend,**使用者離開後很快回來時，不必重新連線**,改善使用者體驗」,以及「讓你有機會乾淨地關掉連線」。— [Maintaining a TCP Connection in the Background](https://developer.apple.com/forums/thread/97824)(2018-03)

### 2.3 suspend 時 socket 會怎樣

- **【文件】** TN2277:suspend 時「app 程序裡沒有任何程式碼在執行」,而且「系統可能從網路 socket 底下回收資源，從而關閉該連線」。被回收的 socket「所有操作都會失敗」(錯誤常是 `EBADF`),唯一能做的是關掉它;高階 API 會把它回報成錯誤。資料 socket 的建議:「如果重新開啟便宜、使用者看不出來，進背景時就關掉，回前景再開」;重新開啟慢或使用者看得到時，可以留著，但要處理錯誤。— [TN2277 Networking and Multitasking](https://developer.apple.com/library/archive/technotes/tn2277/_index.html)(2011,封存)
- **【論壇】** TN2277 有些內容已過時:現在的說法是連線被「defunct」,而且「**新版 iOS 在 app suspend 時就 defunct**,不必鎖螢幕」;「TCP 連線一般會在 app 被 suspend 時斷開」。— Quinn,[thread 795697](https://developer.apple.com/forums/thread/795697)(2025-08)
- **【論壇】** 「現在的系統比以前積極得多。系統會在 suspend app 的當下**立刻** defunct」。Network framework 會把連線轉到 `.failed(…)` 並呼叫 state update handler。重點是「是否符合 suspend 的條件，而不是在不在背景」:背景中仍在播音訊、沒被 suspend 的 app 不受影響。— DTS,[thread 840808](https://developer.apple.com/forums/thread/840808)(2026-08)
- **【論壇】** 留著連線不關時,「實際線路上的行為沒有規定」:只被 suspend 時連線是「聾的」;suspend 且被 defunct 時，**對端會看到連線關閉**。BSD socket 與 Network framework 在背景的行為相同，改用 Network framework 不會改變這點。回前景時不必分辨連線是被 defunct 還是自然斷掉:需要連線就重開。— Quinn,[thread 757385](https://developer.apple.com/forums/thread/757385)(2024-06、2024-11)
- **【論壇】** 測試時要從主畫面開 app:接著 debugger 時 app 不會被 suspend,看到的行為不準。— 同上，以及 [thread 97824](https://developer.apple.com/forums/thread/97824)
- **【論壇】** 有 WWAN 的裝置在不需要 Wi-Fi 時，系統會**斷開 Wi-Fi 以省電**。— [thread 97824](https://developer.apple.com/forums/thread/97824)(與 §3.4 的網路路徑變化有關)

### 2.4 哪些背景模式能讓 TCP 活著，以及審查規定

- **【文件】** App Review Guidelines **2.5.4**:「多工 app 只能把背景服務用在其預期用途:VoIP、音訊播放、位置、工作完成、本機通知等。」— [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- **VoIP**:
  - **【文件】** 舊的 VoIP socket(keep-alive)架構在 iOS 9 SDK 正式淘汰。以 iOS 10 SDK 連結的 app 停用這個架構，改用 PushKit。— [QA1938](https://developer.apple.com/library/archive/qa/qa1938/_index.html)
  - **【文件】** 以 iOS 13 SDK 起建置的 app,PushKit 必須搭配 CallKit 處理來電;不支援 CallKit 就不能用 PushKit。— [Responding to VoIP notifications from PushKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
  - **【論壇】** Quinn 反對用舊 VoIP 架構撐 TCP。— [thread 97824](https://developer.apple.com/forums/thread/97824)
  - Purrdr 沒有通話，用不上。
- **audio、location**:
  - 這兩種模式會讓 app 不被 suspend,TCP 也就不會被 defunct(§2.3 的 thread 840808)。
  - 但 2.5.4 要求「用在預期用途」。為了保持連線而播放無聲音訊或追蹤位置，不是預期用途。
- **BGTaskScheduler**:
  - **【文件】** `BGAppRefreshTask` 由系統決定何時執行，每次最多約 30 秒。— [Choosing background strategies for your app](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
  - **【論壇】** Quinn 說 app refresh 不會給固定週期，有些常見情境「完全不給」。— [thread 685525](https://developer.apple.com/forums/thread/685525)
  - **【文件】** `BGProcessingTask` 給充電、閒置時的重度工作。— 同上
  - **【文件】** `BGContinuedProcessingTask`(iOS 26)必須由使用者動作在前景開始，用在有進度的有限工作(匯出影片等),系統以 Live Activity 顯示進度，使用者可以取消。— [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
  - 這幾種都不是用來保持連線的。
- **URLSession 背景 session**:
  - **【文件】** 只支援 HTTP／HTTPS 的上傳與下載，由另一個程序執行。— [background(withIdentifier:)](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))、[Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
  - WebSocket 與 SSH 都不適用。
- **背景推播**:
  - **【文件】** silent push(`content-available`)每次最多 30 秒;每小時超過 3 次會被限流。— [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

### 2.5 swift-nio／swift-nio-ssh 在 suspend 時

- **【原始碼】** swift-nio-ssh 是掛在 NIO `Channel` pipeline 上的協定 handler,原始碼裡沒有 keepalive,也沒有 app 生命週期的處理(GitHub code search `keepalive`、`background` 在 `apple/swift-nio-ssh` 都沒有相關結果)。suspend 對它來說就是底層 TCP channel 出錯或關閉。
- **【原始碼】** swift-nio README 把 `swift-nio-transport-services`(NIOTS,建在 Network.framework 上)列為「對 macOS、iOS、tvOS、watchOS 的一級支援」。NIOTS README 說它提供「等待網路路由可用」以及 Network.framework 內建的 proxy 與 VPN 支援，一般 NIO app「只要換 event loop 與 bootstrap」就能用。兩份 README 都沒有說 iOS 上不能用 `NIOPosix`。— [swift-nio](https://github.com/apple/swift-nio)、[swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services)
- **【原始碼】** NIO 的計時(`NIODeadline.now()`)在 Darwin 上是 `DispatchTime.now().uptimeNanoseconds`。— [`EventLoop.swift` L858–L933](https://github.com/apple/swift-nio/blob/b003027fc38b649a43e9aad77c3d4e4a2c5b6997/Sources/NIOCore/EventLoop.swift#L858-L933)
  - 【未證實】這個時鐘在裝置睡眠時是否前進。如果不前進,keepalive 的間隔在裝置睡眠期間不計時，會影響回前景後第一輪 keepalive 的時機。
- **【未證實】** `NIOPosix` 的 socket 被 defunct 後，回前景時 kqueue 會不會立刻回報錯誤，讓 channel 馬上關閉(`isActive` 變 false)。Network framework 會以 `.failed` 主動通知(§2.3)。BSD socket 依 TN2277,要等「下一個操作」才失敗。

### 2.6 Tailscale

- **【文件】** Tailscale 啟用時，會自動設定一個廣泛的 VPN On Demand 規則，「確保 VPN 在系統重開、自動更新、當機等事件後仍保持啟用」。— [Using VPN On Demand for iOS and macOS](https://tailscale.com/docs/features/client/ios-vpn-on-demand)
  - 【推論】Tailscale 的通道在自己的 Network Extension 程序裡跑，與 Purrdr 是否在前景無關。Purrdr 的 TCP socket 屬於 Purrdr 程序，被 defunct 的是 Purrdr 這一端，Tailscale 開著也救不了。
- **【文件】** Tailscale SSH 的文件沒有提到 session 的閒置逾時或 keepalive。check mode 的預設 check period 是 12 小時。撤銷存取或重啟 tailscaled 會斷掉現有 SSH 連線。— [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
  - 【推論】在 check period 內重撥不會再要求驗證(另見 `docs/research/tailscale-ssh-check-mode.md` 結論 5)。
- 【推論】VPN 重新連上(On Demand 觸發)時，`utun` 介面會出現或消失。`NWPathMonitor` 的 `availableInterfaces` 跟著改變，會觸發 Purrdr 丟棄所有連線(§3.4)。

---

## 3. 本 app 目前的行為(master `15dc383c`)

### 3.1 誰會關連線：進背景時

| 事件 | 做什麼 | 位置 |
|---|---|---|
| `scenePhase` 變 `.background` | 只記錄進背景的時間,**不關 SSH 連線、不申請 background task** | `src/PurrdrFeatures/TopNavigationView.swift:122-124`、`src/PurrdrFeatures/HostsModel.swift:948-950` |
| 同上(App 層) | App 鎖狀態;開 `traffic.flush` background task,寫完流量檔就結束 | `src/App/Purrdr/PurrdrApp.swift:473-478`、`:499-503` |
| Pane 終端機畫面 `.background` 或 `onDisappear` | `BackgroundRelease.hangUp`:開 `terminal.release` background task,送 release、關掉 exec 通道,**最多等 3 秒**就結束 task | `src/PurrdrFeatures/PaneTerminalView.swift:77-91`、`:99-124`;`src/PurrdrAgentFeatures/BackgroundReleaseWait.swift:9`;`src/PurrdrAgentFeatures/PaneTerminalModel.swift:163-175` |
| `scenePhase` 離開 `.active`(**含 `.inactive`**) | `.task(id: scenePhase == .active)` 被取消:Agent 列表的 `run()`(主機更新來源的 `events.subscribe`)、You should know | `src/PurrdrFeatures/AgentListView.swift:104-107`、`:119-123` |
| 同上 | 聊天的 `run()` 結束:停止輪詢與對話紀錄追蹤,`endQuickDisconnectDetection()`;Send When Done 訂閱也結束 | `src/PurrdrFeatures/ConversationView.swift:89-102`;`src/PurrdrAgentFeatures/ConversationModel.swift:1006-1051` |
| 最後一個畫面離開 | `SharedRun` 取消主機更新來源的工作，訂閱的 exec 通道關閉 | `src/PurrdrAgentFeatures/SharedRun.swift:21-44`;`src/PurrdrAgentFeatures/HostUpdates.swift:152-156` |
| 其他 `.task(id: scenePhase == .active)` | 主題、委派卡片、流量頁、輸入列註記等都停 | `src/PurrdrFeatures/HostThemeViews.swift:63-64`、`DelegationViews.swift:225`、`DataUsageView.swift:76`、`ComposerView.swift:197` |

重點:

- 進背景時 app **自己不關 SSH 的 TCP 連線**,只關上面的 exec 通道(訂閱、追蹤、Pane 終端機)。
- 但**沒有任何 background task 保護這條連線**。`terminal.release` 與 `traffic.flush` 一結束(最多約 3 秒),app 就可能被 suspend,TCP 跟著被 defunct(§2.3)。
- `Info.plist` 沒有 `UIBackgroundModes`(`src/App` 下 grep 不到)。

### 3.2 為什麼體感是「一進背景就斷」【推論】

1. 進背景後幾秒內 app 被 suspend(§2.1;只有上面兩個短 background task)。
2. 系統在 suspend 當下 defunct 這條 TCP(§2.3 thread 840808)。主機的 sshd 或 Tailscale SSH 看到連線關閉，所以 `herdr remote-api-bridge` 等子程序收到 EOF 結束。
3. 就算連線剛好沒被 defunct,事件訂閱、聊天輪詢、Pane 終端機也已經在 `.inactive`／`.background` 時被 app 關掉(§3.1)。回來一定要重開這些通道並重讀快照。
4. Pane 終端機是刻意掛斷的(#357:讓電腦上的 Pane 還原成原尺寸)。不論平台怎麼規定，回來都要重新接上。

所以有兩件事要分開看:

- **TCP 斷線**:平台造成，可以延後約 30 秒，但避免不了。
- **畫面上的串流中斷**:app 依設計造成。

### 3.3 回前景時：偵測斷線與重連

| 步驟 | 行為 | 位置 |
|---|---|---|
| `scenePhase` 變 `.active` | `sceneDidBecomeActive`:背景**超過 60 秒**才對每條主機通道跑喚醒探測 | `src/PurrdrFeatures/TopNavigationView.swift:125-128`;`src/PurrdrFeatures/HostsModel.swift:952-968` |
| 喚醒探測 | 在主機跑 `true`,期限 3 秒(含開通道);失敗就 `disconnect()`,並讓列表 `retryNow()` | `src/PurrdrSSH/WakeProbe.swift:8-32` |
| 同時 | `.task(id: scenePhase == .active)` 重新開始：列表 `run()` → 主機更新來源讀快照、重新訂閱;聊天 `run()` → `beginQuickDisconnectDetection()` 並重新追蹤 | `src/PurrdrFeatures/AgentListView.swift:119-123`;`src/PurrdrAgentFeatures/HostUpdates.swift:129-201`;`src/PurrdrAgentFeatures/ConversationModel.swift:1014-1016` |
| 指令遇到已斷的連線 | `connected()` 看 `isActive`,斷了就重撥(撥號合併);開 channel 逾時(20 秒)視為半開，整條丟棄 | `src/PurrdrSSH/SSHHostChannel.swift:148-205`、`:221-232`;期限 `:27-31` |
| keepalive | 一般 20 秒一輪、等回應 15 秒;聊天可見時 5 秒、5 秒(最壞約 15 秒);這一輪間隔內收過資料就跳過 | `src/PurrdrSSH/SSHHostChannel.swift:15-22`、`:386-429`、`:125-135` |
| 失敗退避 | 主機更新來源 1 秒起倍增、上限 30 秒;`retryNow()` 叫醒 | `src/PurrdrAgentFeatures/HostUpdates.swift:193-206`、`:231-233` |
| 畫面 | 連線中的主機到 10 秒換成「仍在連線」 | `src/PurrdrFeatures/AgentListView.swift:108-113`;`src/PurrdrFeatures/ConnectingClock.swift` |
| Pane 終端機 | 回到畫面且是自己放開的，以同一組格數 `resume()` 重新接上 | `src/PurrdrFeatures/PaneTerminalView.swift:80`、`:84-87`;`src/PurrdrAgentFeatures/PaneTerminalModel.swift:153-156` |
| HTTPS(對照) | 心跳一般 15 秒一次、逾時 10 秒，聊天可見時 10 秒與 5 秒;斷線後下一個操作重撥 | `src/PurrdrHTTPS/HostServiceHeartbeat.swift:12-15`;`src/PurrdrHTTPS/HTTPSHostConnection.swift:321-329` |

重連要多久【推論，未實測】:

- **背景超過 60 秒**:探測最多 3 秒，接著重撥。重撥包含 TCP、SSH 握手與認證，以及開 exec 通道，經 Tailscale 估計 1～3 秒。之後讀快照並重新訂閱，合計約 **2～6 秒**。
- **背景不到 60 秒，連線已被 defunct**:
  - 如果 `NIOPosix` 回前景就發現 socket 壞了(§2.5 未證實),立刻重撥，約 1～3 秒。
  - 如果沒發現，第一個指令卡在開 channel,要等快速 keepalive(最壞約 15 秒)或開 channel 期限(20 秒)。這段時間畫面顯示「連線中」,過了 10 秒顯示「仍在連線」。**這是使用者最可能感覺「斷很久」的情況。**
- **Pane 終端機**:除了重撥，還要重新 handshake 接上 Pane,並把 Pane 改成手機尺寸。

### 3.4 網路路徑變化會丟掉所有連線

- `NetworkPaths` 以「狀態 + 排序後的可用介面類型」當簽章(Tailscale 的 utun 是 `other`)。簽章一變，`networkPathChanged` 就 `disconnect()` 所有主機通道與 HTTPS 連線，再讓列表重連。— `src/PurrdrFeatures/NetworkPaths.swift:9-21`;`src/PurrdrFeatures/HostsModel.swift:927-946`;監看在 `src/PurrdrFeatures/TopNavigationView.swift:119-121`
- 【推論】待機時系統可能斷開 Wi-Fi(§2.3)、VPN On Demand 可能重新連上(§2.6)。回前景時路徑監看送出新的簽章，連線就算還活著也會被這裡丟棄。看到的是 `hosts` category 的 `Network path changed (… → …): dropping N host connection(s)`。
- `availableInterfaces` 包含「可用但不是目前路由」的介面，所以行動網路可用性的變化也會觸發。這是 app 自己的取捨(行為規格 §7.4,沿用 HerdrChat),不是平台規定。

### 3.5 怎麼從診斷紀錄判斷是哪一種

在實機從主畫面開 app,不要接 debugger(§2.3),以 Console 篩 subsystem `com.raychiu.purrdr`:

| 紀錄 | 意思 |
|---|---|
| `ssh`:`dial N dropped after Ns: network error: …` 或 `closed by the host or the network` | 平台 defunct 或網路斷了 |
| `ssh`:`… keepalive timeout`、`channel open timeout` | 回前景後半開連線，靠期限才發現(§3.3 的慢路徑) |
| `ssh`:`… disconnect requested by the app` 加上 `hosts`:`Network path changed …` | app 因路徑變化主動丟棄(§3.4) |
| `hosts`:`Wake probe failed after Ns in background …` | 喚醒探測發現連線已死 |

來源:`src/PurrdrFeatures/SSHConnectionLog.swift:9-40`、`src/PurrdrSSH/SSHConnectionDiagnostics.swift:5-16`、`src/PurrdrFeatures/HostsModel.swift:939`、`:967`。

---

## 4. 可行選項比較

| # | 選項 | 能撐多久 | 使用者看到的效果 | 審查風險 | 實作成本 |
|---|---|---|---|---|---|
| A | **進背景時以 `beginBackgroundTask` 保留連線**:background task 期間不輪詢、不更新畫面，只保留 TCP(keepalive 照常);快到期或回前景時結束 | 約 30 秒(系統決定，可能更短，§2.2)。鎖螢幕時沒有意義(Blink 在鎖定時不申請，見下) | 切去別的 app 回覆、複製指令，30 秒內回來時**不用重連**,列表與聊天馬上就緒(但訂閱仍要重開，除非一起保留) | 低：Quinn 明列這是正當用途(§2.2);App Review 2.5.4 的「task completion」 | 低：一個 app 層的 background task 管理者;注意 #492(背景不推進、不寫狀態)與 expiry handler 要在 1 秒內結束 |
| A′ | A 再加上**背景 grace 期間保留事件訂閱**(`.inactive`／短暫背景不取消 `liveUpdates`) | 同 A | 回來時列表狀態已是最新，不重讀快照 | 同 A | 中：要改 `scenePhase` 驅動的 `.task` 鍵;也會讓背景中主執行緒有事做，要守 #492 |
| B | **回前景快速重連並恢復畫面**:記錄這次背景是否超過 background task 的保護時間，超過就直接 `disconnect()` 重撥(不探測);回前景立刻預先撥號;畫面先顯示快取(列表快照、`ConversationCache`),重連前幾秒不顯示「連線中」 | 不延長連線，縮短重連 | 回前景約 1～3 秒恢復;避開 15～20 秒的慢路徑(§3.3) | 無 | 低～中：`HostsModel.sceneDidBecomeActive` 改策略、預先撥號;畫面的延遲顯示 |
| B′ | 路徑變化不再無條件丟棄連線：只在目前路由的介面變了(例如 `NWPath` 的 `usesInterfaceType` 或 gateway 變化)才丟;其餘交給 keepalive | — | 回前景時少一次不必要的重連 | 無 | 低～中：改 `NetworkPaths.signature`;要以實機驗證 Wi-Fi↔行動網路仍能正確切換 |
| C | **把 `NIOPosix` 換成 NIOTS(Network.framework)** | 不延長連線 | 被 defunct 的連線以 `.failed` 主動通知(§2.3),回前景馬上知道要重撥;另外有 Network.framework 的路徑與 VPN 處理 | 無 | 中～高：bootstrap、event loop group、錯誤對應(`SSHConnectionError`)、`TestSSHServer` 與流量計量都要跟著改;Android 版可攜性(ADR-0006)要保留 `NIOPosix` 路徑。【未證實】NIOTS 把 defunct 轉成 channel 關閉的時機 |
| D | **mosh 或類 mosh 的設計**:以 UDP 做狀態同步，沒有連線狀態，回來直接繼續 | 「連線」不會斷，但 suspend 期間仍收不到任何東西;mosh 官網說可以讓筆電睡眠後喚醒，連線仍在、會自動漫遊(§6 出處) | 回前景幾乎立即恢復，不用握手 | 無 | 很高：主機要裝 mosh-server(或自寫協定)、開 UDP 60000–61000;只對終端機有意義。Purrdr 的 Agent 狀態本來就在主機(herdr),快照加游標的重讀已經是應用層的「狀態同步」,mosh 能省的只有握手 |
| D′ | **在主機服務(HTTPS)做可續接的 session**:斷線後以 session token 加序號續接，主機補送漏掉的事件 | 同 D(不延長連線) | 回前景重連後不必重讀全部快照、追蹤從游標接上 | 無 | 中～高：purrdr.host 協定變更(schema、codegen、同步) |
| E | **主機服務(HTTPS)路線本身** | WSS 同樣在 suspend 時被 defunct(§2.3:BSD socket 與 Network framework 行為相同;URLSession 背景 session 不支援 WebSocket,§2.4) | 重連只要 TLS 加 `hello`;追蹤與觀察者在主機上跑，背景期間「卡住、仍在等你」等通知由主機服務送出 | 無 | 已有;差別在主機端繼續工作、推播較完整 |
| F | **推播補位**:現有的「需要你、完成、卡住、提醒」通知(ADR-0004);進一步用 **Live Activity + ActivityKit push** 在鎖定畫面顯示 Agent 狀態 | Live Activity 最多 8 小時(鎖定畫面最多 12 小時);ActivityKit push 有每小時預算，`apns-priority: 5` 不計入預算 | app 不在前景也知道 Agent 狀態;點通知直接進聊天 | 低(用途正確) | 現有推播：已完成。Live Activity:中～高(widget extension、後台 purrdr.server 送 ActivityKit push、主機外掛事件) |
| G | **VoIP、audio、location 背景模式撐連線** | 不被 suspend 就一直活著 | 連線不斷 | **高**:2.5.4 只准用在預期用途;VoIP 需要 CallKit 通話(§2.4);location 耗電、需要位置權限 | 低～中(技術上),但不建議 |
| H | **BGAppRefresh／BGProcessing／BGContinuedProcessingTask** | 不定期、不保證(§2.4) | 對保持連線沒幫助;`BGContinuedProcessingTask` 只適合使用者觸發、有進度的工作(例：大檔上傳) | 濫用時有風險 | — |

同類 app 的官方做法:

- **Blink Shell**(開源)【原始碼】
  - 所有 scene 都進背景時開 `BackgroundExtension` background task,保留時間取 `min(backgroundTimeRemaining × 0.9, 5 分鐘)`。到時或到期就把各 session `suspend()`(存檔)後結束 task。
  - 裝置鎖定時(`isProtectedDataAvailable` 為 false)不申請。
  - 回前景時結束 task。
  - 出處:[`Blink/AppDelegate.m` L161–L268](https://github.com/blinksh/blink/blob/66691814d05f96d8338d4cbb5d081415ac481d67/Blink/AppDelegate.m#L161-L268)、[`SceneDelegate.swift` L233–L257](https://github.com/blinksh/blink/blob/66691814d05f96d8338d4cbb5d081415ac481d67/Blink/SceneDelegate.swift#L233-L257)
  - 另外它的 `UIBackgroundModes` 有 `location`,使用者手動執行 `geo track` 才以 `allowsBackgroundLocationUpdates`、`pausesLocationUpdatesAutomatically = NO` 持續追蹤位置。同一功能也提供「geo lock」(離開範圍就結束所有 session)。出處:[`Blink/Info.plist` L169–L174](https://github.com/blinksh/blink/blob/66691814d05f96d8338d4cbb5d081415ac481d67/Blink/Info.plist#L169-L174)、[`Blink/GeoManager.m` L145–L171](https://github.com/blinksh/blink/blob/66691814d05f96d8338d4cbb5d081415ac481d67/Blink/GeoManager.m#L145-L171)
  - 終端機的長時間存活則靠 mosh。
- **Termius**【文件】
  - 官方 FAQ 說新版 iOS 通常在 20～30 秒內停止背景活動。
  - 建議開「位置追蹤」(副作用是背景連線較不容易中斷)、iPad 分割畫面，以及在主機用 screen／tmux 保住 session。— [How can I keep Termius sessions alive in the background on iOS/iPadOS?](https://docs.termius.com/help-center/faq/how-can-i-keep-termius-sessions-alive-in-the-background-on-ios-ipados)
- **mosh**【文件】
  - SSH 登入後在主機啟動 `mosh-server`,改用 UDP 60000–61000 的 State Synchronization Protocol(SSP)。
  - 會自動漫遊;斷網時警告、恢復後繼續;筆電睡眠喚醒後連線仍在。
  - 出處:[mosh.org](https://mosh.org/)、論文 [Mosh: An Interactive Remote Shell for Mobile Clients(USENIX ATC 2012)](https://mosh.org/mosh-paper.pdf)

Live Activity 出處【文件】:[Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)(8 小時、鎖定畫面最多 12 小時)、[Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)(每小時預算、priority 5 不計入預算)。

---

## 5. 建議

1. **先量再改(0.5 天)**:用實機從主畫面開 app,做「切到別的 app 10 秒、40 秒、2 分鐘」與「鎖螢幕 1 分鐘」四種情境，收 `ssh` 與 `hosts` 紀錄(§3.5)。確認三件事:
   - 斷線原因(defunct 還是路徑變化)。
   - 回前景後多久重連。
   - 是否走了 15～20 秒的慢路徑。

   結果寫回本文件。
2. **選項 B:回前景快速重連(優先)**:
   - 依平台規則(suspend 就 defunct),「背景時間超過保護期」就當連線已死，直接重撥，不再分 60 秒門檻、也不探測。
   - 回前景立刻預先撥號。
   - 畫面先顯示快取，重連的前 1～2 秒不顯示「連線中」。

   這是使用者感受最大的部分，成本低。
3. **選項 A:background task 保留時間(與 2 一起做)**:
   - 仿 Blink:所有 scene 都進背景、而且沒有鎖定時，開一個 app 層的 background task,保留約 25 秒(取 `backgroundTimeRemaining` 的 9 成，上限 25 秒)。
   - 期間只保留 TCP,不輪詢、不寫狀態(#492)。
   - expiry handler 立刻 `endBackgroundTask`。
   - Pane 終端機照 #357 立刻放開(它的 release 本來就在背景 task 內)。
   - 可以考慮把它延到 grace 結束才放開，但會讓電腦上的 Pane 晚 30 秒還原，需要使用者決定。
4. **選項 B′:路徑變化的判斷收窄**:只在實際路由的介面改變時丟棄連線，避免回前景時被無謂的路徑更新丟掉活著的連線。要先由第 1 點的紀錄確認這種情況有發生。
5. **長時間背景交給推播**:現有推播已涵蓋「需要你」等事件。要讓使用者不開 app 也看到進度，下一步是 Live Activity(選項 F),需要 purrdr.server 與主機外掛配合，另開 spec。
6. **暫不做**:
   - C(換 NIOTS):等第 1 點證實 `NIOPosix` 回前景後偵測很慢、而且 B 的「直接重撥」不夠時再評估。
   - D／D′(mosh 式設計):成本高，Purrdr 的狀態已在主機;D′ 可以等 HTTPS 成為主要路線時再評估。
   - G(背景模式撐連線)。

---

## 6. 未證實的地方

- **`NIOPosix` 回前景時會不會立刻發現 socket 被 defunct**(kqueue 回報、`isActive` 變 false),還是要等下一次讀寫或 keepalive。這決定「背景不到 60 秒」的重連是 1～3 秒還是 15～20 秒(§2.5、§3.3)。
- **NIOTS 把 Network.framework 的 `.failed`(defunct)轉成 channel 關閉的時機**(選項 C 的效益)。
- **`NIODeadline`(mach uptime)在裝置睡眠時是否前進**,以及它對回前景後第一輪 keepalive 時機的影響(§2.5)。
- **Tailscale 的 iOS Network Extension 在裝置待機時的行為**:是否會暫停或重建 utun,讓回前景時 `NWPathMonitor` 送出不同的簽章。Tailscale 官方文件只說明 On Demand 規則，沒有說明這一點(§2.6)。
- **系統實際給的背景時間**:Quinn 說約 30 秒，但會變動(§2.2)。本 app 在 iOS 26 實機上拿到多少未量測。
- **Termius 用「位置追蹤」維持背景連線的審查狀況**:只有它自己的 FAQ,沒有 Apple 的說法。Blink 同樣以使用者手動開啟的 `geo track` 做到，是否曾被審查要求修改查不到一手來源。
- §3.3 的重連時間都是推論，沒有實測。
