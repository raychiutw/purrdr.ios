# App 審查備註(#36)

App Store Connect → 版本 → App 審查資訊 →「備註」(上限 4,000 字元)。下方英文段落直接貼上;中文是對照與依據。

**每次送審前核對**:內容必須和送審 build 的 Demo 一致(#36 驗收條件)。Demo 改了(`src/PurrdrDemo/`、`AGENTS.md`「Demo 主機」一節),這份要一起改;
最快的核對方式是跑 `scripts/screenshots.sh`,看 11 張截圖是否仍對得上下面每一項。

「登入資訊」:**不需要示範帳號**(勾「不需要登入」)。聊天與終端機不需要帳號;Purrdr Plus 的會員用 Sign in with Apple 自行建立。

## 貼到 App Store Connect 的備註(English)

```
Purrdr is a client for herdr, an open-source tool that runs AI coding agents (such as Claude Code and Codex) on the user's own computer. The app connects directly to that computer over SSH (Tailscale SSH or OpenSSH) to read agent conversations, answer agent questions, and open a terminal. It needs the user's own computer running herdr, so we built a Demo host into the app for review. The Demo host is simulated entirely inside the app: it connects to nothing, and the same Demo ships in the release build.

HOW TO OPEN THE DEMO
On first launch a Welcome screen appears. Tap "Try the Demo". (If you dismissed it: ⋯ > Settings > Show Welcome, or pick "Demo" in the host menu at the top of the list.) With no hosts added, the Demo host is selected automatically.

WHAT YOU CAN TRY ON THE DEMO HOST
1. Agent list: three workspaces. "weather-app" (Claude Code) needs you, "notes" (Codex) is working, "ledger" (Claude Code) is done.
2. Needs you: open "weather-app". The agent asks to run a command ("Do you want to proceed?"). Tap an answer; the agent becomes done.
3. Chat: open "ledger" and send any message; the agent replies that this is the Demo host. Scroll up to see a finished subagent card ("Check how the widget refreshes").
4. Questions: in "ledger", send "ask me" to get two multiple-choice questions, or "trust" for a folder trust prompt.
5. Slash commands: in "ledger", type "/" to see the command menu. "/model" opens a model picker and "/effort" an effort slider, shown as cards.
6. Shell commands: in "ledger", send "!git status"; the chat shows the command and a sample output block.
7. Live work: open "notes" to see the Codex agent writing in real time; stopping it (Esc) makes it done.
8. Terminal: in a chat, tap the terminal button to open a terminal (an echo shell, prompt "demo@purrdr"). ⋯ > Login Shell and ⋯ > Files also work on the Demo host.
Things the Demo host cannot do, by design: start new chats or create workspaces (it shows "The Demo host can't start new chats. Add your own host to try this."), and send notifications.

WHY A REAL HOST IS NEEDED
Everything except the Demo talks to the user's own computer over SSH; there is no Purrdr server in that path. Conversations and terminal sessions never pass through our servers, so we cannot provide a shared test computer.

PURRDR PLUS (AUTO-RENEWABLE SUBSCRIPTION)
Purrdr Plus adds notifications when an agent needs you and host-list sync between devices. Chat, the terminal, and the Demo are free and never require an account or subscription.
To test: ⋯ > Purrdr Plus. Tap "Sign In to Subscribe" and use Sign in with Apple (Google sign-in is also offered) with your sandbox Apple Account; a member account is created on the spot. Then choose Monthly (US$4.99) or Yearly (US$39.99), each with a 2-week free trial. "Restore Purchases" and "Redeem Code" are on the same screen. Terms of Use (Apple standard EULA) and the Privacy Policy are linked at the bottom of the paywall.
After subscribing, the subscription status appears on the Purrdr Plus and ⋯ > Member screens. The notification toggle (⋯ > Settings) needs a real host, because it installs a small plugin on that computer; on the Demo host it explains "Choose your own host first. The demo host can't send notifications."
Account deletion: ⋯ > Member > Delete Member…

Contact: REPLACE_ME@example.com
```

## 中文對照與依據

| 備註內容 | 依據(送審前逐項確認) |
|---|---|
| 第一次開啟出現歡迎頁，有「Try the Demo」 | `WelcomeView`(`welcome.demo`)、`TopNavigationModel.launched(welcome:)`;UI 測試 `WelcomeUITests` |
| 設定頁「Show Welcome」可再看 | `SettingsView`(`settings.welcome`) |
| 沒有主機時自動選 Demo | `HostsModel.validSelection`(沒有已存主機回 `.demo`)、`rebuildMembers` |
| 三個 workspace:weather-app 需要你、notes 工作中(Codex)、ledger 完成 | `AGENTS.md`「Demo 主機」;`src/PurrdrDemo/DemoAnswers.swift` 開頭說明;截圖 01 |
| weather-app 的 Bash 權限提示「Do you want to proceed?」,回答後完成 | `DemoAnswers`(`w2:p1` `.bashPermission`);截圖 02 |
| 送任何訊息會收到「這是 Demo 主機」的固定回覆 | `DemoTranscripts.reply(to:number:at:)` |
| subagent 卡「Check how the widget refreshes」 | `DemoTranscripts`(`subagentMeta`);截圖 03 |
| 「ask me」兩題、「trust」資料夾信任 | `DemoAnswers.receivedPrompt` |
| `/` 選單、`/model`、`/effort` 卡片 | `DemoSlash`、`DemoAnswers`;截圖 04–06 |
| `!git status` 顯示 shell 區塊 | `DemoTranscripts.reply`(`!` 開頭);截圖 07 |
| notes 即時預覽，Esc 停止後完成 | `DemoAnswers`(`w3:p1`);`AGENTS.md` |
| 終端機(回顯 shell、`demo@purrdr`)、Login Shell、Files | 截圖 08;`DemoFolders` |
| Demo 不能開新聊天／建 workspace、不能推播 | `NewChatModel`(「The Demo host can’t start new chats…」)、`DemoHost.unsupportedMessage`、`PushSettingsSection`(`.demoHost`) |
| 訂閱要先登入;Sign in with Apple 與 Google | `PlusView`(`Sign In to Subscribe`)、`MemberView` |
| 價格、試用 | `src/App/Purrdr.storekit`、`subscriptions.md`(`StoreKitConfigurationTests` 檢查) |
| 付費牆底部有使用條款與隱私權政策 | `PlusView`(`plus.terms`、`plus.privacy`),`PurrdrLinks` |
| 刪除會員 | `MemberView`(`Delete Member…`) |

## 送審前的前提(否則審查會卡在登入或訂閱)

- 後台已部署，`BackendConfiguration.baseURL`、Google client ID 已換成真值(`backend/README.md`「上線前要填的東西」)。否則 Sign in with Apple 會顯示連線錯誤，審查員無法測訂閱。
- 兩個訂閱商品已「準備提交」並跟這個版本一起送;「付費 App」合約生效。
- App Store Server Notifications 的 Sandbox 網址已填(審查員在 Sandbox 購買)。
- 隱私權政策與支援頁已發佈到 `https://raychiutw.github.io/purrdr/`,聯絡信箱已換掉 `REPLACE_ME@example.com`(備註最後一行也要換)。
- 選填：附一段真實主機的錄影(推播、主機同步),放在「附件」;審查員無法自己架主機時有助於理解推播。
