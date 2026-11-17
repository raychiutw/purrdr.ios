# AGENTS.md

## 專案性質

Purrdr:在 iPhone／iPad 上看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機進那台電腦。原生 SwiftUI,最低 iOS 26,用 Xcode 27 建置,Universal,bundle id `com.raychiu.purrdr`,要上架 App Store。

- 詞彙在 `GLOSSARY.md`,UI 規範在 `DESIGN.md`,難以逆轉的決策在 `docs/adr/`,一手來源研究在 `docs/research/`。
- **clean-room**(ADR-0001):不閱讀、不複製 herdrchat 原始碼;只依據 `docs/research/herdrchat-behavior-spec.md`、herdr 官方文件與真實主機實測。
- 舊名 Drover Chat 已改為 Purrdr(ADR-0009);ADR-0001～0008 與 `docs/research/` 保留舊名，對照表見 ADR-0009。
- 設計原型保存在 `prototype/design-directions` 分支，不合併。

## 常用指令

```bash
xcodebuild -showComponent MetalToolchain | grep -q 'Status: installed' \
  || xcodebuild -downloadComponent MetalToolchain               # 一次性：SwiftTerm 的 Metal shader 需要(Xcode 27 不內建，約 900 MB)
swift test --explicit-target-dependency-import-check error     # package 全部測試，並檢查依賴方向
swift test --filter PurrdrCoreTests                             # 單一 test target(或 --filter 測試 suite 的型別名)
xcodebuild test -project src/App/Purrdr.xcodeproj -scheme Purrdr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -skipPackagePluginValidation \
  -only-testing:PurrdrUITests/AgentListUITests                  # UI 測試：本機跑，只跑有修改到的類別(CI 不做)。模擬器固定一台「iPhone 17」,不要另外建立或讓 Xcode clone
rm -rf .derivedData/package/Package.xcresult && xcodebuild build -scheme Purrdr-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData/package \
  -resultBundlePath .derivedData/package/Package.xcresult -skipPackagePluginValidation \
  && xcrun xcresulttool get build-results --path .derivedData/package/Package.xcresult | jq .warningCount  # 以 iOS 編譯 package,warning 要是 0
scripts/record-herdr-fixture.sh <檔名> <method> [params] [ssh 目的地]  # 從真實主機錄 herdr 回應，見 tests/PurrdrTestSupport/Fixtures/README.md
scripts/strings.sh sync                                          # 把畫面新字串加進 String Catalog(之後補繁中);check 只檢查(CI 也跑)
PURRDR_WINDOWS_HOST=user@host PURRDR_WINDOWS_KEY=<私鑰> \
  python -I scripts/windows-upload-repro.py                      # Windows 上傳與 stdin stub 經真正 sshd 的回歸檢查(案例見腳本說明);Windows 開發機 SSH 到本機就能跑
```

warning 當 error 有三道:`Package.swift` 的 `treatAllWarnings`(只對 macOS,也就是 `swift test`)、app 專案的 `SWIFT_TREAT_WARNINGS_AS_ERRORS`,以及上面的 package iOS 編譯(Xcode 建置 app 時會把 package 的 warning 壓掉，所以不能省)。package iOS 編譯不能加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`:命令列的設定會套到 SwiftTerm、swift-nio 等遠端 package,跟 Xcode 給它們的 `-suppress-warnings` 衝突，所以改數 result bundle 的 warning。

SwiftTerm(1.19)的需求：編譯 `Shaders.metal` 要 **Metal Toolchain**(上面第一行，裝過就好);它也帶 build-tool plugin(`SwiftTermBuildInfoPlugin`),命令列 `xcodebuild` 沒辦法像 Xcode 介面那樣按「信任」,所以**每個 `xcodebuild build`／`test` 都要加 `-skipPackagePluginValidation`**,否則停在「Validate plug-in」。`swift test` 不需要。

CI(`.github/workflows/ci.yml`):`swift test` + package iOS 編譯、app 編譯(零 warning)、可攜核心用 Swift SDK for Android 交叉編譯(aarch64、x86_64,API 28)、後台測試(`backend/`,vitest)。

TestFlight(`.github/workflows/testflight.yml`,#36):合併進 `master` 自動上傳(只改 `docs/`、`.md` 不上傳),也可 `gh workflow run testflight.yml --ref master`。PR 的 CI 已通過就不重測，否則先跑 `ci.yml`。archive 不簽章、ad-hoc 寫入 entitlements,匯出時以 App Store Connect API key 自動簽章(Apple 雲端管理的 Distribution 憑證),上傳前檢查匯出的 entitlements(推播 production、time-sensitive、Sign in with Apple),最後 `scripts/wait-for-testflight.rb` 等 build 可測試(內部群組「內部測試」自動分發)。build 號是 `GITHUB_RUN_ID`;**版本號是 `MARKETING_VERSION`(4 處),每次發佈前要遞增**。需要 GitHub environment `testflight`(部署分支限定 `master`):變數 `APPLE_TEAM_ID`,secret `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`(`.p8` 全文;key 要 **Admin** 角色)。上架的其他人工步驟見 `docs/launch/checklist.md`。

## 架構

分層由 SwiftPM target 強制依賴方向。頂層固定是 `src/` 和 `tests/`:

```text
Package.swift                  # 根目錄 local package,用 path: 指向 src/、tests/
src/App/Purrdr.xcodeproj       # app target、UI test target(buildable folders)
src/App/Purrdr/                # @main(PurrdrApp)= 唯一的 composition root;AppIcon.icon、Assets.xcassets(AccentColor)
src/PurrdrCore/                # 可攜核心：主機通道 HostChannel(真 SSH:SSHHostChannel)、主機指令建構 HerdrCommand、herdr client、連線測試 HostProbe、領域型別
src/PurrdrDemo/                # 可攜:Demo 主機 DemoHost(HostChannel 的實作)
src/PurrdrFeatures/            # SwiftUI 畫面 + 每畫面一個 @MainActor @Observable model
tests/PurrdrTestSupport/       # 假主機 FakeHost、錄製回應 Fixtures/
tests/PurrdrCoreTests/  tests/PurrdrFeaturesTests/
tests/PurrdrUITests/           # XCUITest
backend/                       # Purrdr 後台(Cloudflare Worker + D1,TypeScript),說明見 backend/README.md
```

依賴方向:`App → Features → Core ← Demo ← App`。**Features 不 import Demo**:畫面只透過 `HostChannel` 拿資料，不知道背後是真主機、假主機或 Demo。

- **可攜核心**(PurrdrCore、PurrdrDemo,ADR-0006)只能 import Foundation 與 swift-nio／swift-nio-ssh／swift-crypto 系列。Apple 專屬的東西(SwiftUI、Security、StoreKit、SwiftData…)放 Features 或 app,以 protocol 從核心注入。`PortableCoreImportTests` 在 `swift test` 先擋;CI 的 Android job 是最終守門。新增可攜 module 時兩邊(測試的允許清單、CI 的 `--target`)都要更新。
- **主機通道**(`HostChannel`):`execute(command)` 回傳 `ExecSession`(stdout／stderr／exit 串流，可寫 stdin、送 EOF、關閉);`openPTY(PTYRequest)` 回傳 `PTYSession`。連線重用、逾時、「連線層失敗不重送」都封裝在實作內;`disconnect()` 關掉底層連線。
- **真 SSH**(`SSHHostChannel`,ADR-0003):swift-nio-ssh,Tailscale SSH 用 `none` 認證。沒有 host key pin 時**不登入**,丟 `SSHConnectionError.hostKeyUnverified(presented:)` 讓畫面請使用者確認;指紋不符丟 `hostKeyChanged`。主機設定與 pin 存 Keychain(`KeychainHostStore`,解鎖時、僅此裝置)。
- **herdr client**:每個請求開一個 `herdr remote-api-bridge`,stdin 寫一行請求、**不送 EOF**,讀到第一行回應後關閉通道(行為規格 §3.3)。錯誤 envelope → `HerdrError.herdr(code:message:)`,未知碼保留 herdr 原文。wire format(snake_case)只在 `HerdrClient.swift` 處理。
- **主機指令建構**(`HerdrCommand`):POSIX 指令前綴明確 PATH、引號用 `'"'"'`(行為規格 §3.2)。herdr 路徑與具名 session 由 `HerdrInstallation` 帶入(`--session <name>` 放在子指令前;`--version`、`update` 不帶)。
- **Windows 主機**(#26):呼叫端照常送 POSIX 指令，`WindowsHostChannel`(包住真正的通道;`HostsModel` 依主機設定的 `operatingSystem == .windows` 套上;作業系統未知(主機同步帶來的新主機)時包 `OperatingSystemDetectingChannel`,第一個指令前先偵測、存回主機設定，偵測完才送指令;連線測試偵測到 Windows 後自己套上)在通道層換成 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`,所以不要求 Git Bash。herdr 指令把 `PATH=… '<herdr>' 參數…` 換成 `& $h 參數…`(找不到 `herdr` 試 `%LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe`,`update --handoff` 換成 `update`);對話紀錄、圖片／檔案上傳、資料夾清單、主機檔案讀寫(`HostFileScript` 的讀、compare-and-swap 寫、找最新檔，含推播配對清單;版本是 SHA-256:大小,讀的輸出多一行 `home C:/Users/<帳號>`,`HostFileRead.operatingSystem` 由它判斷)與 Claude slash 清單探索有同樣輸出格式與 exit code 的 PowerShell 版本(`WindowsScripts`,#68),其他指令丟 `WindowsCommandError.unsupported`,不把 POSIX 腳本送過去。Windows 的差異：主題讀 `%APPDATA%\herdr\config.toml`(`HostThemeHost.windowsConfigPath`);Claude 用量的包裝是 `statusline.ps1`,指令 `powershell.exe … -ExecutionPolicy Bypass -File '<家目錄>/.purrdr/claude-usage/statusline.ps1'`(Claude Code 經 Git Bash 或 PowerShell 跑都可以，原本的 status line 以 Git Bash 執行);Codex 啟動器做不到(丟 `unsupported`,畫面顯示「Windows 主機目前還不能用這項功能」)。唯讀腳本經 stdin 送給固定的 stub(cmd 的命令列上限 8,191 字元),**不靠 EOF**:stub 讀到結束標記行、上傳讀剛好宣告的大小;同一個指令只送一次 EOF。stdin 以 console stream 的原始 handle 建 `FileStream` 讀(`WindowsScripts.openStdin`;經 sshd 直接讀 console stream 超過約 128 KiB 會卡住，取不到 handle 時退回 console stream)。PowerShell 函式一律 `P` 開頭(alias 優先於函式，`rd` 是 Remove-Item)。路徑驗證、切段、上一層與顯示(列表副標、資料夾瀏覽)都認 `C:\…`(`HostPathSyntax`);錯誤訊息的 CLIXML／Rust Debug 格式由 `WindowsErrorText` 整理。偵測：`uname -s` 的 `MINGW64_NT-…`／`MSYS_NT-…`,沒有 `uname`(cmd／PowerShell)時再跑 `PowerShell.windowsProbe`。Windows 沒有 live handoff:更新 herdr 後請使用者重啟伺服器(`HerdrUpdateOutcome.restartServerRequired`)。
- **檔案上傳的 gzip 傳輸**(#79):`HostFolders` 以 `UploadTransfer.prepare` 決定傳輸編碼(已知壓縮格式的副檔名、gzip 後沒有至少小 10% 都照原樣傳;圖片上傳不用)。gzip 封裝(標頭、CRC32、原始長度)在可攜核心(`Gzip`),原始 DEFLATE 由平台注入(`RawDeflate`;iOS 是 Features 的 `SystemDeflate`)。上傳指令多兩個參數：傳輸編碼(`identity`／`gzip`)與傳輸大小;主機檢查傳輸 bytes 等於傳輸大小、解壓後等於原始大小，否則 exit 75 並刪暫存檔。POSIX 用 `gzip -dc`(主機沒有 `gzip` 時 exit 69,client 改用 identity 重傳一次，並記在那台主機的 `HostGzipAvailability`,之後直接用 identity),Windows 把傳輸 bytes 寫進第二個暫存檔再以 .NET `GZipStream` 解壓(不整個放進記憶體)。上限以原始大小判斷(附圖的單張上限也是以使用者挑的原始圖片判斷)。測試用的 DEFLATE 與解壓是系統 `gzip`(`StandardGzip`／`StandardRawDeflate`,只在 macOS)。
- **Purrdr 後台(會員)**:核心的 `MemberSession`(actor)管登入與權杖(更新權杖存 `TokenStore`,iOS 是 Keychain;401 自動換權杖重送一次),經 `BackendTransport` 送出;iOS 傳輸是 Features 的 `URLSessionBackendTransport`。wire format(camelCase)只在 `MemberSession.swift`,契約在 `backend/README.md`。`-uiTesting` 時權杖只放記憶體、後台指向 `backend.invalid`。app 端測試用 `HTTPStub`(URLProtocol)擋後台。
- **訂閱(Purrdr Plus)**:StoreKit 2 在 Features 的 `StoreKitPlusStore`(`PlusStore` 協定，測試用假 store);購買帶 `appAccountToken` = 會員 ID,簽章交易(JWS)原封交給後台驗證，送到後台才 finish。`SubscriptionModel.isPlusActive` 是推播與主機同步的開關。StoreKit 設定檔 `src/App/Purrdr.storekit` 由 scheme 的 Run 指定(在 Xcode 執行時用);命令列 `xcodebuild test` 不套用它，所以 `-uiTesting` 改用 app 內容相同的替身 `UITestingPlusStore`(也保證不連網路),設定檔內容由 `StoreKitConfigurationTests` 檢查。`SKTestSession` 需要 app 宿主，`swift test` 不能用。後台的權限判定見 `backend/README.md`。
- **主機同步**(#30):核心 `HostSyncJournal` 記這支裝置的修改時間與已同步版本，決定要上傳的變更並把後台結果併回;上傳內容是獨立型別 `SyncedHost`(只有名稱、位址與埠、使用者、連線方式、host key 指紋,**私鑰與密碼永不上傳**)。Features 的 `HostSyncModel` 開啟前與每次同步前看 `isPlusActive`;`HostsModel.changeRecorder` 通知修改，`applySynced` 套用結果。最後修改者勝與刪除紀錄由後台判定(`backend/README.md`)。
- **平台服務**(Seam 3):`PlatformServices`(開外部網址、剪貼簿;系統實作 `SystemPlatformServices`),測試用記錄呼叫的假實作。App Store id(`6835416115`,與後台 `APP_STORE_APP_APPLE_ID` 同一個數字)、隱私權政策、支援頁、使用條款(Apple 標準 EULA)都只在 Features 的 `PurrdrLinks`(app 的 `AppStoreConfiguration` 由它組出設定頁連結)(`PurrdrLinksTests` 核對字面值),網頁原始碼在 `docs/site/purrdr/`。
- **歡迎頁與評分**(#34):`WelcomeModel`(`WelcomeStore`,UserDefaults key `welcomeSeen`)第一次開啟時由 `TopNavigationModel.launched(welcome:)` 開出 `WelcomeView`(sheet;準備事項、Try the Demo、Add Host、Rate Purrdr),設定頁「Show Welcome」可再看。`ReviewPrompt`:主機收下第 3 個 prompt(`ConversationModel.onPromptDelivered`,經 `HostsModel.reviewPrompt`,所有聊天共用)時請求評分，同一個 app 版本只一次;app 以 StoreKit `AppStore.requestReview(in:)` 實作,`-uiTesting` 不叫出系統對話框。
- **推播**(ADR-0004、#29):主機外掛在本 repo 的 `host-plugin/`(herdr plugin manifest + `notify.sh`(sh + curl)／`notify.ps1`(Windows,best-effort)),發佈成公開 repo `raychiutw/purrdr-host-plugin` 後由 app 經 SSH `herdr plugin install` 安裝(來源常數 `PushSettings.pluginSource`)。核心 `PushHost`:每支裝置的配對檔 `~/.purrdr/push-<裝置 id>/pairing`(經 `ReversibleHostWrite`)、只有 Purrdr 裝的外掛才在最後一支裝置關閉時移除(紀錄在 `~/.purrdr/push-plugin/`)。配對密鑰只在主機上，後台與 app 只有它的 SHA-256。Features:`PushService`(後台、權限與 token、`PushPairingStore`)、`PushModel`(選取中主機的開關，`HostsModel.push`)、`PushNotificationRouter`(點通知 → `HostsModel.open(_:)`)、`SystemPushPlatform`(iOS);app 的 `PushAppDelegate` 接 APNs token、前景不跳通知。外掛腳本以 `HostPluginScriptTests` 在暫存家目錄實跑(假 curl／herdr),主機端用 `FakeHerdrPluginCLI`。
- **主機主題與 You should know**(#23):核心 `HostTheme`(解析 herdr `config.toml` 的 `[theme]`、內建主題色票、對比 < 4.5:1 退回系統)、`HostThemeHost`(讀設定;經同意寫參考檔 `~/.purrdr/theme/README.md`)、`YouShouldKnowStore`／`YouShouldKnowHost`(找最新 store `HostFiles.newest`、compare-and-swap 寫回、衝突重試一次、還原只撤掉 Purrdr 加進 `known` 的句子)。Features:`HostThemeModel`、`YouShouldKnowModel` 每台主機各一份(`HostMember`)。主題套用選取中主機的(`HostsModel.hostTheme`,`.selectedHostTheme(hosts)` 接在 `TopNavigationView` 的三欄／一疊與 `PaneWindowView` 上，sheet 接在外面所以不套);註記合併所有主機(`MergedAgentListModel.notes`),聊天輸入列上方用聊天所在主機的那份。
- **出口合規(只用系統加密)**:`ITSAppUsesNonExemptEncryption = NO` 的前提是 app 只用作業系統提供的加密——CryptoKit(含經 swift-crypto `Crypto` 轉呼叫)、CommonCrypto、系統 TLS。**不可**自寫加密演算法、加入 `_CryptoExtras`、OpenSSL／libsodium 之類的第三方加密;所以有 passphrase 的 OpenSSH 私鑰(bcrypt KDF)不支援，回 `SSHKeyImportError.passphraseProtected`。`PortableCoreImportTests` 的允許清單不含 `_CryptoExtras`。見 `docs/launch/checklist.md` 1.14。
- **DI**:只用 initializer 注入;畫面 model 由 composition root 建立後傳入。
- **Concurrency**:核心型別是 `Sendable` value type 或 actor;畫面 model 放在 main actor。

## 在地化

- 英文是開發語言(key 就是英文原文),另有繁體中文(台灣用語，詞彙依 `GLOSSARY.md`;Agent、Workspace、Tab、Pane、session 保留英文)。
- String Catalog 只有一份：`src/App/Purrdr/Localizable.xcstrings`(放在 app,因為 SwiftUI 與 `String(localized:)` 預設查 `Bundle.main`,package 程式碼不必加 `bundle:`)。
- 寫畫面時：吃 `LocalizedStringKey` 的 API(`Text("…")`、`Button("…")`、`.navigationTitle("…")`)直接寫英文;回傳 `String` 的地方用 `String(localized: "…")`;
  不翻譯的值用 `Text(verbatim:)`。不要用 `Text(英文 String 常數)`(verbatim,不會翻)。
- 加了字串就跑 `scripts/strings.sh sync`(以編譯器抽出 package 字串、標 `extractionState: manual`),再補 `zh-Hant`。
  `scripts/strings.sh check`(CI)擋缺 key／沒翻／已不用;`StringCatalogTests` 擋格式符不符與 GLOSSARY 避免的詞。
- 可攜核心(PurrdrCore)不放顯示字串;要翻的英文在 Features 對應。
- 不提供 app 內深淺色設定(跟隨系統)。
- UI 測試預設以英文啟動(`LaunchHelper` 帶 `-AppleLanguages (en)`;模擬器系統語言是繁中)。測繁中：`launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])`。

## 測試慣例

- 單元與 integration 測試用 Swift Testing;UI 流程用 XCUITest。測試名稱使用 `GLOSSARY.md` 的詞。
- **Seam 1 主機通道**:核心與畫面 model 的測試都透過**假主機**:

  ```swift
  let host = FakeHost()
  await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
  let model = AgentListModel(client: HerdrClient(channel: host))
  await model.load()
  #expect(await host.executions.first?.stdinText == "…")   // 斷言送出的指令與 stdin
  #expect(await host.executions.first?.closedStdin == false)  // bridge 規則
  ```

  - `expect` 的指令字串必須完全相同;沒預期的指令一律丟 `FakeHostError.unexpectedCommand`。`unmetExpectations` 列出沒被執行到的預期。
  - `.recorded(檔名, keepsOpen: true)`:回完不結束(像訂閱串流),之後用 `host.send(stdout:toExecution:)`／`host.finish(execution:)` 推事件或斷線。
  - 錄不到的情境用 `.recorded(檔名) { SnapshotEdit.agent("w1:pA", in: &$0) { … } }` 以真實回應為底改動，改了什麼寫在測試裡。
  - `.recorded(檔名)` 回放 `Fixtures/herdr-<版本>/` 的錄製檔，等 stdin 收到一行才回(模擬 bridge);一般指令用 `FakeReply(stdout:stderr:exitCode:)`,立即回應。
  - PTY:`expectPTY(request, output:)`,之後看 `host.ptys` 的輸入與尺寸變更。
  - 錄製檔一律從真實主機錄(`scripts/record-herdr-fixture.sh`),個人資料換成假值，不照程式碼手寫。
- **會寫入主機的功能**(ADR-0002:Claude 用量、主題、Codex 啟動器、推播外掛)一律經 `ReversibleHostWrite`(安裝紀錄在 `~/.purrdr/<功能>/`,可完整還原),同意存在 `HostWriteConsentStore`。測試用 `LocalShellHost`(只在 macOS):以真的 `/bin/sh` 執行主機腳本，`HOME` 是暫存資料夾;「還原後與安裝前完全相同」以 `DirectorySnapshot(of: host.home) == before` 斷言。絕不對真正的家目錄測試。
- **Demo 主機**(`DemoHost`,行為規格 F21):對真正 client 送出的**精確指令字串**回應，所以走的是正式程式路徑。App Review 與 UI 測試都靠它;Release 也會帶。目前內容：三個 Agent——`w1:p1` Claude Code done(workspace `ledger`)、`w2:p1` Claude Code blocked(`weather-app`)、`w3:p1` Codex working(`notes`,畫面有即時預覽;收到 Esc／ctrl+c 變 done);接受 `events.subscribe`(回 ack 後保持開著、不送事件);Claude Code 的 slash 清單發現(`DemoSlash`:plugin `demo-kit` 以 `plugin.json` 宣告兩個巢狀 skill、停用的 `old-kit`、使用者層一個 skill 與一個指令);ledger 送出 `/model` 開出模型面板(畫面上有 `▔` 分隔的 Claude 面板;方向鍵移動游標、←/→ 調整 effort、Enter／`s` 選定、Esc 關閉，不寫進對話紀錄);`/effort` 開出 effort 滑桿面板(low…max,←/→、Enter 確認、Esc 取消);送給 Claude 的 `!` 指令在對話紀錄接上 shell 交換(輸入行與固定的輸出行);回顯的 PTY shell、不認得的指令 exit 127。**示範主機**(#34,`DemoCompanionHost`,正式 Demo 也有):Demo 主機出現在列表時一起出現「Studio Mac」(通道是 Demo 主機)與一律連不上的「Build Box」(`DemoUnreachableChannel`),演出多主機合併列表與連線中斷;不是已存主機(不在主機清單、不同步),UI 測試要加 `-demoCompanions` 才有。範例內容自己寫，不沿用 herdrchat 的文字。Demo 演不出來的功能，先加 Demo 情境。`ScreenshotTourUITests` 以 Demo 逐一打開主要畫面(列表與 workspace 卡片、需要你、subagent、slash 選單、`/model`／`/effort` 卡片、`!` 指令、終端機、多主機含一台連不上、推播設定、歡迎頁),`scripts/screenshots.sh [輸出資料夾] [模擬器]` 跑它並匯出 PNG(在 UI 測試鎖內)。
- **SSH 通道**的測試對 `tests/PurrdrCoreTests/Support/TestSSHServer.swift`(swift-nio-ssh server 角色，只接受 `none` 認證)跑，斷言連線數、收到的指令、PTY 請求。
- **Windows 真實主機整合測試**(`WindowsRealHostIntegrationTests`):`PURRDR_WINDOWS_HOST=user@host[:port]`、`PURRDR_WINDOWS_KEY=<OpenSSH 私鑰路徑>`(可加 `PURRDR_WINDOWS_FINGERPRINT`)。既有 workspace 只讀;寫入只在 `%TEMP%\purrdr-test-<亂數>`(測完刪掉，家目錄 `USERPROFILE` 與 agent 設定目錄以環境變數指過去;主機檔案的還原以資料夾快照 `WindowsTemp.snapshot` 比對),Pane 終端機只開在自建的 `purrdr-test` workspace(只有 shell,測完以建立時拿到的 id 關閉)。預設 shell 是 cmd／PowerShell 的情況以 `DefaultShellChannel` 在 Git Bash 裡明確呼叫模擬。
- **真實主機整合測試**(`RealHostIntegrationTests`)以環境變數開啟、只跑唯讀指令:`PURRDR_REAL_HOST=user@host[:port]`(可加 `PURRDR_REAL_HOST_FINGERPRINT`、`PURRDR_REAL_HOST_SESSION`)經 Tailscale SSH;`PURRDR_LOCAL_HERDR=1` 讓本機的真 herdr 經測試用 SSH 伺服器跑。Tailscale SSH 不接受同一台機器連自己的 tailnet IP,要從另一台裝置跑。
- **UI 測試**一律用 `XCUIApplication.launchUITesting(flags:contentSize:)` 啟動(帶 `-uiTesting`,只用 Demo 主機、不連網路;主機存在記憶體，任何主機的通道也是 Demo 主機)。元素用 accessibility identifier 找(例：Agent 列是 `agent.row.<主機身分>/<pane id>`,主機身分是主機 id,Demo 主機是 `demo`,如 `agent.row.demo/w1:p1`)。多主機情境旗標:`-seedHost`(已存主機 Studio Mac,通道是 Demo)、`-seedUnreachableHost`(已存主機 Build Box,一律連不上)、`-selectDemo`、`-demoCompanions`(正式 Demo 的示範主機，見下)。`-showWelcome`:當作第一次開啟(UI 測試預設已看過歡迎頁)。列表是 lazy,畫面外的列不在 accessibility tree:找列一律用 `XCUIApplication.reveal(_:)`,不要直接 `waitForExistence`。
- TDD 紅綠燈的本機紀錄放 `.tdd-logs/`(不進 git),摘要寫在 PR。

## 開發流程

- 走 Matt Pocock skill 工作流:`/grill-with-docs` → `/to-spec` → `/to-tickets` → `/implement`。
- TDD:production code 變更先寫失敗測試，並真的跑出紅燈、留下輸出。
- **完成定義**:`swift test` 與 `xcodebuild test` 全部通過、零 warning;UI 測試在本機只跑有修改到的類別;涉及畫面者逐項通過 `DESIGN.md` 與 `docs/research/apple-hig-drover-chat.md` 第 20 節的相關項目。
- 不直接 commit 到 `master`:開 feature branch,push 後開 PR,合併用 **merge commit**,不用 squash。
- 文件、註解、commit message 用繁體中文(台灣用語),技術名詞保留英文。

## Agent skills

### Issue tracker

Issues 與 spec 放在 GitHub Issues(`raychiutw/purrdr.ios`),用 `gh` CLI 操作。見 `docs/agents/issue-tracker.md`。

### Triage labels

使用預設的五種 triage label:`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。見 `docs/agents/triage-labels.md`。

### Domain docs

單一 context:根目錄 `GLOSSARY.md` 加 `docs/adr/`。見 `docs/agents/domain.md`。
