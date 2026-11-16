# 主機端零安裝：只靠 SSH 加 herdr 內建指令

app 不需要自己的後端，也不在主機上安裝任何常駐程式。所有操作都透過 SSH 在主機上執行 herdr 內建的指令(包括 0.9.1 起內建的 `herdr remote-api-bridge`),以及讀取 agent 的對話紀錄檔。連線方式支援 Tailscale SSH(作者的 Mac 刻意只接受這種方式)與 OpenSSH(例如 Windows 主機);主機作業系統涵蓋 macOS、Linux、Windows。最低支援 herdr 0.9.5,不為更舊的版本做相容處理。

## 例外

- 推播需要主機外掛，見 ADR-0004。
- HTTPS 連線方式需要主機服務，見 ADR-0010;零安裝只適用於 SSH 連線方式。
- 會寫入主機的功能(Claude 用量的 status line 包裝、Codex 啟動器、主機主題參考檔、「You should know」資料寫回):每台主機個別徵求使用者同意、說明會改什麼，並且可以完整還原。我們自己的檔案一律放在 `~/.drover-chat/`(Windows 為 `%USERPROFILE%\.drover-chat\`)。
- Windows 主機的每個指令都包成 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <base64>`(與 herdr 自己連 Windows 遠端機器的做法相同),不論 OpenSSH 預設 shell 是 cmd 或 PowerShell 都能執行，不要求 Git Bash。
