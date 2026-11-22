# 競品怎麼處理 Pane 終端機的寬度:herdrchat、Heeler 與 Purrdr 建議案

日期 2026-11-22。只做研究，沒有改程式，也沒有對任何 pane 送按鍵或 resize。
前一份研究:`terminal-width-research.md`(同在 docs/research)。

**clean-room(ADR-0001)**:herdrchat 只用了專案內的行為規格(`git show origin/master:docs/research/herdrchat-behavior-spec.md`,以下簡稱「行為規格」)、官網、App Store 頁面與 GitHub Release 清單。**沒有讀** herdrchat 的 repo 檔案、README 或原始碼。Heeler 是開源專案，只讀了它的官網、docs 網站、App Store、README 與 `docs/` 底下的 ADR(設計文件)。它的 Swift 原始碼一行都沒讀。

標記:【規格】行為規格;【官方】產品官網、App Store 或 docs;【ADR】Heeler 公開的設計紀錄;【未證實】推論。

## TL;DR

- **herdrchat 和 Heeler(連 Herdr TUI 時)都讓手機的寬度變成 Pane 的 PTY 寬度。** 開著終端機時，電腦上那個 Pane 會用手機的尺寸重畫，離開後恢復。兩者都沒有「整寬縮放」，也沒有文字模式。捏合改的是字級，所以欄數跟著變，又會再送一次 resize。
- 兩者都靠**縮短持有尺寸的時間**來降低對電腦的影響。herdrchat 一進背景就掛斷，回來也不自動重連。Heeler 只在畫面真的顯示時持有尺寸，離開就還回去。
- Heeler 在自己的 Rex 後端試過「不改尺寸、照別台的寬度在手機上重新折行」。它的 ADR 說游標位置會錯，放大縮小也做不到，最後改成「顯示就調成手機尺寸」。這和 Purrdr 前一份研究「不能重新折行」的結論相符。
- 官方 Herdr app(herdr-core 用，不支援 Herdr TUI)的宣傳寫「從手機觀看不會改電腦上任何東西的大小」。這只是觀看，打字的部分沒有說明。
- **Purrdr 建議案(保留電腦寬度＋整寬縮放＋捏合，一般 shell 加只讀文字檢視)在三者中最符合「不影響電腦」。** 代價是 TUI 的字很小。

## 1. herdrchat

| 面向 | 行為 | 出處 |
|---|---|---|
| 傳輸 | Agent pane 用 `herdr agent attach <pane_id>`,shell pane 用 `herdr terminal attach <terminal_id>`(direct attach,開在 PTY 上)。沒有用 `terminal session control`／`observe` | 【規格】§6.1、§6.6「herdrchat 未使用」 |
| 會不會改電腦 Pane 的尺寸 | **會**。「唯一共享的是 pane 尺寸(attach 期間 pane 以此 client 的尺寸繪製,detach 時恢復)」 | 【規格】§6.1 |
| 尺寸怎麼決定 | 終端機視圖先依字型與邊界算出 cols/rows,通道綁好時立刻送出。之後尺寸一變(鍵盤、旋轉)就去抖 250ms 再以 `window-change` 送給主機。理由寫明「每次 resize 也會重繪桌機的 pane」 | 【規格】§6.4「尺寸」、R-T05 |
| 縮放 | **沒有整寬縮放**。捏合改的是字級(預設 13pt,8～28pt),只存在記憶體。字級變了欄數也變，所以 Pane 跟著被 resize(【未證實】:依「cols/rows 由字型算出」加上「尺寸變化就送」推得) | 【規格】§6.4「字型」 |
| 折行 | 程式依手機寬度自己排版(PTY 本來就是手機寬度),所以看起來是「手機寬度」。app 沒有另外重新折行 | 【規格】§6.4 推論 |
| 切換／文字模式 | 都沒有。閱讀用聊天畫面(讀對話紀錄檔):「Less terminal. More conversation」「reads each agent's own transcript files … instead of scraping the terminal」 | 【官方】https://herdrchat.cobanov.dev ;【規格】§6 沒有文字模式 |
| 降低對電腦的影響 | 進背景**立刻掛斷、回前景不自動重連**,理由「不能讓桌機 pane 一直是手機尺寸」(commit fc77291)。離開畫面也掛斷。不用 zoom 加 session attach,因為那會改到桌機的 zoom、focus 與側欄 | 【規格】§6.5、§6.1、R-T03、R-T05 |
| 接管 | 只有使用者按「接管」才帶 `--takeover`。桌機的 herdr TUI client 不算 attached client,所以平常不必接管就能開 | 【規格】§6.3 |
| TUI | 程式持有滑鼠時，垂直滑動送滾輪事件;拖曳手勢移除 | 【規格】§6.4「手勢」 |
| iPad | 直立的 iPad 要放得下 80 欄，所以字級上限 28pt。開好後終端機自動取得焦點。分割裝置上終端機在詳細欄 | 【規格】§6.4、F20、R-T09 |
| 公開資料 | 官網、FAQ、App Store 說明與版本紀錄(0.7.9～0.15.0)都沒提終端機尺寸。GitHub Release 只有兩則，也沒提 | 【官方】https://herdrchat.cobanov.dev 、https://apps.apple.com/app/herdrchat/id6791874615 、`gh api repos/cobanov/herdrchat/releases` |

## 2. Heeler

Heeler 是誰做的：開源的 iPhone／iPad app(ZingerLittleBee),後端支援 Herdr TUI、herdr-core(Herdr 桌面 app)、tmux 和實驗中的 Rex,透過 SSH 連線，終端機用 libghostty 畫。
出處:https://heeler.bybee.dev 、https://github.com/ZingerLittleBee/Heeler (README)、https://apps.apple.com/app/id6797263135 、https://www.producthunt.com/products/heeler-2

| 面向 | 行為 | 出處 |
|---|---|---|
| Herdr TUI 的傳輸 | 「herdr's JSON API over stream-local forwarding … with terminals on an SSH PTY」。Shell Terminal 是 `herdr terminal attach <terminal_id> --takeover`(只用在自己剛建立的 tab)。Agent 用 `agent attach`。Windows 走 `terminal session control`(「resize, and release」) | 【官方】README「How it connects」;【ADR】0015、0018 |
| 會不會改電腦 Pane 的尺寸 | **會**。ADR 0013:「Terminal size changes continue to resize the remote PTY, including changes caused by the Composer and software keyboard」。ADR 0053:「Other Server Kinds size their terminals to the view」(除了 Rex,其他後端都依畫面調整尺寸) | 【ADR】0013、0053 |
| 為了不一直 resize 做的事 | Agent 畫面的 Composer(原生輸入框)在鍵盤收起時也維持全高，切換輸入方式時「Neither mode … asks Ghostty to resize its grid」。目的是不讓電腦上的 Pane 跟著鍵盤跳動 | 【ADR】0013 |
| 縮放 | 捏合與 ⌘+/⌘- 改 app 全域的**字級**(會保存),「lets Ghostty's cell-size callback resize the remote PTY as usual」。也就是說縮放也會改 Pane 尺寸。沒有整寬縮放 | 【ADR】0004 |
| 折行 | Herdr TUI／tmux:PTY 就是手機寬度，所以程式依手機寬度排版。Rex 不持有尺寸時:「lines wrap at its width, a line wider than the view wraps again at the view's」。但游標落在伺服器的列與欄，會疊在折過的字上 | 【ADR】0053 |
| 「縮成整寬」 | **明確不做**:「No scaled view. Heeler does not scale the other device's grid down to the screen … needs a terminal view whose grid the remote side fixes, which no Attach has」 | 【ADR】0053、0045 |
| 切換 | Rex 原本要按「Fit to Screen」才調尺寸。維護者覺得每次都要按很煩，改成「Shown means fitted」(顯示就調成手機尺寸，不用按)。按鈕留作備用，有「Sized for another device」提示。其他後端沒有這個提示 | 【ADR】0053 |
| 還回尺寸 | Rex:畫面離開或場景進背景就還。tmux:「Leaving the Pane hands window sizing back to your other clients」,並以桌機 client 的視窗大小為上限(「stays within an open desktop terminal on the same window」),不會把桌機撐大 | 【ADR】0053;【官方】https://docs.heeler.bybee.dev/tmux 、ADR 0045 |
| 文字模式 | 聊天畫面讀對話紀錄(「read its conversation as Chat」);tmux 文件寫明用 Chat 讀與送「without resizing your tmux window」。iPad 截圖說明 Shell Terminal 有「Text and Keys modes」,看起來是輸入方式(Composer 或直接打字)而不是文字檢視【未證實】 | 【官方】App Store 說明、docs/tmux、README 的 iPad 截圖頁 |
| TUI | 終端機是 Agent 輸出的權威呈現(「The Agent TUI is the authoritative presentation」)。觸控捲動在 alternate screen 送滾輪事件。預設輸入是原生 Composer,Direct Input(直接打字)要自己打開 | 【ADR】0013、0016 |
| 接管 | herdr-core／tmux:「any viewer can type without a Take Over step」。Herdr TUI 的 shell 用 `--takeover`,但只對自己剛建立的 tab,不搶桌機的 attach | 【官方】docs/herdr-core、docs/tmux;【ADR】0015 |
| iPad | 側欄＋終端機並排、Stage Manager 多視窗、調整視窗大小時修正終端機(0.1.11、0.1.13)。一個終端機一次只在一個 scene 顯示(Rex)。沒有 iPad 專屬的寬度策略，同樣依視窗調尺寸【未證實：依「size their terminals to the view」推得】 | 【官方】App Store 版本紀錄;【ADR】0053 |

## 3. 參考：官方 Herdr app(herdr-core)

- 「Watching from the phone never resizes anything on your computer.」打字是「Type straight in, like on your laptop」,沒說打字時會不會改尺寸。
- 這個 app **不支援 Herdr TUI**(「Herdr TUI runs its own server, so agents started there don't show up on your phone」),所以不是 Purrdr 的直接參考。它只說明 herdr 官方認為「只看不改尺寸」是值得寫進宣傳的特性。
- 出處:【官方】https://herdr.dev/mobile

## 4. 比較

| | herdrchat | Heeler(Herdr TUI) | Purrdr 建議案 |
|---|---|---|---|
| 改電腦 Pane 的 PTY 尺寸 | 會(開著的期間) | 會(顯示的期間) | **不會**(control 帶原尺寸 handshake 或 observe) |
| 手機上 TUI 的可讀性 | 好(依手機寬度排版) | 好 | 差(整寬縮小，要捏合放大) |
| 捏合 | 改字級，也改 Pane 尺寸 | 改字級，也改 Pane 尺寸 | 只縮放畫面，不改欄數 |
| 整寬縮放 | 無 | 明確不做 | 有 |
| 文字模式 | 無(閱讀靠聊天) | 無(閱讀靠聊天) | 一般 shell 有只讀文字檢視;agent 靠聊天 |
| 降低對電腦的影響 | 背景即掛斷、不自動重連;resize 去抖 | 只在顯示時持有;鍵盤與 Composer 不觸發 resize;tmux 以桌機為上限 | 本來就不影響 |
| 切換 | 無 | Rex 有 Fit to Screen 提示;其他無 | 無 |
| iPad | 直立放得下 80 欄;依視窗 resize | 依視窗 resize | 通常寬度夠，縮放比例接近 1 |

兩家競品都接受「看終端機的期間電腦的 Pane 會變成手機大小」,把力氣花在縮短持有時間。使用者的要求是「不影響電腦」,這兩家都沒有做到，所以**沒有現成的競品做法可以照抄**。Heeler 的 Rex 經驗則是反證：不改尺寸又要手機寬度折行，畫面會壞(游標位置錯)。

## 5. 對 Purrdr 的建議

1. **維持前一份研究的建議案作為預設**:電腦寬度＋整寬縮放＋捏合放大，不改 PTY 尺寸。這是三者中唯一符合「不影響電腦」的做法。競品證明的是另一條路(改尺寸)可行，而不是建議案錯了。
2. **捏合只做畫面縮放，不改欄數**。兩家競品的捏合都會連帶 resize。Purrdr 刻意不這樣做，要在 UI 上讓使用者明白(例如放大後可以平移，不會重新排版)。
3. **閱讀繼續交給聊天**。三家都把「好讀」交給讀對話紀錄的聊天畫面，終端機只用來操作例外狀況(選單、權限提示、Esc／ctrl-c)。Purrdr 現有的分工和業界一致。
4. **一般 shell 的只讀文字檢視是 Purrdr 獨有的**。競品都沒有，可以做成差異點，但要先在真主機確認 `recent_unwrapped` 對 shell 真的能接回軟換行(前一份研究的實測第 6 項)。
5. **不建議**加「配合這支手機」的切換(像 Heeler Rex 的 Fit to Screen)。使用者已經說不要切換。Heeler 的經驗也顯示，提供切換後使用者每次都會按，維護者最後改成自動調整，又回到改電腦尺寸。如果將來真的要加，要照 Heeler 的規則：只在畫面顯示時持有、離開就還、不跟別台搶。
6. 前一份研究列出的實測(control 期間電腦調整 Pane 會不會被卡住、observe 比 Pane 窄時的畫面)仍然要做。競品都用 PTY attach 並跟著手機調整尺寸，所以沒有任何公開資料能回答這兩個問題。

## 出處清單

- 行為規格 §6.1、§6.3～§6.6、F12、F20、R-T03／R-T05／R-T09:`git show origin/master:docs/research/herdrchat-behavior-spec.md`
- herdrchat 官網:https://herdrchat.cobanov.dev
- herdrchat App Store:https://apps.apple.com/app/herdrchat/id6791874615
- Heeler 官網:https://heeler.bybee.dev ;docs:https://docs.heeler.bybee.dev/herdr-core 、https://docs.heeler.bybee.dev/tmux
- Heeler App Store:https://apps.apple.com/app/id6797263135
- Heeler README 與 iPad 截圖:https://github.com/ZingerLittleBee/Heeler 、https://github.com/ZingerLittleBee/Heeler/blob/main/docs/ipad-screenshots.md
- Heeler ADR:https://github.com/ZingerLittleBee/Heeler/tree/main/docs/adr (0004 libghostty-terminal、0013 live-terminal-with-local-composer、0015 shell-terminal-via-direct-terminal-attach、0016 direct-input-on-agent-attach、0018 native-windows-hosts、0045 tmux control mode、0053 rex-terminals-fit-the-view-that-shows-them)
- Heeler Product Hunt:https://www.producthunt.com/products/heeler-2
- 官方 Herdr app:https://herdr.dev/mobile
