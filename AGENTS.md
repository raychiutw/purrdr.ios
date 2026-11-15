# AGENTS.md

## 專案性質

Purrdr:在 iPhone／iPad 上看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機進那台電腦。原生 SwiftUI,最低 iOS 26,用 Xcode 27 建置,Universal,bundle id `com.raychiu.purrdr`,要上架 App Store。

- 詞彙在 `GLOSSARY.md`,UI 規範在 `DESIGN.md`,難以逆轉的決策在 `docs/adr/`,一手來源研究在 `docs/research/`。
- **clean-room**(ADR-0001):不閱讀、不複製 herdrchat 原始碼;只依據 `docs/research/herdrchat-behavior-spec.md`、herdr 官方文件與真實主機實測。
- 舊名 Drover Chat 已改為 Purrdr(ADR-0009);ADR-0001～0008 與 `docs/research/` 保留舊名，對照表見 ADR-0009。
- 設計原型保存在 `prototype/design-directions` 分支，不合併。

## 常用指令

```bash
swift test --explicit-target-dependency-import-check error     # package 全部測試，並檢查依賴方向
swift test --filter PurrdrCoreTests                             # 單一 test target(或 --filter 測試 suite 的型別名)
xcodebuild test -project src/App/Purrdr.xcodeproj -scheme Purrdr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -only-testing:PurrdrUITests/AgentListUITests                  # UI 測試：本機跑，只跑有修改到的類別(CI 不做)。模擬器固定一台「iPhone 17」,不要另外建立或讓 Xcode clone
rm -rf .derivedData/package/Package.xcresult && xcodebuild build -scheme Purrdr-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData/package \
  -resultBundlePath .derivedData/package/Package.xcresult \
  && xcrun xcresulttool get build-results --path .derivedData/package/Package.xcresult | jq .warningCount  # 以 iOS 編譯 package,warning 數要是 0
scripts/record-herdr-fixture.sh <檔名> <method> [params] [ssh 目的地]  # 從真實主機錄 herdr 回應，見 tests/PurrdrTestSupport/Fixtures/README.md
```

warning 當 error 有三道:`Package.swift` 的 `treatAllWarnings`(只對 macOS,也就是 `swift test`)、app 專案的 `SWIFT_TREAT_WARNINGS_AS_ERRORS`,以及上面的 package iOS 編譯(Xcode 建置 app 時會把 package 的 warning 壓掉，所以不能省;因為有 swift-nio 等遠端依賴，不能加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`,改數建置結果的 warning)。

CI(`.github/workflows/ci.yml`):`swift test` + package iOS 編譯、app 編譯(零 warning)、可攜核心用 Swift SDK for Android 交叉編譯(aarch64、x86_64,API 28)。

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
```

依賴方向:`App → Features → Core ← Demo ← App`。**Features 不 import Demo**:畫面只透過 `HostChannel` 拿資料，不知道背後是真主機、假主機或 Demo。

- **可攜核心**(PurrdrCore、PurrdrDemo,ADR-0006)只能 import Foundation 與 swift-nio／swift-nio-ssh／swift-crypto 系列。Apple 專屬的東西(SwiftUI、Security、StoreKit、SwiftData…)放 Features 或 app,以 protocol 從核心注入。`PortableCoreImportTests` 在 `swift test` 先擋;CI 的 Android job 是最終守門。新增可攜 module 時兩邊(測試的允許清單、CI 的 `--target`)都要更新。
- **主機通道**(`HostChannel`):`execute(command)` 回傳 `ExecSession`(stdout／stderr／exit 串流，可寫 stdin、送 EOF、關閉);`openPTY(PTYRequest)` 回傳 `PTYSession`。連線重用、逾時、「連線層失敗不重送」都封裝在實作內;`disconnect()` 關掉底層連線。
- **真 SSH**(`SSHHostChannel`,ADR-0003):swift-nio-ssh,Tailscale SSH 用 `none` 認證。沒有 host key pin 時**不登入**,丟 `SSHConnectionError.hostKeyUnverified(presented:)` 讓畫面請使用者確認;指紋不符丟 `hostKeyChanged`。主機設定與 pin 存 Keychain(`KeychainHostStore`,解鎖時、僅此裝置)。
- **herdr client**:每個請求開一個 `herdr remote-api-bridge`,stdin 寫一行請求、**不送 EOF**,讀到第一行回應後關閉通道(行為規格 §3.3)。錯誤 envelope → `HerdrError.herdr(code:message:)`,未知碼保留 herdr 原文。wire format(snake_case)只在 `HerdrClient.swift` 處理。
- **主機指令建構**(`HerdrCommand`):POSIX 指令前綴明確 PATH、引號用 `'"'"'`(行為規格 §3.2)。herdr 路徑與具名 session 由 `HerdrInstallation` 帶入(`--session <name>` 放在子指令前;`--version`、`update` 不帶)。Windows 的 `-EncodedCommand` 尚未實作。
- **DI**:只用 initializer 注入;畫面 model 由 composition root 建立後傳入。
- **Concurrency**:核心型別是 `Sendable` value type 或 actor;畫面 model 放在 main actor。

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
- **Demo 主機**(`DemoHost`,行為規格 F21):對真正 client 送出的**精確指令字串**回應，所以走的是正式程式路徑。App Review 與 UI 測試都靠它;Release 也會帶。目前內容：三個 Agent——`w1:p1` Claude Code done(workspace `ledger`)、`w2:p1` Claude Code blocked(`weather-app`)、`w3:p1` Codex working(`notes`);接受 `events.subscribe`(回 ack 後保持開著、不送事件);回顯的 PTY shell、不認得的指令 exit 127。範例內容自己寫，不沿用 herdrchat 的文字。Demo 演不出來的功能，先加 Demo 情境。
- **SSH 通道**的測試對 `tests/PurrdrCoreTests/Support/TestSSHServer.swift`(swift-nio-ssh server 角色，只接受 `none` 認證)跑，斷言連線數、收到的指令、PTY 請求。
- **真實主機整合測試**(`RealHostIntegrationTests`)以環境變數開啟、只跑唯讀指令:`PURRDR_REAL_HOST=user@host[:port]`(可加 `PURRDR_REAL_HOST_FINGERPRINT`、`PURRDR_REAL_HOST_SESSION`)經 Tailscale SSH;`PURRDR_LOCAL_HERDR=1` 讓本機的真 herdr 經測試用 SSH 伺服器跑。Tailscale SSH 不接受同一台機器連自己的 tailnet IP,要從另一台裝置跑。
- **UI 測試**一律用 `XCUIApplication.launchUITesting(flags:contentSize:)` 啟動(帶 `-uiTesting`,只用 Demo 主機、不連網路;主機存在記憶體，任何主機的通道也是 Demo 主機)。元素用 accessibility identifier 找(例：Agent 列是 `agent.row.<pane id>`)。
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
