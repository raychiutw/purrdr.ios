# Purrdr

在 iPhone 與 iPad 上，看、回覆、操作你電腦上由 [herdr](https://herdr.dev) 管理的 coding agent，也能直接開終端機進那台電腦。

Read, answer, and steer the coding agents herdr runs on your computer — from your iPhone or iPad.

## 主要功能

- 所有 Agent 一個列表:哪個在工作、哪個做完了、哪個在等你。
- 在聊天裡回答 Agent 的提問與權限確認，送 prompt、slash 指令與圖片。
- 需要時開一個完整的終端機。
- 直接連到你自己的電腦(Tailscale SSH、OpenSSH 或 HTTPS),對話不經過我們的伺服器。
- 還沒有主機?內建的 Demo 主機讓你先試每個畫面。
- Purrdr Plus(選用訂閱):Agent 需要你時推播通知，並在你的裝置之間同步主機清單。

## 安裝

需要 iOS 26 以上的 iPhone 或 iPad，電腦上要裝 herdr 0.9.5 以上。目前以 TestFlight 發行，App Store 上架準備中。

1. 在手機安裝 Purrdr。
2. 開啟 App，點「Add Host」，照畫面輸入電腦的位址並確認連線方式。
3. 連線方式二選一:
   - **SSH**(Tailscale SSH 或 OpenSSH):電腦要能 SSH 進去。
   - **HTTPS**:在電腦上安裝[主機服務](https://github.com/raychiutw/purrdr.host)，再用配對碼配對。

## 更多資訊

- [完整說明與支援](https://raychiutw.github.io/purrdr/)
- [版本說明](CHANGELOG.md)(每個版本改了什麼)，也可在 [Releases](https://github.com/raychiutw/purrdr.ios/releases) 查看
- [隱私權政策](https://raychiutw.github.io/purrdr/privacy/)
- 主機服務與主機外掛:[raychiutw/purrdr.host](https://github.com/raychiutw/purrdr.host)

## 開發

開發指令、架構、測試與發版流程在 [AGENTS.md](AGENTS.md)。

Purrdr 是獨立的 App，與 herdr、Anthropic、OpenAI、Tailscale 沒有隸屬關係。
