# SSH 用 apple/swift-nio-ssh,不支援 RSA 金鑰

選 Apple 官方的 swift-nio-ssh,不選 herdrchat 用的 Citadel。swift-nio-ssh 原生支援在同一個 channel 上同時開 PTY 與執行指令，支援 Tailscale SSH 需要的 `none` 認證，還能使用 Secure Enclave P256 金鑰;Citadel 只在開 login shell 時給 PTY,而且依賴個人 fork 的 swift-nio-ssh。代價是 swift-nio-ssh 不支援 RSA 金鑰，也沒有 SFTP,所以只支援 ed25519、ECDSA、Secure Enclave 金鑰與密碼登入，檔案上傳改走 exec 的 stdin。

後來上傳加了傳輸編碼(#76:`identity`／`gzip` 與傳輸大小是上傳指令的參數)。接收的腳本每次隨指令送出、主機上不安裝(ADR-0002),所以編碼不是難以逆轉的協定：改格式只要 app 與腳本一起改。要承擔的是依賴主機的解壓工具(POSIX 的 `gzip`、Windows 的 .NET `GZipStream`),沒有時退回 `identity`。
