# 錄製回應(假主機回放用)

假主機(`FakeHost`)回放的主機回應，一律從**真實主機**錄下，不照程式碼手寫。目錄依 herdr 版本分(`herdr-0.9.5/`)。

## 錄製

```bash
scripts/record-herdr-fixture.sh <檔名> <method> [params JSON] [ssh 目的地]
```

腳本經 `herdr remote-api-bridge` 送一行請求(stdin 保持開著 2 秒，不送 EOF),只留第一行回應，並自動把家目錄換成 `/Users/demo`、使用者名稱換成 `demo`、session UUID 換成 `00000000-…-000000000001` 這類假值。

**workspace 名稱、終端機標題、資料夾名稱腳本不會動**:存檔後一定要打開檢查，換成假值，再用 `grep` 確認沒有真實的專案名稱或路徑。

## 清單

| 檔案 | 請求 | 錄製日期 | 用來驗證 |
|---|---|---|---|
| `herdr-0.9.5/session.snapshot.ndjson` | `session.snapshot {}`(作者的 Mac,3 個 Claude Code agent + 1 個 shell pane) | 2026-11-15 | snapshot 解碼、Agent 列表分組 |
| `herdr-0.9.5/error.invalid-request.ndjson` | 格式錯誤的請求(`params` 不是合法 JSON) | 2026-11-15 | herdr 錯誤 envelope 保留錯誤碼與原文 |
| `herdr-0.9.5/session-control/*.stdout.ndjson`、`*.stdin.ndjson` | `herdr terminal session control`／`observe` 的 stdout 原樣與我方送出的 stdin(#4 spike,40×12 乾淨 bash) | 2026-11-15 | Pane 終端機的 frame 解析、`terminal.closed` 分類、輸入格式;情境說明與重錄方式見 `docs/research/terminal-session-control-macos.md`「Fixture」 |
