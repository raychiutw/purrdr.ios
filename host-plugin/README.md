# purrdr-host-plugin

Purrdr 的主機外掛：裝在主機的 [herdr](https://herdr.dev) 上，Agent 進入「需要你」(blocked)時，通知 Purrdr 後台推播到配對的 iPhone／iPad。

- 通常不需要手動安裝：在 Purrdr app 對主機打開推播時，app 會經 SSH 執行 `herdr plugin install raychiutw/purrdr-host-plugin --yes`,並寫入配對資料;關閉推播時移除。
- 配對資料在 `~/.purrdr/push-<裝置>/pairing`(每支配對的裝置一個資料夾，只有本人可讀)。
- 推播只帶 workspace 名稱、狀態與 pane id,**不帶任何對話內容**;推播的文字由 Purrdr 後台組成。配對密鑰只在主機與 app 上，後台只保存它的雜湊。
- macOS／Linux 用 `sh` + `curl`(`notify.sh`);Windows 用 PowerShell(`notify.ps1`)。herdr 的 plugin 在 Windows 仍是 preview,Windows 推播是 best-effort。
- 沒有常駐程序：herdr 在 `pane.agent_status_changed` 時才執行腳本，執行完就結束。

## 檔案

| 檔案 | 用途 |
|---|---|
| `herdr-plugin.toml` | herdr plugin manifest(id `purrdr.push`) |
| `notify.sh` | macOS／Linux 的事件 hook |
| `notify.ps1` | Windows 的事件 hook(best-effort) |

開發與測試在 Purrdr 的 app repo(`host-plugin/`,測試是 `tests/PurrdrCoreTests/HostPluginScriptTests.swift`);這個公開 repo 是它的發佈版本。
