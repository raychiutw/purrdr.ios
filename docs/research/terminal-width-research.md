# Pane 終端機：不改電腦寬度、手機自然折行的可行性(研究)

日期 2026-11-22。唯讀研究：沒有對任何 pane 送按鍵、resize 或指令;只跑了 `herdr --help`、`herdr api schema --json`、`herdr pane list/get/layout`、`herdr pane read`(唯讀)。
標記:【實測】本機唯讀輸出;【文件】herdr 官方文件 v0.9.5;【fixture】`docs/research/fixtures/session-control/` 的真主機錄製;【程式】integ 工作樹 `caef5ba8`;【推論】未驗證。

## TL;DR

- herdr 一個 Pane 只有**一個 PTY 尺寸**。能改它的只有 controller(handshake 的 `--cols/--rows` 與 `terminal.resize`)與 direct attach。**沒有「每個 client 各自尺寸」**。observer 不改 PTY,但它拿到的是「把 Pane 的格子畫進自己的 viewport」,不是重新排版。
- frame 是 **herdr 畫好的格子**(絕對座標 `ESC[r;cH` 加上每列補滿空白),不是程式的原始輸出。裡面沒有軟換行標記，也不轉送 alternate screen、滑鼠模式等狀態，所以**手機端不能對 frame 重新折行，也看不出程式是否在 alternate screen**。
- 「邏輯行」只有 `pane.read` 的 `recent_unwrapped` 有(可帶 ANSI 顏色)。但它只會接回**終端機的軟換行**。Claude Code 依 PTY 寬度**自己硬換行**、自己畫整寬分隔線，所以接回後還是電腦寬度的硬折行。
- 結論：**全螢幕 TUI(Claude Code、Codex、vim)不改 PTY 寬度，就不可能在手機上「自然折行」**。這是 TUI 的本質，不是 herdr 少了某個 API。可行的是：終端機以電腦尺寸顯示(整寬縮放＋捏合)保留操作，閱讀交給聊天畫面;一般 shell／log 另外提供以 `recent_unwrapped` 在手機寬度重新排版的「文字檢視」。

## 1. herdr 能做什麼

| 問題 | 答案 | 證據 |
|---|---|---|
| 同一 Pane 多個 client 各自尺寸 | **不行**。PTY 只有一個;一次只有一個 controller 擁有輸入與 resize | 【文件】persistence-remote.mdx:「Only one controller owns input and resize at a time」;cli-reference:「Only one writable direct attach client owns input and resize」 |
| controller 不送 resize 就不改尺寸? | **不是**。handshake 的 `--cols/--rows` 一接上就套到 PTY(預設 120×40);接上期間鎖在 controller 的尺寸，離開才恢復 | 【fixture／研究】`terminal-session-control-macos.md`:「`--cols/--rows` 在 handshake 時就套用到 pane 的 PTY(`stty size` 回 `24 80`)」、release／SIGKILL 後恢復;【程式】`TerminalSizeMode.keepDesktop` 的註解記了同樣結論，所以 handshake 帶 Pane 原尺寸 |
| observer(只看，不改 PTY) | **有**:`herdr terminal session observe <target> --cols N --rows N`,數量不限，不取得輸入、resize、捲動與接管權 | 【文件】「Multiple observers can watch the same terminal without taking input, resize, scroll, or takeover ownership」;【實測 help】只有 `--cols/--rows`;Purrdr 的唯讀裝置已在用(ADR-0010) |
| observer 的尺寸語意 | 自己的 cols/rows 只決定**自己的** render viewport。CLI 不讀 stdin,尺寸在啟動時固定，要換尺寸只能重開 | 【fixture】`06-takeover-observer`:Pane 40×12,observer 收到 `width:30,height:8` 的 frame,每列補到 30 格;【研究】behavior-spec §6.6 |
| Pane 比 observer 寬時 | 【未確認】fixture 的內容比 30 格短，看不出是裁切還是其他處理。依「畫進自己的 viewport」與絕對座標格子推測是**裁切**(右側與部分列看不到),**不會重新折行** | 要實測(見 §4) |
| frame 是格子還是原始位元組 | **畫好的格子**:`ESC[?2026h … ESC[2J ESC[1;1H <整列補空白> ESC[2;1H …`,增量 frame 也是逐格定位 | 【fixture】解碼 `06-takeover-A`、`06-takeover-observer` |
| frame 帶不帶程式的終端機模式 | **不帶**。vim、less、一般 shell 的全部 frame 只出現 `?2026h/l`(同步輸出)與 `?25h/l`(游標),**沒有 `?1049h`(alternate screen)、`?1000h`(滑鼠)** | 【fixture】統計 `04-mouse-wheel-vim`、`05-alternate-scroll-less`、`03-scroll-host-scrollback` 的 `ESC[?…h/l` |
| 能不能取得邏輯行 | `pane.read` 的 `source`:`visible`、`recent`(含終端機換行)、`recent_unwrapped`(「without soft wrapping. Best for logs」)、`detection`;`format` 可用 `text`/`ansi`,回應帶 `revision`、`truncated` | 【實測 schema】`PaneReadParams`、`PaneReadResult`;【文件】cli-reference |
| 有沒有輸出串流的文字事件 | 沒有。只有 `pane.output_matched`(wait-output)、`pane.scroll_changed`;要用 `pane.read` 就只能輪詢(請求也沒有「從某個 revision 起」的參數) | 【實測 schema】 |
| 偵測 alternate screen 的 API | 沒有。schema 只有 `screen_detection_skipped` 這類 agent 偵測欄位 | 【實測 schema】搜尋 alt／screen／mode |
| Pane 尺寸從哪裡讀 | `pane.layout` 的 `rect`(實測 w1:pC 是 164×33);`pane.list/get` 的 `scroll.viewport_rows` | 【實測】 |

### 用真實 Claude Code pane 實測 `recent_unwrapped`(唯讀)

- w1:pC(Claude Code,164×33):`recent --lines 1000` 是 156 行，`recent-unwrapped --lines 1000` 也是 156 行;`--lines 20` 時是 20 對 19 行。**幾乎沒有軟換行可以接回**。
- 最寬一行的顯示寬度是 164,長路徑與長句都被 Claude Code 自己斷成好幾行並縮排兩格(例：「錯誤訊息寫的是「no dyld」換行接「  cache」…」)。
- `--format ansi` 可用，保留 24-bit 顏色;分隔線是 164 個 `─` 的單一行，在手機寬度重新排版會折成三行。

## 2. 「手機自然折行」的做法比較

### (a) 手機端對 herdr 的 frame 重新折行(reflow)
- **一般 shell／log**:做不到。frame 是絕對定位的格子，每列補滿空白、沒有 wrap 旗標。SwiftTerm 收到的每一列都像是一列「定位後寫滿」的內容，它的 reflow 也接不回來【推論，依 frame 格式】。
- **全螢幕 TUI**:做不到也不該做。版面(方框、狀態列、選單、游標位置)是程式依 PTY 寬度畫的，重新折行只會打散。
- **偵測 alternate screen 再分流**:frame 不帶模式，無法偵測(見上表)。唯一能用的判別是 snapshot 的 `agent` 欄位(claude／codex = TUI)【推論】。
- 判定：**不可行**。

### (b) 只看模式顯示＋換成文字檢視，輸入另外走 `send_text`
- observe(或 control 以 Pane 原尺寸 handshake、從不 resize)看 frame,電腦尺寸整寬縮放。另提供「文字」分頁：輪詢 `pane.read recent_unwrapped`(ansi)後，在 UITextView 以手機寬度自然折行。
- 一般 shell／log:效果好，軟換行都能接回。
- Claude Code／Codex:可讀性有限。程式自己的硬折行(164 格)在手機上變成每行斷在奇怪的位置，分隔線與方框也會折開。可以用啟發式改善(去掉整列框線字元、把縮排相同的續行接回),但很脆弱【推論】。
- 輸入：`pane.send_text`/`pane.send_keys`(`HerdrOperation` 已支援，HTTPS 也有)不需要擁有權。缺點是 observe 不讀 stdin,沒有 `terminal.scroll`/`terminal.mouse`;捲動只能用 API 的 `pane.scroll`,而它改的是電腦上那個 Pane 共用的捲動位置【推論：herdr 的 scroll offset 是每個 Pane 一份】。
- 頻寬：每次輪詢都是整段文字(156 行約 10 KB 量級),沒有增量。

### (c) 只用 `pane.read` 純文字，在 app 內折行
- 等於 (b) 拿掉 frame 的部分。對 shell 可行，對 TUI 的可讀性問題相同，而且看不到游標與選單的即時狀態，不能操作 TUI。

### (d) 目前 #357 的做法(control,handshake 帶 Pane 原尺寸，不送 resize,整寬縮放＋捏合平移)
- 不改電腦版面【程式；要實測確認】,TUI 版面完整、可以操作。但字小，不是「自然折行」。
- 風險：control 接上期間 PTY 鎖在 handshake 尺寸。電腦端這時調整視窗或分割，**可能改不動 Pane 的 PTY**,電腦版面會被手機卡住【推論，依「attach 期間鎖在 controller 尺寸」;要實測】。
- 改用 observe 可以避開這個風險(電腦照常調整，手機重開 observer 以新尺寸顯示),代價是輸入改走 API、沒有 mouse/scroll。

## 3. Claude Code／Codex 這類 TUI

- 硬限制:TUI 依 PTY 寬度排版、自己硬折行。**手機想要「自然折行」就得讓 PTY 等於手機寬度，而這就是改電腦版面**。herdr 每個 Pane 只有一個 PTY,沒有 per-client viewport。兩者不能同時成立。
- Purrdr 的分工本來就是：**閱讀在聊天畫面**(對話紀錄已在手機寬度自然排版，含工具卡片、檔案與圖片),送 prompt 走 `agent.prompt`,「需要你」、`/model`、`/effort` 已經做成原生卡片或 sheet。
- 所以終端機在 agent pane 的角色是**例外處理的遙控器**:看 TUI 當下畫面(選單、權限提示、進度)、按 Esc／ctrl-c／方向鍵／Enter、少量打字。這些操作只需要看得到版面、按得到鍵，不需要折行。
- 最實際的方案：電腦尺寸整寬縮放＋捏合放大到游標或選單附近(#357 已做的 `TerminalViewportZoom`),按鍵列照舊;iPad 通常不用縮放。手機直向 164 格整寬約 2.3 pt/格，只能看輪廓，要放大才讀得到字。這是不改寬度的必然代價。橫向會好一些。
- 純 shell pane(沒有 agent):提供「文字檢視」(`recent_unwrapped` 在手機寬度排版)對閱讀 log 最有幫助。

## 4. 結論

### 推薦
1. **預設保留電腦版面，不提供切換**(符合「不要切換設定」):Pane 終端機一律以電腦 Pane 的尺寸顯示，整寬縮放、捏合放大與平移、雙點兩下切換，鍵盤出現時捲到游標。
2. **傳輸二選一，看實測結果**:
   - 若實測「control 期間電腦調整 Pane 大小會被卡住」→ 改用 **observe**(以 `pane.layout` 的 rect 為 cols/rows;Pane 尺寸改變時(`pane.updated`／layout 事件，或 frame 的寬高對不上 rect)重開),輸入走 `pane.send_text`/`send_keys`,捲動用 `pane.scroll`。要處理 observe 在 Windows 沒有寫入逾時、會殘留程序的問題(主機服務端已有子行程管理;SSH 要另外清理)。
   - 若電腦端仍能自由調整(herdr 會跟著改)→ 保留目前 control＋原尺寸 handshake(mouse、scroll 都還能用)。
3. **一般 shell pane 加「文字」檢視**:輪詢 `pane.read recent_unwrapped`(ansi)後在手機寬度自然折行，只讀;輸入仍在終端機檢視。agent pane 不提供(或標示為實驗性),引導到聊天畫面。

### 做不到(明講)
- 全螢幕 TUI(Claude Code、Codex、vim、less)在不改 PTY 寬度的前提下，**不可能**在手機上依手機寬度自然折行。
- 手機端無法對 herdr 的 frame 重新折行，也無法從 frame 判斷 alternate screen 或滑鼠模式。
- herdr 0.9.5 沒有 per-client 尺寸，也沒有 pane 文字的增量串流。要的話得向 herdr 提出(#357 的 Out of Scope 已寫)。

### 需要在真主機實測(只列步驟)
1. **observer 比 Pane 窄或矮時的畫面**:在測試用 workspace 開一個 shell pane(例如 100×30),印出超過 40 格的長行與 50 行輸出;`herdr terminal session observe <pane> --cols 40 --rows 12` 看 frame 是裁切(哪一邊、顯示上方還是下方的列)、縮小還是折行。
2. **control 期間電腦調整 Pane**:control 以 Pane 原尺寸 handshake、不送 resize;在電腦上改視窗大小或分割，觀察 `pane.layout` rect、`stty size` 與電腦畫面是否跟著改;release 後是否恢復。
3. **observe 期間電腦調整 Pane**:同上，只是換成 observe,確認 PTY 跟著電腦改、observer 的 frame 仍是啟動時的尺寸(要重開)。
4. **observe＋`pane.send_text`/`send_keys`**:在 observe 期間從 API 送字，確認不需要擁有權、不被拒;另一台裝置以 control 接上時是否也能送。
5. **`pane.scroll` 的共用性**:從 API 捲動，確認電腦上那個 Pane 是否跟著捲(預期會)。
6. **shell 的 `recent_unwrapped`**:在 shell pane 印一行超過 Pane 寬度的長字串，比較 `recent` 與 `recent_unwrapped` 是否接回成一行。
7. **Codex pane**:同樣比較 `recent` 與 `recent_unwrapped`,並看 Codex 是否用 alternate screen(`herdr pane get` 的 `scroll.max_offset_from_bottom` 是否一直是 0)。
8. Windows 主機重複 1、3、4,並確認 observe 在 SSH 斷線後的殘留處理。

### #357 規格要怎麼改
- **拿掉「大小」選單膠囊與「配合這支手機」模式**(使用者不要切換;配合模式就是改電腦版面)。User Stories 9–11、15 刪除;Implementation Decisions 的「大小模式」、模式偏好(`TerminalSizeSettings`)、入口膠囊一併移除。登入 Shell 照舊配合手機。
- **保留「整寬縮放」**(Stories 4–8、12、16)作為唯一行為;捏合在 Pane 終端機一律是縮放畫面，不改欄數。
- **加入傳輸的實測分支**(上面第 2、3 項):依結果決定 control＋原尺寸 handshake 或 observe＋API 輸入。若選 observe,`isViewOnly` 的語意要從「唯讀裝置」拆成「不能輸入」與「用 observe 傳輸」兩個概念。
- **新增一則 Story**:一般 shell pane 可以切到「文字」檢視，在手機寬度自然折行閱讀(只讀)。agent pane 的閱讀導向聊天畫面。
- Out of Scope 明寫:TUI 在手機寬度自然折行(需要改 PTY 寬度，與「不影響電腦」互斥)。

## 附：integ 分支(`caef5ba8`)已有的 #357 實作
- `src/PurrdrAgentFeatures/TerminalSizeMode.swift`:`keepDesktop`(handshake 帶 Pane 原尺寸、不送 resize)／`fitPhone`,偏好 key `terminal.sizeMode`。
- `src/PurrdrAgentFeatures/PaneTerminalModel.swift`:`nativeSize`(從 snapshot 取 `PaneNativeSize`)、`keepDesktopFallback`、切回 keepDesktop 時送一次 resize 回原尺寸。
- `src/PurrdrFeatures/TerminalViewportZoom.swift`、`PaneTerminalView.swift`:整寬縮放、捏合、平移、雙點兩下、鍵盤時捲到游標(`revealing(caret:)`)。
- 依本研究，要改的是移除 `fitPhone` 與膠囊;縮放部分可以沿用。
