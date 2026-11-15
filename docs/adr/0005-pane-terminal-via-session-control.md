# Pane 終端機全平台統一走 `herdr terminal session control`

herdr 在原生 Windows 不支援 direct attach(`herdr agent attach`／`herdr terminal attach` 回「direct terminal attach is not supported on Windows yet」,herdr `src/client/startup.rs:17-24`),所以 Windows 主機的 Pane 終端機只能走 `terminal session control`(NDJSON 畫面更新與輸入，不需要 PTY)。macOS、Linux 雖然可以用 PTY 加 `attach`,我們仍然全平台統一走 `control`,只維護、只測一條路。登入 Shell 不受影響，仍然用 PTY。

## Consequences

- `control` 沒有在其他 app 的正式環境驗證過，實作第一步是在 macOS 與 Windows 實測的 spike;spike 失敗時重新評估 macOS／Linux 改回 `attach`。
- herdrchat 為了 PTY 做的各種處理(login shell 繞路、rc 檔自動啟動 tmux 的問題)對 Pane 終端機不適用。
