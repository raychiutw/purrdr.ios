# `herdr terminal session control` 在 macOS 的實測(#4)

> 目的:驗證 ADR-0005「Pane 終端機全平台統一走 `herdr terminal session control`」在 macOS 上是否可行，量測延遲與頻寬，記下各訊息的實際格式與邊界行為，並錄製 #20 要用的 NDJSON fixture。
>
> 標記:**【實測】** = 本次在本機實際執行觀察到;**【原始碼】** = 讀 herdr 0.9.5 原始碼確認(路徑相對於 herdr repo);**【推論】** = 根據前兩者推出、未直接驗證。

## 結論

**可行，維持 ADR-0005,不需要改回 PTY + attach。** 輸入、resize、捲動、滑鼠、接管、release、`terminal.closed` 都照文件運作;延遲是一個 render 週期(p50 約 18 ms);伺服器端會把輸出合併成「畫面差異」,所以頻寬取決於畫面變化，不取決於程式輸出量。

但 #20 實作時有幾件事要照著做，否則會踩雷(細節見下方「對 #20 的要求」):

1. 串流**不轉送任何終端機模式**(滑鼠回報、bracketed paste、DECCKM、alternate screen),也不轉送標題、BEL、OSC 52。App 端的模擬器只負責畫面;滑鼠、滾輪、貼上一律交給 herdr。
2. 單則輸入超過 1 MiB 會被**直接斷線**,而且**不送 `terminal.closed`**。輸入必須切塊。
3. 「stdout EOF 但沒收到 `terminal.closed`」要當成連線中斷處理;**exit code 一律是 0**,不能拿來判斷。
4. `terminal.scroll` 的 `lines` 只對 herdr 主機端 scrollback 有效;程式自己處理滾輪時(vim、less),**一則訊息只等於一格滾輪**。
5. 串流沒有 heartbeat,也不帶捲動位置。

## 測試環境與方法

| 項目 | 值 |
|---|---|
| 日期 | 2026-11-15 |
| 主機 | macOS(Darwin 27.2.0,arm64),herdr 0.9.5(正在執行的 server,同機另有使用者的 agent) |
| 測試對象 | 用 `herdr workspace create --no-focus` 自建的專用 workspace,只對它的 pane 操作；最後讓它 `exit` 結束，第二個測試 workspace 用 `herdr workspace close` 關掉。全程沒碰使用者的 pane,桌機焦點維持在原 workspace |
| pane 內程式 | 先送 `exec env -i HOME=/tmp TERM=xterm-256color LANG=en_US.UTF-8 PS1='$ ' /bin/bash --norc --noprofile`,換成乾淨的 bash 3.2(prompt 為 `$ `,畫面不含個資) |
| 驅動方式 | Python 腳本用 pipe(**不是 TTY**)啟動 `herdr terminal session control|observe <target> --cols N --rows N`,依腳本寫 stdin,另一條 thread 讀 stdout,以 `time.monotonic()` 對每一行打時間戳。和 SSH exec 通道一樣只有 stdin/stdout/stderr |
| 未涵蓋 | **沒有經過 SSH**(本機 Remote Login 未開，`ssh localhost` 被拒),網路延遲與 sshd 行為未實測;Windows 未測 |

工具與腳本在 `docs/research/tools/session-control/`:`harness.py`(驅動與錄製)、`mkfx.py`(fixture 情境定義)、`runfx.sh`(依序錄製)、`export.py`(匯出 + 個資檢查)、`lat.py`/`bw.py`(延遲與頻寬統計)、`storm.py`(最壞情況輸出產生器)。

## 量測數據

### 延遲【實測】

| 項目 | 數值 | 說明 |
|---|---|---|
| 啟動 → 第一個 frame | 13–220 ms,p50 141 ms(n=19) | 【原始碼】閒置的 server 每 250 ms 才 poll 一次 listener(`src/server/headless.rs` `CLIENT_ACCEPT_POLL_INTERVAL`),所以落在 0–250 ms |
| 按鍵 → 畫面出現該字元 | p50 18.4 ms、p90 22.5 ms、最大 96.7 ms(n=200,bash readline 回顯) | 按鍵後 0.4–2 ms 先來一個「只移游標」的小 frame,字元本身要等下一個 render 週期 |
| render 週期 | 連續 frame 最小間隔 14–18 ms | 【原始碼】`MIN_RENDER_INTERVAL` = 16 ms(`src/app/mod.rs:39`),約 60 fps 上限 |
| resize → 新尺寸的 full frame | 1–4 ms | |
| release／stdin EOF → `terminal.closed` | < 1 ms;再 1–2 ms 後 stdout EOF | process 隨即結束 |
| 被拒的 control(已有 controller) | 約 65–120 ms 收到 `terminal.closed` | 沒有任何 frame |
| `exit` → `terminal.closed`(`terminal <id> exited`) | 約 6 ms | controller 與 observer 都收到 |

### 頻寬【實測】

「wire」= stdout 實際行長(JSON + base64),「raw」= base64 解開後的終端機 bytes。

| 情境 | 尺寸 | frame 數 | wire 總量 | 備註 |
|---|---|---|---|---|
| 閒置 5 秒 | 80×24 | 0 | 0 | **沒有 heartbeat** |
| 單一按鍵 | 80×24 | 2 | 約 170 B + 200–250 B | 「移游標」frame 固定約 53 B raw / 171 B wire |
| `seq 1 200000`(1.3 MB 輸出) | 80×24 | 13 | 7.2 KB | 0.21 s 跑完;中間輸出被合併掉 |
| 2 MB base64 亂數(`fold -w 79`) | 80×24 | 7 | 18.5 KB | |
| `top -s 1`(每秒更新) | 80×24 | 約 1/s | 1.9 KiB/s | |
| 最壞情況:每格隨機 256 色前景＋背景，持續 3 秒 | 80×24 | 172(56 fps) | 9.6 MB(3.0 MiB/s) | 每 frame 約 56 KB |
| 同上 | 120×40 | 72(22 fps) | 9.9 MB(3.0 MiB/s) | 每 frame 約 137 KB |
| 同上 | 200×60 | 28(8 fps) | 9.1 MB(2.6 MiB/s) | 每 frame 約 326 KB |
| 同上，但讀取端限速 64 KiB/s | 120×40 | 9 | 848 KB | 沒斷線、沒丟 closed;herdr 只送最新畫面，但最後一個 frame 在 storm 結束後約 10 秒才讀到 |

- 封裝負擔:大 frame 約 1.33×(base64 4/3 + JSON 欄位);小 frame 約 2.5–3.2×(JSON 欄位約 100 B 固定成本)。
- 每個 frame 固定包著 `ESC[?2026h`(synchronized output 開始)、`ESC[?25l`、`ESC]8;;ESC\`(清 hyperlink),結尾 `ESC[?2026l` 與游標位置／`ESC[?25h`,約 50 B raw。
- 【推論】頻寬上限由「畫面格數 × 每格屬性變化 × fps」決定，跟程式吐多少輸出無關。正常 CLI／agent 畫面每秒在數 KB 等級;只有整片彩色畫面每 frame 都變的程式才會到 MB/s。慢速連線下 herdr 會跳過中間畫面，但已經在 pipe／socket buffer 裡的 frame 還是要讀完，延遲大約是「buffer 內 frame 數 × 每 frame 傳輸時間」。

## 訊息實際格式

### stdout:`terminal.frame`【實測】

```json
{"bytes":"G1s/MjAyNmgbWz8yNWwbXTg7OxtcG1sxOzNIG1swOzM5OzQ5bWVjaG8b...","encoding":"ansi","full":false,"height":12,"seq":3,"type":"terminal.frame","width":40}
```

- 欄位依字母排序輸出;`bytes` 是標準 base64(有 padding)。
- `seq` 每條連線從 1 起算、逐 frame 加 1。
- `full:true` 出現在:第一個 frame、每次 resize 後、**擁有權變動時**(別的 client 嘗試 attach 被拒、被 takeover、takeover 方 release)。full frame 以 `ESC[2J` 開頭，逐列用 CUP 定位重畫。
- 增量 frame 只重畫有變的格子，**每段文字前都有絕對定位**(`ESC[row;colH`),寬字元與 emoji 也逐字定位(例:`ESC[5;1H中ESC[5;3H文`)。App 端模擬器的寬度表即使和 herdr 不同，也不會累積偏移。
- SGR 已被正規化:`ESC[0;1;38;5;1;49m`(粗體＋調色盤 1 號紅)、`ESC[0;38;5;214;49m`、`ESC[0;4;39;49m`。組合字元(`e` + U+0301)和基底字元同一格送出。
- **會轉送**:OSC 8 hyperlink(`ESC]8;;https://example.comESC\link`)、DECSCUSR 游標形狀(`ESC[5 q`)。
- **不會轉送**:視窗標題(OSC 0/2)、BEL、OSC 52 剪貼簿、alternate screen 切換(`?1049h`)、滑鼠回報模式(`?1000h`/`?1006h`)、bracketed paste 模式(`?2004h`)、DECCKM(`?1h`)。我們在測試 pane 裡逐一 `printf` 這些序列，串流中都沒有出現;所有 fixture 中出現過的 `ESC[?` 序列只有 `?25h/l` 與 `?2026h/l`。

### stdout:`terminal.closed`【實測】

```json
{"reason":"detached","type":"terminal.closed"}
```

本次實際收到的 `reason`:

| reason | 何時 |
|---|---|
| `detached` | 送 `terminal.release`,或關閉 stdin |
| `terminal attach taken over` | 別人以 `--takeover` 接管 |
| `terminal attach failed: terminal <terminal_id> already has an attached client; retry with --takeover` | 已有 controller 時再開 control(不帶 `--takeover`) |
| `terminal session control failed: terminal target <target> not found` | target 不存在 |
| `terminal session observe failed: terminal target <target> not found` | 同上(observe) |
| `terminal <terminal_id> exited` | pane 內程式結束(controller、observer 都收到) |

- 以上所有情況 process **exit code 都是 0**。
- **沒有** `terminal.closed` 就 EOF 的情況:單則輸入超過 1 MiB(見下)、herdr client process 被 SIGKILL。
- 收到 `terminal.closed` 後 stdout 立即 EOF、process 結束;之後再寫 stdin 會 broken pipe。

### stdin【實測】

```json
{"type":"terminal.input","text":"echo hi\r"}
{"type":"terminal.input","bytes":"FQ=="}
{"type":"terminal.resize","cols":60,"rows":15,"cell_width_px":0,"cell_height_px":0}
{"type":"terminal.scroll","direction":"up","lines":5,"source":"wheel","column":0,"row":0,"modifiers":0}
{"type":"terminal.mouse","action":"down","button":"left","column":6,"row":4,"modifiers":0}
{"type":"terminal.release"}
```

無效輸入只在 stderr 警告，串流繼續(之後的 `echo still-alive` 正常執行):

| 送出 | stderr |
|---|---|
| `{"type":"terminal.resize","cols":0,"rows":10}` | `herdr: terminal session control input ignored: terminal.resize cols and rows must be greater than 0` |
| `{"type":"terminal.resize","cols":40}` | `… invalid json command: missing field `rows`` |
| `this is not json` | `… invalid json command: expected ident at line 1 column 2` |
| `{"type":"terminal.bogus"}` | `… unknown variant `terminal.bogus`, expected one of `terminal.input`, `terminal.resize`, `terminal.scroll`, `terminal.mouse`, `terminal.release` …` |
| `{"type":"terminal.input","text":"x","bytes":"eA=="}` | `… terminal.input accepts text or bytes, not both` |
| 空行、`{"type":"terminal.input"}` | 無警告、無作用 |

## 各功能的行為

### 輸入【實測】

- `text` 與 `bytes` 都可用;控制字元(Ctrl-U `0x15`、Esc `0x1B`、Ctrl-C `0x03`)用 `bytes` 送沒問題。
- **完整包好的 bracketed paste**(`ESC[200~…ESC[201~`)會被 herdr 依 pane 的模式處理:bash 3.2 沒開 bracketed paste,herdr 把標記拿掉、只送 `echo pasted`。所以 App 的「貼上」可以永遠包標記，由 herdr 決定要不要保留。
- 輸入會把 herdr 主機端 scrollback 捲回底部(送 `#` 後下一個 frame 立刻回到最底)。
- 大小:900 KiB 的單則輸入(pane 端 `stty raw; head -c 921600 | wc -c`)約 56 ms 完整送達。**1.1 MiB 的單則輸入讓 client 被斷線**:stdout 直接 EOF,沒有 `terminal.closed`、stderr 也沒訊息,exit 0。【原始碼】上限是 `MAX_INPUT_PAYLOAD` = 1 MiB(`src/server/client_transport.rs`)。
- 附帶發現:canonical 模式的 tty 一行塞 900 KiB 會卡住(macOS 行緩衝上限),這是 tty 的行為，不是 herdr 的;Ctrl-C 可恢復。

### resize【實測】

- `--cols/--rows` 在 handshake 時就套用到 pane 的 PTY(`stty size` 回 `24 80`)。
- `terminal.resize` 後 1–4 ms 收到新尺寸的 full frame;`stty size` 立即反映(`15 60`、`10 30`),程式收得到 SIGWINCH。
- 期間 `herdr pane get` 的 `viewport_rows` 變成 controller 的列數;release 後恢復成桌機的尺寸(本機為 32 列)。controller 被 SIGKILL 時也會恢復。
- 很大的尺寸(5000×10)也被接受，回來一個 67 KB 的 full frame。【推論】App 端應自行限制上限。

### 捲動【實測】

`terminal.scroll` 依 pane 狀態由 herdr 決定怎麼處理【原始碼:`src/server/pane_input.rs` `apply_scroll`】:

| pane 狀態 | `source:"wheel"` | `source:"page_key"` |
|---|---|---|
| 一般 shell(沒開滑鼠回報、不在 alternate screen) | 捲 herdr 主機端 scrollback **`lines` 列**(上 5 → offset 5) | 也是捲主機 scrollback `lines` 列(上 3 → offset 再加 3) |
| 程式開了滑鼠回報(vim `mouse=a`) | 送**一個**滾輪事件到 `column/row`,**`lines` 被忽略**(lines=1 與 lines=3 都讓 vim 捲 3 行，那是 vim 自己每格捲 3 行) | 【原始碼】送 `ESC[5~`/`ESC[6~`(本次未在 vim 實測) |
| alternate screen、沒開滑鼠回報(less) | 轉成**一個**方向鍵,**`lines` 被忽略**(lines=3 只讓 less 捲 1 行) | 送一次 PageDown(less 翻一頁) |

- 主機端 scrollback 捲動後，frame 本身**不帶任何「目前在 scrollback」的標記或 offset**;要知道位置只能另外查 `herdr pane get`(`scroll.offset_from_bottom`)。
- 捲動的畫面只有 frame 差異，沒有 full frame。

### 滑鼠【實測】

- 一般 shell(沒開滑鼠回報)時，`terminal.mouse` 被丟棄，沒有任何 frame。
- vim `mouse=a`:click(down + up)在 `column 6, row 4`(零起算)把游標移到該格對應的位置(`:echo line('.') col('.')` → `11 2`,畫面已捲到第 7 行開始、行號欄 4 格寬，計算吻合);down → drag → drag → up 進入 `-- VISUAL --`。
- 座標是 controller viewport 的零起算格。

### 接管與 observer【實測】

依序：A 開 control → observer O(30×8)開始觀察 → B 開 control(不帶 `--takeover`)→ C 開 control `--takeover`(50×14)→ C release。

- B:約 116 ms 後收到 `already has an attached client; retry with --takeover`,沒有 frame,exit 0。**副作用**:B 這次失敗的嘗試讓 A 與 O 都收到一個 full frame。
- C:立刻收到兩個 full frame(50×14),`stty size` 回 `14 50`。
- A:收到 `terminal attach taken over`,stdout EOF、process 自行結束，之後寫 stdin 為 broken pipe。
- O:始終用自己的 30×8 viewport;C 接管時收到兩個 full frame,C release 時再一個 full frame。O 的 stdin 完全不讀(寫入的 `echo observer-ignored` 沒有出現),關閉 stdin 也不會結束，要等 stdout 寫入失敗或被 kill。
- controller 被 SIGKILL:擁有權立刻釋放、pane 尺寸恢復;接著不帶 `--takeover` 再開 control 直接成功。
- target 可以用 pane id(`w2:p1`)或 terminal id(`term_…`),兩者都測過。

### 結束(`terminal.closed`)【實測】

- pane 內 `exit`:controller 與 observer 都在約 6 ms 內收到 `terminal <id> exited`,隨後 EOF。單一 pane 的 workspace 也隨之消失。
- 關閉 stdin 等同 release(`detached`)。【推論】SSH exec 通道關閉時 sshd 會關掉 stdin,所以 App 正常掛斷時 herdr 會乾淨釋放;但網路無聲斷掉時，主機上的 herdr client 可能留到 sshd 發現為止，期間 pane 仍被佔住——下次開啟會被拒，要靠「接管」按鈕(未實測，本機沒有 sshd)。

## 對 #20 的要求

1. **模擬器只做畫面**:不要把 App 端模擬器的滑鼠／滾輪手勢編碼成 bytes 送出;一律送 `terminal.mouse`／`terminal.scroll`。模擬器看不到程式的模式，自己編碼一定會錯。
2. **貼上**:永遠包 `ESC[200~ … ESC[201~` 用 `terminal.input` 送;herdr 依 pane 模式處理。
3. **方向鍵**:App 看不到 DECCKM,固定送 CSI 形式(`ESC[A`);大部分程式兩種都收。
4. **滾輪**:每滑過一列送一則 `terminal.scroll`(`lines:1`),不要合併成一則大 `lines`;否則在 vim、less 裡會捲太少。
5. **輸入切塊**:每則 `terminal.input` 遠低於 1 MiB(建議 64 KiB 以內)。超大貼上必須分段，而且分段後就不再是「完整的 bracketed paste」,herdr 會把標記原樣送出——【推論】大於上限的貼上應在 App 端擋下或提示。
6. **結束判斷**:看 `terminal.closed.reason`;stdout EOF 但沒有 `closed` → 視為連線中斷(可重連);不要看 exit code。被拒(`already has an attached client`)時才顯示「接管」。
7. **resize 去抖**:每次 resize 都會讓 pane PTY 改尺寸並回一個 full frame,保留 250 ms 去抖。cols/rows 要限制在合理範圍。
8. **標題**:串流沒有標題，改用 herdr snapshot 的 `terminal_title`。BEL 與 OSC 52 寫入在 control 下拿不到——`herdrchat-behavior-spec.md` §6.4 的「OSC 52 寫入剪貼簿」「bell 轉事件」在這條路徑上**做不到**,要從需求中移除或另想辦法。
9. **沒有 heartbeat**:連線健康要靠 SSH 層(keepalive)判斷，不能靠「多久沒收到 frame」。
10. **慢速連線**:彩色整片畫面在低頻寬下會延遲數秒;herdr 不會因讀太慢而斷 controller。【推論】必要時可縮小 viewport 降低每 frame 大小。

## 限制與未驗證

- 沒有經過真正的 SSH 通道;網路延遲、sshd 關通道時的訊號、無聲斷線後殘留的 client 都沒實測。
- Windows 未測(ADR-0005 的另一半前提)。→ 已在 #6 實測，見 `terminal-session-control-windows.md`。
- 只用 bash、vim、less、top 測過，沒有測 agent 的 TUI(依安全規則不碰使用者的 agent)。
- 延遲數據是本機 pipe,不含網路來回。

## Fixture

位置：`docs/research/fixtures/session-control/`。全部以 40×12 錄製(observer 30×8、接管方 50×14),畫面只有乾淨 bash 的內容;匯出時以家目錄路徑、帳號、主機名等樣式檢查過 base64 解開後的內容，沒有命中。

每個情境最多三個檔:

- `<名稱>.stdout.ndjson`:herdr stdout 逐行原樣，可直接餵 parser。
- `<名稱>.stdin.ndjson`:我們送進 stdin 的行(observer 的 stdin 會被忽略)。
- `<名稱>.transcript.ndjson`:時間序紀錄 `{"t_ms":…,"dir":…,"line":…}`,`dir` 為 `stdin`/`stdout`/`stderr`/`stdin_eof`/`stdout_eof`/`sigkill`/`exit`(`exit` 的 `line` 是 exit code)。

| 情境 | 內容 |
|---|---|
| `01-handshake-echo-release` | 第一個 full frame、輸入與回顯、release → `detached` |
| `02-resize` | 40×12 → 60×15 → 30×10,每次 full frame,`stty size` 驗證 |
| `03-scroll-host-scrollback` | 主機 scrollback 的 wheel/page_key、沒開滑鼠回報時 mouse 被丟棄、輸入讓捲動歸位 |
| `04-mouse-wheel-vim` | vim `mouse=a`:滾輪(`lines` 被忽略)、click、drag 選取 |
| `05-alternate-scroll-less` | less:滾輪轉方向鍵、page_key 翻頁 |
| `06-takeover-A/B/C/observer` | 擁有權：被拒、接管、被接管、observer 看到的 full frame |
| `07-unicode-colors` | 256 色與粗體／底線 SGR、中文與 emoji 寬字元、組合字元、bracketed paste 被拿掉標記 |
| `08-burst-coalesce` | `seq 1 100000` 被合併成 6 個 frame |
| `09-invalid-input-stderr` | 各種無效輸入的 stderr 警告，串流繼續 |
| `10-stdin-eof-release` | 關 stdin → `detached` |
| `11-oversize-input-disconnect` | 1.1 MiB 單則輸入 → 無 `closed` 的 EOF(stdin 檔以摘要取代原始輸入) |
| `12-sigkill-then-reattach`(含 `-2`) | controller 被 SIGKILL → 無 `closed` 的 EOF;再開 control 不需 `--takeover` |
| `13-not-found-control/observe` | target 不存在 |
| `14-exited-control/observer` | pane 內 `exit` → 兩邊都收到 `terminal <id> exited` |

fixture 裡的 terminal id(`term_660523e11df7c5`)是當次測試 pane 的隨機 id,已不存在。

重新錄製：建一個專用 workspace(`herdr workspace create --no-focus`),在該 pane 換成上述乾淨 bash,執行 `docs/research/tools/session-control/runfx.sh <terminal_id> <pane_id>`,再以 `PII_PATTERN='<自己的帳號|主機名|家目錄>' python3 export.py fx <輸出目錄>` 匯出。

## controller 不送 resize 時的尺寸行為(#357)

背景:行為規格寫 controller 的 `terminal.resize` 會改變 Pane 的 PTY 尺寸,接上期間鎖在 controller 尺寸,離開時恢復。#357 的「保留電腦版面」模式因此**不送 `terminal.resize`**,以 full frame 的 `width`／`height` 當顯示格數。這份實作只依文件推論,**尚未在真主機驗證**,下列項目要在 SSH 與 HTTPS 各驗一次:

1. 接上前後,電腦上該 Pane 的欄列數不變(`herdr pane list` 或在電腦上看版面)。
2. 第一個 frame(`full: true`)的 `width`／`height` 是 Pane 原本的尺寸,而不是 handshake 的 `--cols`／`--rows`。
3. **handshake 本身需要 `--cols`／`--rows`**(`HerdrCommand.terminalSessionControl`;HTTPS 的 `pane.terminal.open` 同):保留模式目前帶的是手機視圖放得下的格數。若 herdr 接上時就把 Pane 鎖成這個尺寸,保留模式沒有效果;替代方案是 handshake 改帶 Pane 目前的尺寸(需另有來源,例如 snapshot 或先 observe 一次讀到第一個 frame)。
4. 離開(release)後 Pane 回到原尺寸。
5. 電腦端調整視窗時,controller 是否收到新的 full frame(畫面隨之重新縮放,故事 16)。

驗證結果在下方「真主機驗證」:第 2、3 項**不成立**,`PaneTerminalModel.connect` 已改成 handshake 帶 Pane 目前的尺寸。

### 真主機驗證(#357,2026-11-21)

> 標記沿用本文件:**【實測】**、**【原始碼】**(herdr 0.9.5,commit `2ecf19a`)、**【推論】**。

**結論:herdr 0.9.5 的 `terminal session control` 一定會把 Pane 的 PTY 改成 handshake 的尺寸,沒有「不改尺寸」的 controller 模式。** #357 現在「不送 `terminal.resize`、handshake 帶手機格數」的做法**沒有保留效果**:電腦上的 Pane 從接上那一刻就變成手機的欄列數。要保留，handshake 必須帶 Pane **目前的 PTY 尺寸**;唯一完全不碰尺寸的接法是 `observe`(但它不收輸入)。

#### 環境與方法

| 項目 | 值 |
|---|---|
| 主機 | macOS(Darwin 27.2.0,arm64),herdr 0.9.5 |
| 隔離 | 獨立具名 session `herdr --session purrdr-357-test server`,只建一個測試 workspace;每個指令都帶 `--session purrdr-357-test`。測完 `herdr session stop` + `herdr session delete`,`herdr session list` 只剩 `default`。使用者的 `default` session 沒有被任何指令指到 |
| 模擬電腦 | 以 Python `pty.fork` 開 `herdr --session purrdr-357-test`(TUI client),視窗 160×50;要先清掉 `HERDR_*` 環境變數，否則被擋(`error: nested herdr is disabled by default.`) |
| 量尺寸 | PTY 實際尺寸:在 Pane 裡 `herdr pane run w1:p1 'clear; stty size'` 再 `herdr pane read`;另記 `herdr pane layout --pane w1:p1` 的 `rect` 與 `herdr pane get` 的 `scroll.viewport_rows` |
| controller | pipe(非 TTY)啟動 `herdr --session purrdr-357-test terminal session control w1:p1 [--cols N --rows N]`,記錄每個 full frame 的 `width`／`height`,最後送 `{"type":"terminal.release"}` |
| 腳本 | scratchpad `h357/h.py`(驅動)、`t2.py`～`t5.py`(閒置、observe 裁切、split、alternate screen、observe + 電腦改視窗);未進 repo |
| 未涵蓋 | 沒有經過 SSH(本機沒有 sshd)與主機服務;兩者都只是轉呼叫同一個 CLI(見「SSH 與 HTTPS」),【推論】行為相同 |

#### 1. Pane 原本的尺寸怎麼查【實測】

電腦 client 160×50,單一 Pane:

```
[desktop baseline] area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
```

- 左側 sidebar 占 26 欄、狀態列 1 列，所以 layout 是 134×49。
- **`rect.width` 不是 PTY 欄數**:PTY 是 133 欄。差的 1 欄是 scrollbar gutter。
- split 成左右兩個 Pane 後:`rect` 67×49,PTY `stty rows=47 cols=64`(邊框左右 2 欄、上下 2 列，再加 gutter 1 欄);`viewport_rows` 是 47。
- 同一個 split Pane 進 alternate screen 時欄數變 65、離開回 64(`47 64` → `47 65` → `47 64`)。
- 【原始碼】`src/ui/panes.rs`:PTY = `rect` 扣掉邊框(`pane_borders`、`pane_gaps`、`pane_outer_borders`,只在多 Pane 或設定為 always 時有)再扣 scrollbar gutter 1 欄(`pane_scrollbars = true` **且不在 alternate screen**,寬度 ≤ 4 時不扣)。
- **列數有精確來源**:`panes[].scroll.viewport_rows`(snapshot、`pane list`、`pane get` 都有)就是 PTY 列數(上面 49、47;controller 接上 50×30 期間變成 30)。
- **欄數沒有 API**:`herdr api schema --json` 裡跟尺寸有關的欄位只有 `height`、`width`(layout 的 rect)、`viewport_row(s)`;`pane get`、`pane process-info`、`pane read` 都不帶欄數。只能從 `rect.width` 依上面規則推算，推算結果受主機設定與 alternate screen 影響。
- 沒有電腦 client(headless)時，layout 是設定的 headless 尺寸(預設 120×40,`config.rs` `DEFAULT_HEADLESS_COLS/ROWS`),PTY 起始是 119×40(扣 gutter)。

#### 2. 以 Purrdr 現在的方式接上(手機尺寸 50×30)【實測】

```
[before]           area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
$ herdr --session purrdr-357-test terminal session control w1:p1 --cols 50 --rows 30
[after handshake]  full frames (w,h,t_ms)=[(50, 30, 245)]
[during]           area=134x49 rect=134x49 viewport_rows=30 | stty rows=30 cols=50
[final]            terminal.closed reason=detached
[after release]    area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
```

- **接上就變成 50×30**,不需要任何 `terminal.resize`。第一個 full frame 是 50×30(不是 Pane 原尺寸),所以文件待驗證第 2 項不成立。
- layout `rect` 不變(電腦上框的大小不變，裡面的程式畫成 50×30)。
- 不送 resize 閒置 6 秒，一直維持 50×30(t≈1、3、6 秒都是 `stty rows=30 cols=50`,沒有額外 full frame)。
- release 後回到電腦 layout 的 133×49。
- 【原始碼】`src/server/headless.rs` `attach_terminal_client`:接上時無條件 `runtime.resize(rows, cols, …)`,並把 terminal 加進 `direct_attach_resize_locks`;`src/ui/panes.rs` 的版面重算對鎖住的 terminal 跳過 resize。

#### 3. 不帶 `--cols`／`--rows`【實測】

```
$ herdr --session purrdr-357-test terminal session control w1:p1
[after handshake]  full frames (w,h,t_ms)=[(120, 40, 16)]
[during]           area=134x49 rect=134x49 viewport_rows=40 | stty rows=40 cols=120
[after release]    area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
```

- **變成 120×40**,不是 Pane 原尺寸。【原始碼】`src/cli.rs`:CLI 自己預設 `cols = 120`、`rows = 40` 再送給 server,server 分不出「沒帶」。
- `observe` 不帶尺寸時 frame 也是 120×40。

#### 4. 帶 Pane 原本的欄列數【實測】

```
$ … control w1:p1 --cols 133 --rows 49
[after handshake]  full frames (w,h,t_ms)=[(133, 49, 249)]
[during]           area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
[after release]    area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
```

- **完全一致時 Pane 不變**,第一個 full frame 就是 133×49。
- 用 `rect` 直接當欄數(134×49)會差 1 欄:接上期間 `stty rows=49 cols=134`,release 後回 133。所以要扣 gutter。
- 接上期間不送 resize,Pane 維持(見第 2 項的閒置測試，機制相同)。
- **鎖住的副作用**:接上 133×49 後電腦把視窗改成 140×44 → layout 變 114×43,但 PTY 仍是 `stty rows=49 cols=133`;controller 收到一個 133×49 的 full frame(尺寸沒變)。release 後 Pane 才變成 113×43。所以「保留」只保留接上那一刻的尺寸，接上期間電腦改版面不會生效。
- **離開後是否恢復，取決於電腦上有沒有開著 herdr client**:
  - 有 client:release 後回到電腦 layout 的尺寸(上面每個情境都是)。
  - 沒有 client(headless):**不恢復**,停在最後一個 controller 的尺寸:
    ```
    [before]        area=120x40 rect=120x40 viewport_rows=40 | stty rows=40 cols=119
    $ … control w1:p1 --cols 50 --rows 30
    [after release] area=120x40 rect=120x40 viewport_rows=30 | stty rows=30 cols=50
    ```
    下一個不帶尺寸的 control 把它改成 120×40,release 後也停在 120×40。電腦 client 關掉時同樣不會改回(`desktop detached` 後仍是 `stty rows=49 cols=133` 或上次的值)。這時 `rect` 是 headless 的 120×40,與 PTY 無關;`viewport_rows` 仍是真的 PTY 列數(30)。

#### 5. 觀察模式(observe)【實測】

```
$ … observe w1:p1 --cols 50 --rows 30
[after handshake]  full frames (w,h,t_ms)=[(50, 30, 248)]
[during]           area=134x49 rect=134x49 viewport_rows=49 | stty rows=49 cols=133
```

- **observe 不改、不鎖 Pane 尺寸**。接著電腦改視窗為 140×44:Pane 照常變成 113×43,observer(viewport 133×49)收到一個 full frame,尺寸仍是自己的 133×49。
- observer 的 viewport 比 Pane 小時**從左上角裁切**:Pane 133×49 畫滿 132 個 `L` + `R`、46 行 `rowN`、最後一行 `BOTTOM`;50×30 的 observer 只看到 50 個 `L`、`row1`～`row29`,沒有 `R` 與 `BOTTOM`(游標所在的底部看不到)。viewport 等於或大於 Pane(133×49、160×60)時內容完整。
- observe 的 stdin 不讀(前面「接管與 observer」已實測),所以不能打字;也不能送 `terminal.resize` 改 viewport。
- 【原始碼】`observe_terminal_client` 只設 `TerminalObserve` 模式，不呼叫 `runtime.resize`、不加 resize lock。
- herdr 0.9.5 沒有其他接法:`terminal attach`(只有 `--takeover`)與 `agent attach` 都是 direct attach,同樣走 `attach_terminal_client` 改尺寸。

#### 6. 外部參考【原始碼】

- herdrchat:Pane 終端機是在 PTY 裡跑 `herdr agent attach <pane>`,PTY 尺寸取自畫面第一次 `onSizeChange`(`modules/herdr-ssh/README.md`:`cols: 80, rows: 24, // from the view's first onSizeChange`),一律用手機尺寸，沒有保留電腦版面的做法。
- Heeler(Windows 路線):`terminal session control <target> --cols <view> --rows <view>`,同樣帶畫面尺寸(`Sources/Heeler/Transport/HeelerSSHTransport.swift`)。它的相容性紀錄(`docs/agents/herdr-compatibility.md`,herdr 0.9.3)也記到:headless Pane 起始 120×40,client 接上後 Pane 變成 client 的尺寸，離開後保留(40×30 接上後一直是 40×30)——與上面第 4 項的 headless 結果一致。

#### SSH 與 HTTPS

- SSH:`HerdrCommand.terminalSessionControl` 組 `terminal session control '<target>' --cols N --rows N`,行為即上面的實測。
- HTTPS:協定 `pane.terminal.open` 的 `columns`、`rows` 是**必填**(`vendor/purrdr-host/protocol/host-service.schema.json`,主機服務 0.9.0);主機服務 `host-service/service/src/pane_terminal.rs` 照樣轉成 `--cols`／`--rows` 給 `control`(唯讀裝置給 `observe`)。所以 HTTPS 也是「帶什麼就鎖成什麼」;就算協定改成可省略，herdr 也只會變成 120×40,**省略尺寸不是解法**。
- 唯讀裝置(主機服務以 observe 接上)本來就不改電腦上的尺寸;它要的是 viewport 不小於 Pane,否則從左上角裁切、看不到底部。

#### 對 #357 的建議

1. **handshake 帶 Pane 目前的 PTY 尺寸**(保留模式；SSH 與 HTTPS 相同，HTTPS 以 `pane.terminal.open` 的 `columns`／`rows` 帶):
   - 列數 = 開啟前從 snapshot(或 `pane.get`)讀到的 `scroll.viewport_rows`,精確。
   - 欄數 = 對應 layout 的 `rect.width` 推算:單一 Pane、預設設定扣 1(gutter);多 Pane 另扣左右邊框。推算可能差 1～2 欄(主機改過 `pane_borders`／`pane_gaps`／`pane_outer_borders`／`pane_scrollbars`,或 Pane 正在 alternate screen 時不扣 gutter),差多少 PTY 就變多少。【推論】差 1 欄對多數 TUI 只是重排一次，可接受;要精確只能等 herdr 提供欄數(可向上游提)。
   - 列數也可以用 `rect.height` 減邊框交叉核對;兩者不一致時以 `viewport_rows` 為準。
   - **headless 主機(電腦沒開 herdr client)不能用 `rect`**:它是 120×40 的 headless 尺寸，與 PTY 無關(上一支手機留下的尺寸)。【推論】這時「電腦版面」不存在，保留模式可直接用手機尺寸，或至少用 `viewport_rows` 加一個合理欄數;判斷方式可比對 `viewport_rows` 與 `rect.height`(headless 時 rect 恆為設定的 headless 尺寸)。
2. **接上期間不送 `terminal.resize`**(現行做法正確),顯示格數以 full frame 的 `width`／`height` 為準。
3. 電腦端接上期間改視窗不會生效(Pane 被鎖住),controller 只收到一個尺寸不變的 full frame。若要跟著電腦版面，需要偵測 layout 變化(`layout.updated` 事件或重讀 snapshot)後自己送 `terminal.resize` 成新的 PTY 尺寸——這會變成「主動跟隨」而不是「不碰」;或在 UI 說明「接上期間電腦上的 Pane 尺寸固定」。
4. **真正不碰電腦尺寸的替代方案**:以 `observe`(viewport = 推算出的 Pane 尺寸或更大)看畫面，輸入改走 herdr API 的 `pane.send_text`／`pane.send_keys`(不需要 attach 擁有權)。observe 不鎖、不改尺寸，電腦改版面會即時生效;代價是捲動、滑鼠、`page_key` 等只在 control 串流上的訊息沒有，且 viewport 固定(Pane 變大時從左上裁切，要重開 observe)。HTTPS 需要主機服務讓非唯讀裝置也能選 observe(協定加欄位)。
5. 待驗證：經真正的 SSH 與主機服務各跑一次第 2、4 項(預期相同);電腦 client 停在**別的** workspace／tab 時，目標 Pane 的 PTY 尺寸與 `rect` 的關係(本次只測了顯示中的 tab)。

#### app 的做法(#357)

- 保留電腦版面時 handshake 帶 Pane 目前的尺寸:列數取 snapshot 的 `panes[].scroll.viewport_rows`,欄數由 layout 的 `rect.width` 推算(多 Pane 扣左右邊框各 2 欄、不在 alternate screen 扣 scrollbar 1 欄)。換算規則是核心的 `HostSnapshot.nativeSize(ofPane:isAlternateScreen:)`,案例就是上面的實測數字(`PaneNativeSizeTests`)。app 目前不知道 Pane 是否在 alternate screen,一律當成不在(最多差 1 欄,TUI 只是重排一次)。
- 電腦沒開 herdr(headless)時 layout 恆為 120×40、與 PTY 無關,換算回 `nil`,退回手機的格數,並在大小 sheet 的 footer 說明(`PaneTerminalModel.keepDesktopFallback`)。
- 接上期間不送 `terminal.resize`;電腦端在接上期間改視窗不會生效(Pane 被鎖住),sheet 的 footer 也說明。
- 唯讀裝置(observe)同樣帶推算出的尺寸,viewport 才不會比 Pane 小而被從左上角裁切。
- 尚未驗證:經真正的 SSH 與主機服務各跑一次;電腦 client 停在別的 workspace／tab 時的 `rect` 與 PTY 關係。

#### 定案做法(Heeler)的離開還原實測(#357,2026-11-23)

只對自建的 `purrdr-test` workspace 的 Pane 操作(測完以 id 關閉)。數字是 PTY 列數(macOS 另以 `stty size` 核對欄數);基準是接上前 Pane 在主機上的尺寸。

| 情境 | macOS 直接執行 | Windows 經 OpenSSH exec | HTTPS 主機服務(macOS／Windows) |
|---|---|---|---|
| 以 40×12 接上 | 12 列 40 欄 | 12 列 | 12 列 |
| 接上期間 resize 60×15(旋轉) | 15 列 60 欄 | 15 列 | 15 列 |
| release 後 | 還原(33 列 163 欄) | 還原(32 列) | 還原 |
| 回來重新接上(`resume`) | — | — | 15 列(以同一組格數) |
| 被終止:SIGKILL 的 CLI／切斷 ssh／WSS 斷線(不送 release) | 還原 | 還原 | 還原 |
| 只關 stdin(無 release) | 還原 | 還原 | — |
| 快速進出 6～8 次(一半未收到 frame 就放開) | 還原 | 還原 | 還原 |
| 同時第二個 control | 被拒「already has an attached client」,結束後仍是基準 | 同左 | — |

- 沒有殘留程序:Windows 上以 CIM 查 `terminal session` 沒有留下 herdr 子行程。自己啟動的第二個主機服務(`--state-dir` 指到暫存資料夾)在 ssh 斷線後 `purrdr-host-service.exe` 仍留在 Windows(只有本機 ssh 被殺,遠端 exe 沒跟著結束),測完以 PID 手動清掉;這是測試方式造成,不是 app 的行為。purrdr.host#88 的結論:Win32-OpenSSH 在非 pty session 異常結束時不結束子程序樹(主機服務收不到 stdin EOF,直接父程序是同樣成孤兒的 Git Bash),不改程式。真主機上跑暫時主機服務的啟動與清理方式見 purrdr.host 的 `AGENTS.md`「在真主機上跑暫時的主機服務」(複製出來的執行檔、獨立 `--state-dir` 與埠、覆寫 `HOME`／`USERPROFILE`,結束時以 `running.json` 的 pid 加指令列標記明確清理)。
- 沒測:macOS 經 SSH(本機 Remote Login 沒開,`ssh localhost` 被拒;herdr 行為與直接執行同一指令)。
