# Tailscale SSH check mode:SSH client 看到什麼、要怎麼等

> 目的:#9 實作「重新驗證」所需的事實。行為規格 §13 第 4 點列為「需在真機測」。
>
> 標記:**【文件】** = Tailscale 官方 KB;**【原始碼】** = Tailscale 開源程式碼(github.com/tailscale/tailscale `ssh/tailssh/tailssh.go`,2026-11-16 取用 main);**【社群】** = 使用者回報，只當線索;**【推論】** = 由前者推得、未實測。

## 結論

1. 【文件】ACL 的 SSH 規則 `action: "check"` 要求連線端在 check period 內重新驗證(預設 12 小時，可設 1 分鐘～168 小時或 `always`)。「SSH 初始化時會提供一個登入網址」,在瀏覽器登入(可能觸發 IdP 的 MFA)。只套用在 Tailscale SSH。— https://tailscale.com/kb/1193/tailscale-ssh
2. 【原始碼】網址經 **SSH 認證橫幅**(SSH_MSG_USERAUTH_BANNER,`c.spac.SendAuthBanner(action.Message)`)在**認證階段**送出;不是 keyboard-interactive,也不是 session 的 stderr。伺服器沒有 `KeyboardInteractiveCallback`;`none`、`password`、`publickey` 都走同一個 `clientAuth`,所以用 `none` 認證也會遇到。
3. 【原始碼】送出橫幅後，伺服器**不回覆認證結果**,向控制端取下一步(`fetchSSHAction`,上限 `delegateFetchTimeout = 30 * time.Minute`,失敗以 backoff 重試),並把登入寬限延長到 `holdDelegateGrace`(30 + 5 分鐘;平常 120 秒)。使用者驗證完 → 認證成功、連線照常繼續;被拒 → 認證失敗。
4. 【原始碼】橫幅內容是控制端給的 `action.Message`,**沒有固定格式**。【社群】實際看到的文字是「`# Tailscale SSH requires an additional check.`」加「`# To authenticate, visit: https://login.tailscale.com/a/…`」(forum.tailscale.com/t/lot-auth-request-on-tailscale-shh-on-wsl/4539;Headscale 的 check 實作也用幾乎相同的句子)。
5. 【推論】連線關閉時(`closeConn` → `preAuthCancel`)伺服器放棄等待。驗證本身是對「這個節點／使用者」記錄 check period,所以 app 在背景被系統關掉 socket 後，重新連線多半不會再要求驗證;若仍在等，會拿到新的網址。

## 對實作的決定

- 只認「提到 authenticate 且帶 https 網址」的認證橫幅(`TailscaleCheck.authenticationURL(inBanner:)`),一般登入橫幅即使帶網址也不算;只開 https。
- 收到網址後把握手期限(15 秒)換成 `SSHTimeouts.tailscaleCheck`(30 分鐘，與伺服器一致),並經 `TailscaleCheckObserver` 回報提示;認證成功後等待中的指令自動繼續(這就是「驗證後自動重試」:不用使用者再操作)。
- 等待時連線斷了 → 重新撥號(還沒登入、指令沒送出，不違反「連線層失敗不重送」);被拒、逾時、使用者取消 → 不重撥。
- 使用者可取消：關掉這條連線，等待中的指令得到 `SSHConnectionError.tailscaleCheckCancelled`。

## 未實測

- 作者的 Mac 無法用 Tailscale SSH 連自己的 tailnet IP,且不得變更作者的 ACL,所以**沒有真機錄到 check mode**。`tests/PurrdrTestSupport/Fixtures/tailscale/check-mode.banner.txt` 依上面第 4 點模擬;測試用 SSH 伺服器依第 2、3 點模擬(送橫幅、延後放行／拒絕／斷線)。
- 要驗證：從 iPhone 實機連一台 ACL 為 `check` 的主機，確認橫幅文字、網址開啟後回到 app 時連線是否仍在、以及重撥時是否會再要求驗證。
