# 推播：主機上的 herdr plugin 通知自營 relay

app 在背景時 iOS 會切斷 SSH,所以「Agent 需要你」只能由主機主動通知。因為要上架 App Store,APNs 金鑰不能放在使用者的主機上，所以由我們營運的 Drover 後台(Cloudflare Worker)，保管 APNs 金鑰;主機端則透過 herdr 官方的 plugin 機制，在 Agent 狀態改變時通知後台。推播內容只放 workspace 名稱與狀態，不放對話內容。推播是選用功能;herdr 的 plugin 在 Windows 上仍是 preview,所以 Windows 主機的推播只做 best-effort。

## 配對方式

使用者在 app 裡對某台主機開啟推播時,app 透過 SSH 安裝主機外掛，並寫入一組隨機的配對密鑰;推播後台只保存「配對密鑰 → APNs token」的對應。關閉推播時,app 會移除主機上的外掛與設定。

## 後台的驗證

app 產生 32 bytes 隨機配對密鑰，向後台註冊時只送密鑰的雜湊、APNs token 與平台;主機外掛送推播時帶密鑰，後台比對雜湊。每組密鑰有速率限制，關閉推播時撤銷。後台不保存能回推到使用者身分的資料。註冊與推播的 API 不綁平台，這次只實作 APNs,Android 之後加 FCM。

後來加入會員與訂閱(ADR-0007):推播配對要求會員具有有效訂閱，後台發送前會檢查權限。
