# `herdr remote-api-bridge` 與 `terminal session control` 在 Windows 的實測(#6)

> 目的：確認 Windows 主機上 `herdr remote-api-bridge` 與 `herdr terminal session control` 能不能用、該怎麼呼叫(PowerShell `-EncodedCommand`,以及 Git Bash 下直接呼叫),記下和 macOS(`terminal-session-control-macos.md`)的差異，並錄製 fixture。結論給 Windows 支援票(#26)。
>
> 標記:**【實測】** = 本次在 Windows 實測機實際執行觀察到;**【文件】** = herdr 0.9.5 官方文件(路徑相對於 `herdrdev/herdr@v0.9.5` 的 `docs/next/website/src/content/docs/`);**【推論】** = 根據前兩者推出、未直接驗證。

## 結論

**兩者在 Windows 都可用，維持 ADR-0005(Pane 終端機全平台走 `terminal session control`)。** 結論以 herdr **0.9.5** server 為準;`remote-api-bridge` 在 0.9.4 server 上也測過一輪，結果相同。

| 項目 | 結果 | 依據 |
|---|---|---|
| `remote-api-bridge`,Git Bash 直接呼叫 | 可用 | 【實測】`bridge/0.9.5/gb-*`、`bridge/0.9.4/gb-*` |
| `remote-api-bridge`,PowerShell 5.1 `-EncodedCommand` | 可用，輸出 bytes 與 Git Bash 完全相同 | 【實測】`bridge/0.9.5/ps-*`、`utf8-*` |
| `remote-api-bridge`,經 `cmd.exe /c` 再呼叫 PowerShell | 可用 | 【實測】`bridge/0.9.5/cmd-ps-ping-open` |
| `terminal session control`/`observe` | 可用，wire format 與 macOS 相同 | 【實測】`session-control/*` |
| 「Windows 不支援 direct terminal attach」是否影響 session control | **不影響**。文件只把 `herdr terminal attach`(直接接上目前的終端機)列為不支援;session control/observe 是另一條走 server API socket 的 NDJSON 串流，同一節的文件沒有 Windows 限制 | 【文件】`windows-beta.mdx:131-137`、`persistence-remote.mdx:113-164`、`cli-reference.mdx:369-402`;【實測】本筆記 |
| live handoff | Windows 不支援(`ping` 的 `capabilities.live_handoff` 是 `false`) | 【文件】`windows-beta.mdx:136,150`;【實測】`ping.ndjson` |

和 macOS **不同**、Windows 支援票必須處理的地方(細節見「給 #26 的待辦」):

1. **Windows 的 bridge 一看到 stdin EOF 就放棄請求，連 `ping` 都不回**(macOS 還會回 `ping`)。我們本來就不送 EOF,但 Windows 上這條規則沒有例外。
2. **PowerShell 包裝的成本**:每次啟動 PowerShell 5.1 約 0.6–0.8 s(pwsh 7 約 1.4–2.5 s),herdr 本身約 0.07 s。每個請求一個 bridge 時，這是每個請求的固定延遲。
3. **作業系統偵測**:Git Bash 的 `uname -s` 是 `MINGW64_NT-10.0-26300`,現在的 `HostProbe` 會當成不支援的 OS。
4. **observer 不會自己結束**:SSH client 斷掉後,`observe` 的 herdr 程序會留在主機上，直到下一次 stdout 寫入失敗;Windows 沒有 Unix 那個 30 秒寫入逾時。control 沒有這個問題。
5. **ConPTY 的 resize 殘影**:縮小視窗後，畫面上可能留下舊內容的片段(herdr 照實轉送 ConPTY 畫出來的東西)。

## 測試環境與方法

| 項目 | 值 |
|---|---|
| 日期 | 2026-11-16 |
| 主機 | Windows(`MINGW64_NT-10.0-26300`,x86_64),經 Tailscale 的 OpenSSH 登入;**登入後預設 shell 是 Git Bash** |
| herdr | client 0.9.5(`%USERPROFILE%\.herdr\packages\standalone\releases\0.9.5-x86_64-pc-windows-msvc\herdr.exe`,在 PATH 上)。server 起初是 **0.9.4**,測試途中由使用者重啟為 **0.9.5**(`herdr status server` 的 `version:` 欄;每組錄製都有記錄) |
| PowerShell | Windows PowerShell 5.1.26100;另有 pwsh 7.7.0 |
| 測試對象 | 用 `herdr workspace create --no-focus --label purrdr-spike --cwd 'C:\Windows\Temp'` 自建的 workspace(只有 shell pane,herdr 在 Windows 的預設 shell 是 PowerShell,prompt 為 `PS C:\Windows\Temp>`);`exit` 的測試用同一 workspace 裡另外 split 出來的 pane。**使用者正在使用的 workspace 只做唯讀查詢(`workspace list`),沒有對其中的 pane 做任何操作。** server 重啟後這個 workspace 仍在;測完以 `herdr workspace close` 刪除，之後 `workspace get` 回 `workspace_not_found` |
| 驅動方式 | Mac 上的 Python 腳本以 pipe 啟動 `ssh … '<遠端指令>'`,依腳本寫 stdin、另一條 thread 讀 stdout/stderr 並以 `time.monotonic()` 打時間戳。每個案例是一條新的 SSH 連線，所以時間包含 SSH 連線建立 |
| 未涵蓋 | OpenSSH 預設 shell 真的是 cmd 或 PowerShell 的主機(實測機是 Git Bash;cmd 只以 `cmd.exe //c` 模擬);以系統管理員權限啟動的 server;herdr 0.9.3;vim/less 等開了滑鼠回報或 alternate screen 的程式;agent 的 TUI |

工具在 `docs/research/tools/windows/`:`harness.py`(驅動與錄製，實測機由環境變數 `PURRDR_WIN_SSH`、`PURRDR_WIN_SSH_KEY` 指定)、`bridge_tests.py`(bridge 案例)、`sc_tests.py`/`sc2.py`/`sc3.py`(session control 案例、接管與斷線、pane 結束與延遲)、`decode.py`(把 frame 解開成文字)、`export.py`(去識別化匯出 + 個資檢查)。

## 呼叫方式【實測】

### Git Bash 直接呼叫

app 現有的 POSIX 指令字串原樣可用(`HerdrCommand.bridge()`、`terminalSessionControl(…)`、`version(…)`):

```sh
PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" 'herdr' remote-api-bridge
```

`ping` 正常回應、`terminal session control 'w9:p9'` 回 `not found`、`--version` 回 `herdr 0.9.5`(`bridge/0.9.5/posix-*`)。Git Bash 的 `$HOME` 是 `/c/Users/<帳號>`,herdr 由安裝程式放在 PATH 上(【文件】`windows-beta.mdx:24`),所以前綴的 PATH 只是多餘、不會壞事。

### PowerShell `-EncodedCommand`

腳本以 UTF-16LE 編碼後 base64,外層:

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <base64>
```

測過兩種腳本，結果相同:

```powershell
# 直接呼叫(較短)
$ProgressPreference='SilentlyContinue'; & herdr remote-api-bridge; exit $LASTEXITCODE
# herdr 自己的 remote 功能用的形式(行為規格 §3.9)
$ProgressPreference='SilentlyContinue'; $p = Start-Process -FilePath herdr -ArgumentList 'remote-api-bridge' -NoNewWindow -PassThru; $p.WaitForExit(); exit $p.ExitCode
```

- stdin 會傳給 herdr:bridge 的請求、session control 的 `terminal.input`/`resize`/`release` 都正常(`ps-ping-open`、`ps-start-ping-open`、`session-control/01ps-*`、`10ps-*`)。
- **herdr 的輸出不經過 PowerShell 管線**:中文與 emoji 的 workspace 名稱經 Git Bash、PowerShell 5.1、pwsh 7 取回的 bytes 完全相同(SHA-1 一致，`bridge/0.9.5/utf8-*`);herdr 的換行是 `\n`。
- **PowerShell 自己印的東西是 `\r\n`**(例如腳本裡的 `Write-Output`、`(Get-Command herdr).Source`)。包裝腳本不要往 stdout 印任何東西;要印就得在 client 端去掉 `\r`。
- exit code 正確傳回:連不到 socket 時 `exit $LASTEXITCODE` 回 1(`ps-no-session`)。
- 由 `cmd.exe //c powershell.exe … -EncodedCommand …` 呼叫也可以(`cmd-ps-ping-open`),也就是 OpenSSH 預設 shell 是 cmd 時同一行指令可用【推論:實測機的預設 shell 是 Git Bash,cmd 只是模擬】。

### 啟動成本(在主機上量，不含 SSH)

| 指令 | 時間 |
|---|---|
| `herdr remote-api-bridge --check` | 0.069–0.085 s(n=3) |
| `powershell.exe … -EncodedCommand`(腳本只有 `exit 0`) | 0.61–0.76 s(n=3) |
| `pwsh.exe … -EncodedCommand`(同上) | 1.37–2.50 s(n=2) |

經 SSH 的整段(連線 + 啟動 + 回應)：Git Bash 直接呼叫約 1.0–1.5 s,PowerShell 包裝約 1.4–3.4 s(`bridge/*/*.transcript.ndjson` 的 `t_ms`)。

## `remote-api-bridge` 的行為【實測】

0.9.4 與 0.9.5 server 結果相同(兩組錄製都在 `bridge/<版本>/`)。

| 案例 | 結果 |
|---|---|
| `--check` | `herdr-api-bridge-v1`,exit 0 |
| `ping`,stdin 保持開著 | 一行 `{"id":"purrdr:ping","result":{"type":"pong","version":"0.9.5","protocol":22,"capabilities":{…}}}`,之後 bridge 自己結束(stdout EOF、exit 0),不必等我們關 stdin |
| `ping`,寫完立刻 EOF | **沒有任何輸出**,exit 0(Git Bash、PowerShell 都一樣)。在主機上用 `printf … \| herdr remote-api-bridge` 跑 3 次也都沒輸出;stdin 多開 1 秒(`(printf …; sleep 1) \|`)就有回應——不是 SSH 的時序問題 |
| 一次寫兩行請求 | 只回第一個(和 macOS 相同，single-shot) |
| JSON 無效 | `{"id":"","error":{"code":"invalid_request","message":"invalid request: key must be a string at line 1 column 37"}}` |
| 具名 session 不存在(`--session purrdr-nosuch`) | stdout 空、exit 1,stderr 是 Rust 的 Debug 格式，系統訊息依 Windows 語系在地化(UTF-8):`Error: Custom { kind: NotFound, error: "failed to connect to remote Herdr API socket C:\\Users\\demo\\AppData\\Roaming\\herdr\\sessions\\purrdr-nosuch\\herdr.sock: 系統找不到指定的檔案。 (os error 2)" }` |
| `events.subscribe`,stdin 開著 | ack `{"id":"purrdr:events.subscribe","result":{"type":"subscription_started"}}`;建立／關閉 workspace 時收到 `{"data":{"type":"workspace_created",…},"event":"workspace_created"}`、`{"data":{"type":"workspace_closed",…,"workspace_id":"w2"},"event":"workspace_closed"}`。關 stdin 後 0.1–0.4 s 結束 |
| `events.subscribe`,寫完立刻 EOF | **沒有任何輸出**(macOS 會先回 ack) |

- `ping` 的 `capabilities` 在 Windows 上:`live_handoff:false`、`ssh_agent_registration:false`(作者 Mac 的 0.9.5 兩者都是 `true`)。
- `herdr status server` 的 socket 是 `C:\Users\<帳號>\AppData\Roaming\herdr\herdr.sock`;具名 session 在 `…\herdr\sessions\<名稱>\herdr.sock`。
- 【推論】herdrchat 記錄的「0.9.3 在 Git Bash 下 bridge 通過 check 但不回應」(行為規格 §3.3),最可能的原因就是上面的 EOF 行為:它的傳輸層沒辦法讓 exec 的 stdin 保持開啟(才會有 FIFO + sleep 的繞路),而 Windows 的 bridge 一遇到 EOF 就放棄。0.9.3 沒有實測。

## `terminal session control` 的行為【實測】

只在 0.9.5 server 測(開始測 session control 時 server 已經是 0.9.5)。全部以 40×12 錄製(observer 30×8、接管方 50×14)。

| 項目 | Windows | 和 macOS 比 |
|---|---|---|
| 訊息格式 | `terminal.frame`(`bytes`/`encoding`/`full`/`height`/`seq`/`type`/`width`,欄位依字母排序)、`terminal.closed` | 相同 |
| 每個 frame 的包裝 | `ESC[?2026h`、`ESC[?25l`、`ESC]8;;ESC\` … `ESC[?2026l`;出現過的 `ESC[?` 只有 `?2026h/l`、`?25h/l` | 相同 |
| 第一個 frame | 啟動後 1.1–1.8 s(含 SSH 連線;PowerShell 包裝多約 0.4–0.7 s),`full:true` | 同(macOS 本機 13–220 ms,不含 SSH) |
| 按鍵 → 畫面出現該字元 | p50 97.8 ms、p90 150.7 ms(n=40);同時段網路 ping 平均 81.5 ms | 【推論】扣掉網路來回，herdr 端仍約一個 render 週期 |
| resize | 每次回新尺寸的 full frame;pane 內 `$Host.UI.RawUI.WindowSize` 依序回 `40 12`、`60 15`、`30 10` | 相同。**但** ConPTY 縮小時會重排舊內容，畫面可能留下片段(錄製裡的 `Heights\Temp>`) |
| Unicode 與顏色 | 中文逐字絕對定位(`ESC[6;1H`、SGR、`中ESC[6;3H文`)、`e` + U+0301 同一格、🙂 正常;`Write-Host -ForegroundColor Red` → `ESC[0;38;5;9;49m`,PSReadLine 的語法上色也是 256 色索引 | 相同 |
| 無效輸入 | stderr 警告與 macOS 逐字相同(`terminal.resize cols and rows must be greater than 0`、`expected ident at line 1 column 2`、`unknown variant`、`accepts text or bytes, not both`),之後的 `Write-Output still-alive` 正常執行 | 相同 |
| release／stdin EOF | `{"reason":"detached","type":"terminal.closed"}`,70–80 ms;Git Bash 與 PowerShell 包裝都一樣 | 相同 |
| 捲動與滑鼠(一般 PowerShell shell) | `terminal.scroll` wheel 上 5 → 捲 herdr 主機端 scrollback(畫面從 `50…60` 變成 `45…56`);`terminal.mouse` 被丟棄，沒有 frame | 相同 |
| 已有 controller 再開 control | `terminal attach failed: terminal term_0000000000d001 already has an attached client; retry with --takeover`,exit 0;這次失敗的嘗試讓原 controller 也收到一個 full frame | 相同 |
| `--takeover` | 接管方立刻收到兩個 full frame;原 controller 收到 `terminal attach taken over`、stdout EOF,之後寫 stdin 是 broken pipe;observer 收到的 6 個 frame 全是 full(擁有權變動時);observer 關 stdin 不會結束 | 相同 |
| target 不存在 | `terminal session control failed: terminal target w9:p9 not found`(observe 為 `terminal session observe failed: …`),exit 0 | 相同 |
| pane 內 `exit` | controller 與 observer 都在約 100 ms 內收到 `terminal term_0000000000d002 exited` | 相同 |
| 1.1 MiB 單則輸入 | 約 0.8 s 後 stdout EOF,**沒有** `terminal.closed`,exit 0 | 相同 |
| SSH client 被殺(Mac 端 SIGKILL `ssh`) | 1 秒內主機上的 `herdr terminal session control` 程序就不見了，擁有權釋放;不帶 `--takeover` 重開直接成功。Git Bash 與 PowerShell 包裝都一樣 | macOS 只測過殺 herdr 本身，沒測 SSH |
| observer 的 SSH client 被殺 | **`herdr terminal session observe` 程序留在主機上**(+2 s、+8 s 都還在),直到 pane 重畫、stdout 寫入失敗才結束 | 【文件】「On Linux and macOS, an observer is disconnected if a socket write makes no progress for 30 seconds … Quiet panes do not trigger this timeout」(`cli-reference.mdx:400-402`):Windows 沒有這個逾時，安靜的 pane 會讓它一直留著 |

## 和 macOS 的差異總表

| 項目 | macOS | Windows |
|---|---|---|
| 指令外殼 | POSIX sh,PATH 前綴 | 預設 shell 可能是 Git Bash、cmd 或 PowerShell。Git Bash 下 POSIX 字串原樣可用;cmd/PowerShell 要 `-EncodedCommand` |
| 作業系統偵測 | `uname -s` → `Darwin`/`Linux` | Git Bash 回 `MINGW64_NT-<版本>`;cmd/PowerShell 沒有 `uname` |
| bridge 遇到 stdin EOF | 立即回覆的請求(`ping`)仍會回;訂閱回 ack 後結束 | **什麼都不回** |
| 每個請求的主機端成本 | herdr 啟動 | herdr 啟動 + PowerShell 0.6–0.8 s(若用 `-EncodedCommand`) |
| 連不到 socket 的 stderr | `failed to connect to remote Herdr API socket …` | 同一句，但包在 `Error: Custom { kind: NotFound, error: "…" }` 裡，路徑反斜線跳脫、系統訊息在地化 |
| `ping` 的 capabilities | `live_handoff:true` | `live_handoff:false`、`ssh_agent_registration:false` |
| session control wire format、`closed` 原因、輸入上限 | — | 相同 |
| observer 殘留 | 30 秒寫不出去會斷 | 沒有逾時，要等下一次寫入失敗 |
| 終端機後端 | Unix PTY | ConPTY(resize 重排可能留殘影;游標與 IME 的已知問題見 `windows-beta.mdx:100-121`) |
| 更新 herdr | `herdr update --handoff` 可接手執行中的 server | 不支援 live handoff;更新後要重啟 server 才會換版(`windows-beta.mdx:150`) |
| herdr 安裝位置 | `~/.local/bin/herdr` 等 | `%USERPROFILE%\.herdr\packages\standalone\releases\<版本>`,另有 `%LOCALAPPDATA%\Programs\Herdr\bin` 相容別名(`windows-beta.mdx:24`) |

## 給 #26(Windows 支援)的待辦

1. **作業系統偵測**:`HostProbe` 要把 `MINGW64_NT-*`/`MSYS_NT-*` 認成 Windows(Git Bash);預設 shell 是 cmd/PowerShell 時 `uname` 不存在，要先試行為規格 §3.9 的 Windows 探測。偵測結果決定之後用哪種指令方言。
2. **指令方言**:`HerdrCommand` 加 Windows 版本——預設 shell 是 Git Bash 時，現在的 POSIX 字串可用;cmd/PowerShell 時包成 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <UTF-16LE base64>`,腳本開頭 `$ProgressPreference='SilentlyContinue'`,以 `& herdr …; exit $LASTEXITCODE` 呼叫(本次實測可用;`Start-Process -NoNewWindow -PassThru` 也可以)。引號用 PowerShell 規則(`'` → `''`),具名 session 照樣放 `--session`。包裝腳本不得往 stdout 印東西(PowerShell 的輸出是 `\r\n`)。
3. **bridge 絕不送 EOF**:Windows 上沒有例外，連 `ping` 都會被放棄。保留現有「讀到第一行才關通道」的規則與測試(`WindowsHostRecordingTests` 的 `closedStdin == false`)。
4. **延遲預算**:PowerShell 包裝每個請求多 0.6–0.8 s。逾時(行為規格 §12)要把它算進去;考慮能用 Git Bash 時優先直接呼叫，或在一個 exec 內批次多個請求(行為規格 §3.3「通道數」)。
5. **連不到 socket**:現有判斷是「stderr 含 `failed to connect to remote Herdr API socket`」,Windows 的 Rust Debug 格式也命中(有測試守著)。顯示給使用者的訊息要考慮反斜線跳脫與在地化的系統訊息。
6. **Pane 終端機**:`terminal session control` 不用改協定;只要指令走 Windows 方言。observer 若要用，必須確保通道關閉時主機上的程序會結束(Windows 沒有寫入逾時)——建議 Windows 上只用 control,或另外清理。
7. **ConPTY 畫面**:resize 後的殘影是 ConPTY 的行為【推論】,app 端不必修正;resize 去抖(macOS 筆記「對 #20 的要求」第 7 點)在 Windows 更重要。
8. **更新 herdr**:`ping` 回 `live_handoff:false` 時不要走 `update --handoff`/`server.live_handoff`,改提示「更新後請在主機上重啟 herdr server」(行為規格 §11.1)。
9. **安裝位置與 PATH**:預設 shell 是 PowerShell/cmd 時 PATH 是否包含 herdr 的 release 目錄未實測;找不到時可試 `%LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe`(文件寫的相容別名)。
10. **登入 Shell**:Windows 的預設 shell 可能是 Git Bash(本機)、cmd 或 PowerShell,`exec "${SHELL:-/bin/sh}" -l` 的作法要換(行為規格 §11.1)。不在本次範圍。
11. **未驗證、#26 要補測**:預設 shell 真的是 cmd 或 PowerShell 的主機;以系統管理員權限跑的 server(文件:一般 client 預設連不上，`windows-beta.mdx:52`);vim/less 等滑鼠回報與 alternate screen 程式在 ConPTY 下的 `terminal.scroll`/`terminal.mouse`;agent TUI。

## 限制與未驗證

- 實測機只有一台，預設 shell 是 Git Bash;cmd 只以 `cmd.exe //c` 模擬。
- session control 只在 0.9.5 server 測;bridge 在 0.9.4 與 0.9.5 都測。
- 延遲數據含 Tailscale 網路(平均 81.5 ms ping),樣本小(n=40)。按鍵延遲的比對方法是「frame 解開後含該字元」,最小值 0.1 ms 是誤判(字元剛好出現在前一個 frame 的跳脫序列裡),p50/p90 不受影響。
- 沒有測 herdr 0.9.3,herdrchat 那筆紀錄的原因是推論。

## Fixture

完整錄製在 `docs/research/fixtures/windows/`,格式同 macOS 筆記:`<名稱>.stdout.ndjson`(herdr stdout 原樣)、`.stdin.ndjson`(我們送的行)、`.transcript.ndjson`(時間序 `{"t_ms","dir","line"}`)、`.stderr.txt`。

- `bridge/0.9.4/`、`bridge/0.9.5/`:`gb-*` 是 Git Bash 直接呼叫,`ps-*` 是 PowerShell `-EncodedCommand`(`ps-start-*` 是 `Start-Process` 形式),`cmd-ps-*` 是經 cmd;`*-open` 為 stdin 保持開著、`*-eof` 為寫完立刻 EOF。另有 `sub-workspace-created`(0.9.4)/`sub-workspace-closed`(0.9.5)、`utf8-gb/ps/pwsh`(中文名稱的 `workspace.get`)、`posix-*`(app 現有指令字串原樣)。
- `session-control/`:`01`(`01ps` 為 PowerShell 包裝)handshake、回顯、release;`02` resize;`03` 捲動與滑鼠;`06-takeover-A/B/C/observer`;`07` Unicode 與顏色;`09` 無效輸入;`10`/`10ps` 關 stdin;`11` 超大輸入(stdin 以摘要取代);`12-kill-gb/ps-reattach-1s` SSH client 被殺後重開;`13`/`13ps` target 不存在(control 與 observe);`14-exited-control/observer`。

測試用的子集合在 `tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/windows/`(見該處 `README.md`)。

去識別化:帳號、主機名換成 `demo`/`DEMO-PC`,測試 pane 的 terminal id 換成 `term_0000000000d001`、`term_0000000000d002`(已刪除的 pane)。畫面裡只有 `C:\Windows\Temp` 的 PowerShell prompt 與測試指令。匯出時以帳號、主機名、tailnet 位址、使用者 workspace 名稱與專案名稱的樣式檢查過所有文字與 base64 解開後的 frame,沒有命中。

重新錄製：在實測機建一個專用 workspace(`herdr workspace create --no-focus --label purrdr-spike`),把 `sc_tests.py` 等腳本裡的 pane id 換成它的，設 `PURRDR_WIN_SSH` 後執行，再以 `export.py` 匯出(用法見檔頭)。測完 `herdr workspace close` 並確認 `workspace get` 回 `workspace_not_found`。
