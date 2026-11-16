# Purrdr Plus 訂閱設定(#36)

App Store Connect → App → 營利 → 訂閱。商品 ID、期間、試用、Offer Code 與 `src/App/Purrdr.storekit` 相同，由 `StoreKitConfigurationTests` 檢查設定檔
(商品 ID 等於 app 的 `MemberSubscription.productIDs`;後台的 `PLUS_PRODUCT_IDS` 在 `backend/src/subscriptions.ts`)。**ID 建立後不能改**,改了要三處同步。

## 訂閱群組

| 欄位 | 值 |
|---|---|
| 參考名稱 | Purrdr Plus |
| 顯示名稱(English) | Purrdr Plus |
| 顯示名稱(繁體中文) | Purrdr Plus |
| 方案層級 | 月繳與年繳放**同一層級**(等級 1,已用 App Store Connect API 設定;與設定檔的 `groupNumber` 都是 1 一致):互換時於下個續訂日生效，不按比例退款 |

App 名稱的在地化(群組的「App 名稱」欄)選「使用 App 名稱」。

## 商品

| | 月繳 | 年繳 |
|---|---|---|
| 參考名稱(App Store Connect) | Purrdr Plus 月繳 | Purrdr Plus 年繳 |
| 商品 ID | `com.raychiu.purrdr.plus.monthly` | `com.raychiu.purrdr.plus.yearly` |
| 期間 | 1 個月 | 1 年 |
| 價格(美國) | US$4.99 | US$39.99 |
| 其他地區 | 依美國價格由 Apple 自動換算(建立後在「價格」頁檢查台灣等主要地區) | 同左 |
| 家人共享 | 關閉(設定檔 `familyShareable: false`;權限綁會員，家人共享無從對應會員) | 同左 |
| 推介優惠(Introductory Offer) | 免費試用 2 週，所有地區，新訂閱者 | 同左 |

### 在地化(商品頁的「App Store 在地化」)

顯示名稱上限 30 字元、描述上限 45 字元(字數以 Python `len()` 算過)。

| 語言 | 月繳 顯示名稱 | 年繳 顯示名稱 | 描述(兩者相同) |
|---|---|---|---|
| English (U.S.) | Purrdr Plus Monthly | Purrdr Plus Yearly | Know when agents need you. Sync your hosts.(43) |
| 繁體中文 | Purrdr Plus 月繳(14) | Purrdr Plus 年繳(14) | Agent 需要你時通知，並在裝置間同步主機(22) |

英文顯示名稱與設定檔、UI 測試替身(`UITestingPlusStore`)相同。設定檔的描述較長(「Notifications when an agent needs you, and host sync across your devices.」),
只在 Xcode 本機測試用，不受 45 字元限制;意思一致即可。

### 審查資訊

每個商品各附一張付費牆截圖(`PlusUITests` 打開的畫面)與審查備註(內容同 `review-notes.md` 的「訂閱」一節)。
第一次送審時，兩個商品要跟 app 版本**一起**送(在版本頁的「App 內購買項目與訂閱」勾選)。

## Offer Code

| 欄位 | 值 |
|---|---|
| 參考名稱 | 早期測試 1 個月免費(與設定檔相同) |
| 商品 | 月繳(`com.raychiu.purrdr.plus.monthly`) |
| 優惠 | 免費 1 個月 |
| 資格 | 僅限新訂閱者(設定檔 `eligibility: ["new"]`) |
| 與試用疊加 | 不疊加:用 Offer Code 的新訂閱者拿 1 個月免費，不再加 2 週試用(設定檔 `isStackable: false`,`StoreKitConfigurationTests` 守住) |
| 類型與數量 | 一次性代碼，100 組;**要等訂閱商品審查通過後才能產生**(Offer 本身已建立) |
| 地區 | app 的所有供應地區(147 個，見 `app-store-metadata.md`「供應地區」) |
| 到期日 | 由人工決定(依 App Store Connect 的上限) |

兌換方式：app 的「Purrdr Plus → Redeem Code」(登入會員後，系統兌換畫面),或 App Store 的兌換連結。
在 App Store 兌換的交易沒有 `appAccountToken`,打開 app 登入後由交易更新送到後台，歸登入的會員(`backend/README.md`「訂閱歸屬」)。
不用自訂授權碼(審查規範 3.1.1)。

## 其他要在 App Store Connect 設定的

- **App Store 伺服器通知**:Production 與 Sandbox 都填 `https://<後台網址>/v1/app-store/notifications`,Version 2(`backend/README.md`)。
- **App 內購買項目的稅務、銀行與合約**:「付費 App」合約要生效才能賣訂閱與 sandbox 測試。
