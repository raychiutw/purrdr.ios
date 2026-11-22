# App Store 中繼資料(#36)

App Store Connect → App → App Store 頁(各語言)。字數以字元計，限制依 App Store Connect 的欄位上限;字數都以 Python `len()` 實際算過。

共通設定：

| 欄位 | 值 | 備註 |
|---|---|---|
| Bundle ID | `com.raychiu.purrdr` | |
| SKU | 建議 `purrdr-ios-20261116` | 建立後不能改 |
| 主要語言 | English (U.S.) | 開發語言是英文;另加繁體中文 |
| 主要類別 | 開發者工具(Developer Tools) | 與 Info.plist 的 `LSApplicationCategoryType = public.app-category.developer-tools` 一致 |
| 次要類別 | 生產力工具(Productivity) | |
| 隱私權政策網址 | `https://raychiutw.github.io/purrdr/privacy/` | 與 `PurrdrLinks.privacyPolicy` 相同 |
| 支援網址 | `https://raychiutw.github.io/purrdr/support/` | 與 `PurrdrLinks.support` 相同 |
| 行銷網址(選填) | `https://raychiutw.github.io/purrdr/` | |
| 授權合約 | Apple 標準 EULA | 與 `PurrdrLinks.termsOfUse` 一致;描述最後也放連結(自動續訂訂閱的要求) |
| 版權 | `2026 <要顯示的名稱>` | 由人工決定 |
| 供應地區 | 147 個地區：**排除歐盟 27 國與中國大陸**(2026-11-16 已在 App Store Connect 設定) | 歐盟：數位服務法(DSA)要求公開貿易商(trader)身分與聯絡資料，個人開發者暫不申報;中國大陸：上架需 ICP 備案(工信部)。之後要開放時重新評估 |

關鍵字不重複名稱與副標已有的字(Apple 會一起索引):agent、chat、coding、SSH。
**不放其他公司的商標**(審查規範 2.3.7):關鍵字不用 Claude、Codex、Tailscale;描述中以「相容」的方式提及。

---

## English (U.S.)

**Name**(18/30)

```
Purrdr: Agent Chat
```

**Subtitle**(28/30)

```
Steer coding agents over SSH
```

**Promotional Text**(148/170,之後可隨時改、不用送審)

```
Your coding agents, in your pocket. See which agents need you, answer their questions, and open a terminal — straight to your own computer over SSH.
```

**Keywords**(97/100)

```
herdr,terminal,ai,remote,developer,cli,prompt,shell,tmux,pane,workspace,llm,devtools,server,linux
```

**Description**

```
Purrdr lets you read, answer, and steer the coding agents that herdr runs on your computer — and open a terminal into it — from your iPhone or iPad.

SEE EVERY AGENT AT A GLANCE
One list for all your hosts and workspaces: which agents are working, which are done, and which are waiting for you.

ANSWER WITHOUT GOING BACK TO YOUR DESK
Reply to questions and permission prompts right in the chat. Send prompts, slash commands, ! shell commands, and photos. Follow subagents and long-running work as it happens.

A REAL TERMINAL WHEN YOU NEED ONE
Open a full terminal into any pane, or a login shell on the host.

YOUR COMPUTER, YOUR CONNECTION
Purrdr connects straight to your computer over Tailscale SSH or OpenSSH. Conversations, terminal sessions, and images never pass through our servers. SSH keys are created in your device’s Secure Enclave and never leave it. No account needed for chat and the terminal.

WORKS WITH YOUR SETUP
macOS and Linux hosts, plus Windows hosts over OpenSSH. Works with Claude Code, Codex, and other agents running in herdr 0.9.5 or later.

TRY IT FIRST
No host yet? The built-in Demo host has sample conversations, so you can try every screen before connecting your own computer.

PURRDR PLUS (OPTIONAL)
• A notification when an agent needs you
• Your host list synced across your iPhone and iPad
Monthly or yearly subscription, each with a 2-week free trial for new subscribers. Payment is charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period; manage or cancel them in Settings › Apple Account › Subscriptions.

Privacy Policy: https://raychiutw.github.io/purrdr/privacy/
Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

Purrdr is an independent app and is not affiliated with herdr, Anthropic, OpenAI, or Tailscale.
```

---

## 繁體中文

**名稱**(18/30)

```
Purrdr: Agent Chat
```

**副標題**(21/30)

```
隨身回覆電腦上的 coding agent
```

**推廣文字**(93/170)

```
把電腦上的 coding agent 帶在身上：一眼看出哪個 Agent 在等你，直接回答提問、送 prompt,或開終端機進電腦。經 SSH 直連你自己的電腦，對話不經過我們的伺服器。
```

**關鍵字**(67/100)

```
herdr,終端機,AI,遠端,開發者,程式設計,指令,提示詞,伺服器,推播,工作區,命令列,shell,linux,mac,開發工具
```

**描述**

```
Purrdr 讓你在 iPhone 與 iPad 上，看、回覆、操作電腦上由 herdr 管理的 coding agent,也能直接開終端機進那台電腦。

所有 Agent 一目瞭然
所有主機與 workspace 一個列表：哪個 Agent 在工作、哪個做完了、哪個在等你。

不用回到電腦前也能回答
在聊天裡直接回答 Agent 的提問與權限確認。送 prompt、slash 指令、! shell 指令與照片;subagent 與長時間的工作也能即時追蹤。

需要時就有真正的終端機
任何 Pane 都能開完整的終端機，也能開主機的登入 shell。

你的電腦、你的連線
Purrdr 經 Tailscale SSH 或 OpenSSH 直接連到你的電腦。對話、終端機與圖片都不經過我們的伺服器。SSH 金鑰在裝置的 Secure Enclave 產生，永不離開裝置。聊天與終端機不需要帳號。

配合你現有的環境
支援 macOS 與 Linux 主機，以及經 OpenSSH 連線的 Windows 主機。相容在 herdr 0.9.5 以上執行的 Claude Code、Codex 等 Agent。

先試再說
還沒有主機?內建的 Demo 主機有範例對話，接上自己的電腦前就能試遍每個畫面。

Purrdr Plus(選用)
• Agent 需要你時推播通知
• 在 iPhone 與 iPad 之間同步主機清單
月繳或年繳，新訂閱者各有 2 週免費試用。費用由你的 Apple 帳號支付;除非在目前期間結束前至少 24 小時取消，訂閱會自動續訂。可在「設定 › Apple 帳號 › 訂閱」管理或取消。

隱私權政策:https://raychiutw.github.io/purrdr/privacy/
使用條款:https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

Purrdr 是獨立開發的 App,與 herdr、Anthropic、OpenAI、Tailscale 沒有關係。
```

---

## 截圖

截圖在模擬器以 Demo 主機手動拍(#374 起 UI 測試不再拍截圖),建議 11 張(檔名數字是建議順序):
列表與 workspace 卡片、需要你、subagent、slash 選單、`/model`、`/effort`、`!` 指令、終端機、多主機(一台連不上)、推播設定、歡迎頁。
App Store 需要 6.9 吋 iPhone 與 13 吋 iPad 各一組(其他尺寸可由這兩組縮放),要以對應的模擬器各跑一次。

## 審查用的訂閱截圖

每個訂閱商品送審時要附一張付費牆截圖(App Store Connect → 訂閱 → 審查資訊)。用 `PlusUITests` 打開的付費牆即可(UI 測試的替身商品與正式商品的名稱、價格、試用相同)。
