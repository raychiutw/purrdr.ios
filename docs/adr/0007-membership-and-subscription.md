# 會員加自動續訂訂閱，開通推播與主機同步

Drover 後台(推播轉送、主機同步)有持續費用，所以推播與主機同步做成付費的自動續訂訂閱(月繳、年繳，含 2 週免費試用)。依 App Store 審查規範 3.1.1,解鎖功能必須用 In-App Purchase,不得用自訂授權碼或 QR code,所以送人或活動一律用 Apple 的 Offer Code。

StoreKit 本身不需要帳號，但我們仍然加入會員機制:iOS 提供 Sign in with Apple 與 Google 登入(審查規範 4.8:用 Google 登入就必須同時提供符合隱私條件的另一種登入，例如 Sign in with Apple),Android 只提供 Google;不做帳號密碼。登入後可以在設定裡連結另一種登入方式(Apple ↔ Google 雙向),不以 email 自動對應，因為 Sign in with Apple 的隱藏 email 永遠對不上。理由是之後的 Android 版要能共用同一份訂閱，主機清單也要能跨平台同步。購買時以 `appAccountToken` 帶入會員 ID,後台驗證 Apple 的簽章交易並接收 App Store Server Notifications v2 處理到期與退款，權限記在會員身上並記錄來源商店(`app_store`／`google_play`)。

## Consequences

- 只有訂閱功能需要登入，聊天與終端機不需要(審查規範 5.1.1)。
- app 內必須能刪除會員;刪除時清掉會員資料、推播配對、同步資料與權限紀錄，並提醒 Apple 訂閱要使用者自己取消。
- 主機同步由會員主動開啟，後台可讀(TLS 傳輸、Cloudflare 靜態加密，寫進隱私權政策),不做端對端加密;以單一主機為單位最後寫入者勝，刪除留紀錄。私鑰與密碼永不上傳。
- 後台從單純的推播轉送擴大為 Cloudflare Worker + D1,位於主 repo 的 `backend/`。
- 連結登入方式時，若另一種登入已屬於另一個會員：該會員沒有訂閱也沒有同步資料時自動併入並刪除它;否則拒絕並說明，使用者須先登入該會員刪除它。可隨時解除連結，但會員至少保留一種登入方式。

## 更新(2026-11-19):後台搬到 raychiutw/purrdr.server

後台(原本主 repo 的 `backend/`)搬到私人 repo [`raychiutw/purrdr.server`](https://github.com/raychiutw/purrdr.server)(保留歷史),CI 的後台測試也在那裡跑。API 契約與上線前設定見那裡的 `README.md`;後台仍由使用者手動部署。
