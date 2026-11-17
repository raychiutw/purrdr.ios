# host-poll-repro

主機並行輪詢的回歸工具(#86、#91):以可攜核心(PurrdrCore + PurrdrSSH)連真主機，2 個事件訂閱旁邊，4 個畫面同時照 app 的順序輪詢(snapshot → 讀畫面 → 定位 → 視窗 → 追蹤)。每一步有上限，取消後仍不返回記為 HUNG(RED)。只執行唯讀指令。

用法見 `run.sh` 開頭;Windows 開發機在 WSL 裡跑(Docker 在 WSL,容器連本機要用 Tailscale IP)。

## 紀錄

連 Windows 主機(Ray PC,預設 shell 是 Git Bash),2026-11-17,`run.sh 6`(每次 2 個訂閱 + 4 個畫面、`STEP_LIMIT=45`、`CANCEL_GRACE=2`)。

### 紅：`master` 舊版(`a47d450`,#77 之前，一次性指令沒有期限入口)

6 次有 5 次 RED,每次都是某一步超過上限、取消後也不返回(HUNG):

| 次 | 結果 | 卡住的步驟 |
|----|------|-----------|
| 1 | RED hung=1 | 追蹤 w3:p2(47.0s) |
| 2 | RED hung=1 | 定位 w3:p2(47.0s) |
| 3 | GREEN | — |
| 4 | RED hung=1 | 定位 w3:p4(47.0s) |
| 5 | RED hung=1 | 追蹤 w3:p1(47.0s) |
| 6 | RED hung=3 | 追蹤 w3:p1、追蹤 w3:p4、視窗 w3:p5(3,503,697 B),各 47.0s |

節錄(第 1 次):

```text
WATCHDOG 已等 42 秒：追蹤 w3:p2
  追蹤 w3:p2 @7.9 47.0s HUNG(取消後 2 秒內沒有返回)
RED failures=0 hung=1
```

紅燈留下 7 個卡住的 `powershell.exe`(父程序 sshd 已結束，時間與 7 個 HUNG 吻合),已逐一以 PID 結束。

### 綠：#91 分支

同樣條件 6 次全部 GREEN。
