# SSH 用 apple/swift-nio-ssh,不支援 RSA 金鑰

選 Apple 官方的 swift-nio-ssh,不選 herdrchat 用的 Citadel。swift-nio-ssh 原生支援在同一個 channel 上同時開 PTY 與執行指令，支援 Tailscale SSH 需要的 `none` 認證，還能使用 Secure Enclave P256 金鑰;Citadel 只在開 login shell 時給 PTY,而且依賴個人 fork 的 swift-nio-ssh。代價是 swift-nio-ssh 不支援 RSA 金鑰，也沒有 SFTP,所以只支援 ed25519、ECDSA、Secure Enclave 金鑰與密碼登入，檔案上傳改走 exec 的 stdin。
