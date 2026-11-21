# SSH 用 apple/swift-nio-ssh,不支援 RSA 金鑰

選 Apple 官方的 swift-nio-ssh,不選 herdrchat 用的 Citadel。swift-nio-ssh 原生支援在同一個 channel 上同時開 PTY 與執行指令，支援 Tailscale SSH 需要的 `none` 認證，還能使用 Secure Enclave P256 金鑰;Citadel 只在開 login shell 時給 PTY,而且依賴個人 fork 的 swift-nio-ssh。代價是 swift-nio-ssh 不支援 RSA 金鑰，也沒有 SFTP,所以只支援 ed25519、ECDSA、Secure Enclave 金鑰與密碼登入，檔案上傳改走 exec 的 stdin。

後來上傳加了傳輸編碼(#76:`identity`／`gzip` 與傳輸大小是上傳指令的參數)。接收的腳本每次隨指令送出、主機上不安裝(ADR-0002),所以編碼不是難以逆轉的協定：改格式只要 app 與腳本一起改。要承擔的是依賴主機的解壓工具(POSIX 的 `gzip`、Windows 的 .NET `GZipStream`),沒有時退回 `identity`。

後來主機身分確認改了(#343,spec #332):host key 驗證仍由 `HostKeyVerifier` 只接受與 pin 相同的 key、沒有 pin 時不登入,選 swift-nio-ssh 的前提不變;改的是上層怎麼處理「沒有 pin」。OpenSSH 第一次連線只問信任或取消(指紋收進詳細資訊);Tailscale SSH 由 tailnet 身分保證,第一次出示的 key 自動記成 pin、不問。指紋之後變了一律擋下,沒有「信任新的 key」,要重新連得刪掉主機再新增。
