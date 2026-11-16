# 上架前人工步驟(#36)

「誰做」:**主 session** = 有帳號權限的人／agent(Apple Developer、App Store Connect、GitHub、Cloudflare);**本 repo** = 已在 repo 內完成的程式與文件。
狀態:✅ 完成、⬜ 待做、⚠️ 需要決定。最後更新:2026-11-16。

後台金鑰與網址的細項見 `backend/README.md`「上線前要填的東西」;訂閱見 `subscriptions.md`;中繼資料見 `app-store-metadata.md`。

## 1. Apple Developer 與 App Store Connect

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 1.1 | 註冊 App ID `com.raychiu.purrdr`,勾 Push Notifications、Time Sensitive Notifications、Sign in with Apple、In-App Purchase | 主 session | ✅ |
| 1.2 | App Store Connect 建立 app「Purrdr: Agent Chat」,主要語言 English (U.S.);Apple ID `6835416115` | 主 session | ✅ |
| 1.3 | App Store id 填進 app(`PurrdrLinks.appStoreID`)與後台(`APP_STORE_APP_APPLE_ID`);評分連結 `https://apps.apple.com/app/id6835416115?action=write-review` 由 `AppStoreLinkTests` 核對 | 本 repo | ✅ |
| 1.4 | 建立 Admin 角色的 App Store Connect team API key(或沿用 my-money.ios 的那把);`.p8` 不進 repo | 主 session | ⬜ |
| 1.5 | 「付費 App」合約、稅務、銀行資料生效(賣訂閱與 sandbox 測試的前提) | 主 session | ⬜ |
| 1.6 | 建立訂閱群組「Purrdr Plus」與兩個商品、2 週試用、在地化、審查截圖(`subscriptions.md`) | 主 session | ⬜ |
| 1.7 | 建立 Offer Code:月繳 1 個月免費、限新訂閱者、一次性代碼 100 組(`subscriptions.md`);到期日 | 主 session | ⬜ ⚠️ 到期日待定 |
| 1.8 | App Store Server Notifications:Production 與 Sandbox 都填 `https://<後台網址>/v1/app-store/notifications`,Version 2 | 主 session | ⬜(等 3.1 部署) |
| 1.9 | App 資訊：類別(開發者工具／生產力工具)、隱私權政策網址、授權合約用 Apple 標準 EULA | 主 session | ⬜ |
| 1.10 | 年齡分級問卷 | 主 session | ⬜ ⚠️ Agent 與終端機會顯示主機上任意文字，依問卷如實回答 |
| 1.11 | App 隱私：照 `privacy-labels.md` 逐題填 | 主 session | ⬜ |
| 1.12 | 中繼資料(英文、繁中)、截圖(6.9 吋 iPhone、13 吋 iPad,`scripts/screenshots.sh`) | 主 session | ⬜ |
| 1.13 | 審查資訊：備註貼 `review-notes.md` 的英文段落、勾「不需要登入」、聯絡資訊 | 主 session | ⬜ |
| 1.14 | 出口合規：專案已設 `ITSAppUsesNonExemptEncryption = NO`(上傳後不再逐 build 詢問)。App 有 SSH(swift-nio-ssh、swift-crypto)與 HTTPS;確認「只用標準加密、屬豁免」的判斷 | 主 session | ⚠️ 需人工確認 |

## 2. TestFlight CI

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 2.1 | `.github/workflows/testflight.yml`、`.github/ExportOptions.plist`、`scripts/wait-for-testflight.rb`(合併進 `master` 自動上傳，可 `workflow_dispatch`) | 本 repo | ✅ |
| 2.2 | GitHub environment `testflight`,部署分支限定 `master` | 主 session | ⬜ |
| 2.3 | environment 變數 `APPLE_TEAM_ID` = `8Z6WVFJ574`;secret `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`(`.p8` 全文;與 my-money.ios 相同) | 主 session | ⬜ |
| 2.4 | 發版前遞增 `MARKETING_VERSION`(專案 4 處;每次上傳都要比上一版大) | 主 session | ⬜ |
| 2.5 | 第一次上傳後：確認 Apple 沒寄 ITMS-91053(privacy manifest 缺 required reason API)等警告信;有就補 `src/App/Purrdr/PrivacyInfo.xcprivacy` | 主 session | ⬜ |
| 2.6 | TestFlight 內部群組「內部測試」,開啟自動分發，加入測試者 | 主 session | ⬜ |
| 2.7 | 驗收:TestFlight 能從 CI 收到 build(`wait-for-testflight.rb` 回報 ready for internal testing) | 主 session | ⬜ |

## 3. 後台(Cloudflare)

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 3.1 | D1 建立與 migration、Worker 部署 | 主 session | ⬜ |
| 3.2 | Sign in with Apple key、APNs key、存取權杖密鑰、Apple Root CA - G3、Google OAuth client(`backend/README.md`) | 主 session | ⬜ |
| 3.3 | app 的 `BackendConfiguration.baseURL`、`googleClientID` 換成真值(`src/App/Purrdr/BackendConfiguration.swift`) | 主 session | ⬜ |
| 3.4 | 發佈主機外掛公開 repo `raychiutw/purrdr-host-plugin`(本 repo 的 `host-plugin/`) | 主 session | ⬜ |

## 4. 網站(`raychiutw.github.io/purrdr/`)

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 4.1 | 網頁草稿 `docs/site/purrdr/`(首頁、`privacy/`、`support/`、`style.css`),純靜態、無外部資源 | 本 repo | ✅ |
| 4.2 | 把 `REPLACE_ME@example.com`(隱私權政策、支援頁、`review-notes.md`)換成正式聯絡信箱 | 主 session | ⬜ |
| 4.3 | 複製到 `raychiutw/raychiutw.github.io` 的 `purrdr/` 資料夾並發佈;確認 `https://raychiutw.github.io/purrdr/privacy/` 與 `/support/` 打得開(app 的 `PurrdrLinks` 已指向這兩個網址) | 主 session | ⬜ |
| 4.4 | 隱私權政策的生效日期改成實際發佈日 | 主 session | ⬜ |

## 5. 送審

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 5.1 | 依 `review-notes.md`「送審前的前提」逐項確認(後台、商品、通知網址、網站、信箱) | 主 session | ⬜ |
| 5.2 | 以送審 build 跑 `scripts/screenshots.sh`,核對 `review-notes.md` 的 Demo 描述(#36 驗收條件) | 主 session | ⬜ |
| 5.3 | Sandbox 帳號在 TestFlight build 實測：登入、試用購買、恢復購買、兌換 Offer Code、刪除會員 | 主 session | ⬜ |
| 5.4 | 版本頁勾選兩個訂閱商品一起送審，提交 | 主 session | ⬜ |

## repo 裡仍是佔位的值

| 值 | 位置 | 屬於 |
|---|---|---|
| `REPLACE_ME@example.com` | `docs/site/purrdr/privacy/`、`support/`、`docs/launch/review-notes.md` | 4.2 |
| `https://purrdr-backend.REPLACE-ME.workers.dev` | `src/App/Purrdr/BackendConfiguration.swift`(`baseURL`) | 3.3 |
| `REPLACE-ME.apps.googleusercontent.com` | `src/App/Purrdr/BackendConfiguration.swift`(`googleClientID`) | 3.3 |
| `REPLACE_ME_D1_DATABASE_ID` | `backend/wrangler.jsonc` | 3.1 |
| `REPLACE_ME_APPLE_KEY_ID` | `backend/wrangler.jsonc` | 3.2 |
| `REPLACE_ME.apps.googleusercontent.com` | `backend/wrangler.jsonc`(`GOOGLE_CLIENT_IDS`) | 3.2 |
| `REPLACE_ME_APPLE_ROOT_CA_G3_BASE64` | `backend/wrangler.jsonc` | 3.2 |
| `REPLACE_ME_APNS_KEY_ID` | `backend/wrangler.jsonc` | 3.2 |
