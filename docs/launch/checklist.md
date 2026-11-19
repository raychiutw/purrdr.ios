# 上架前人工步驟(#36)

「誰做」:**主 session** = 有帳號權限的人／agent(Apple Developer、App Store Connect、GitHub、Cloudflare);**本 repo** = 已在 repo 內完成的程式與文件。
狀態:✅ 完成、⬜ 待做、⚠️ 需要決定。最後更新:2026-11-19。

後台金鑰與網址的細項見 `raychiutw/purrdr.server` 的 `README.md`「上線前要填的東西」;訂閱見 `subscriptions.md`;中繼資料見 `app-store-metadata.md`。

## 1. Apple Developer 與 App Store Connect

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 1.1 | 註冊 App ID `com.raychiu.purrdr`,勾 Push Notifications、Time Sensitive Notifications、Sign in with Apple、In-App Purchase | 主 session | ✅ |
| 1.2 | App Store Connect 建立 app「Purrdr: Agent Chat」,主要語言 English (U.S.);Apple ID `6835416115` | 主 session | ✅ |
| 1.3 | App Store id 填進 app(`PurrdrLinks.appStoreID`)與後台(`APP_STORE_APP_APPLE_ID`);評分連結 `https://apps.apple.com/app/id6835416115?action=write-review` 由 `AppStoreLinkTests` 核對 | 本 repo | ✅ |
| 1.4 | 建立 Admin 角色的 App Store Connect team API key(或沿用 my-money.ios 的那把);`.p8` 不進 repo | 主 session | ✅ |
| 1.5 | 「付費 App」合約、稅務、銀行資料生效(賣訂閱與 sandbox 測試的前提) | 主 session | ⬜ |
| 1.6 | 建立訂閱群組「Purrdr Plus」與兩個商品(參考名稱「Purrdr Plus 月繳」「Purrdr Plus 年繳」,同為等級 1)、2 週試用、在地化(`subscriptions.md`) | 主 session | ✅(審查截圖隨送審附上) |
| 1.7 | 建立 Offer Code「早期測試 1 個月免費」:月繳、限新訂閱者、不與 2 週試用疊加(`subscriptions.md`) | 主 session | ✅ |
| 1.7a | 產生一次性代碼 100 組(**訂閱商品審查通過後**才能產生);到期日 | 主 session | ⬜ ⚠️ 到期日待定 |
| 1.8 | App Store Server Notifications:Production 與 Sandbox 都填 `https://<後台網址>/v1/app-store/notifications`,Version 2 | 主 session | ⬜(等 3.1 部署) |
| 1.9 | App 資訊：類別(開發者工具／生產力工具)、隱私權政策網址、授權合約用 Apple 標準 EULA | 主 session | ⬜ |
| 1.10 | 年齡分級問卷 | 主 session | ⬜ ⚠️ Agent 與終端機會顯示主機上任意文字，依問卷如實回答 |
| 1.11 | App 隱私：照 `privacy-labels.md` 逐題填 | 主 session | ⬜ |
| 1.12 | 中繼資料(英文、繁中)、截圖(6.9 吋 iPhone、13 吋 iPad,`scripts/screenshots.sh`) | 主 session | ⬜ |
| 1.15 | 供應地區：排除歐盟 27 國(DSA 貿易商狀態)與中國大陸(ICP 備案),共 147 個地區(`app-store-metadata.md`) | 主 session | ✅ |
| 1.13 | 審查資訊：備註貼 `review-notes.md` 的英文段落、勾「不需要登入」、聯絡資訊 | 主 session | ⬜ |
| 1.14 | 出口合規(2026-11-16 決定 A 案):`ITSAppUsesNonExemptEncryption = NO` 維持。理由：app **只用作業系統提供的加密**——CryptoKit(swift-crypto 在 Apple 平台轉呼叫 CryptoKit;swift-nio-ssh 的金鑰交換、AES-GCM、簽章都走它)、CommonCrypto、系統 TLS(URLSession)。已移除自寫的 bcrypt／Blowfish 與 `_CryptoExtras`(AES-CTR);有 passphrase 的 OpenSSH 私鑰改成明確錯誤，請使用者先 `ssh-keygen -p -N "" -f <私鑰>` 移除 passphrase。**日後不可再引入非系統加密**(自寫演算法、`_CryptoExtras`、OpenSSL／libsodium 等),否則要重新評估出口合規 | 本 repo | ✅ |

## 2. TestFlight CI

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 2.1 | `.github/workflows/testflight.yml`、`.github/ExportOptions.plist`、`scripts/wait-for-testflight.rb`(合併進 `master` 自動上傳，可 `workflow_dispatch`) | 本 repo | ✅ |
| 2.2 | GitHub environment `testflight`,部署分支限定 `master` | 主 session | ✅ |
| 2.3 | environment 變數 `APPLE_TEAM_ID` = `8Z6WVFJ574`;secret `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`(`.p8` 全文;與 my-money.ios 相同) | 主 session | ✅ |
| 2.4 | 發版前遞增 `MARKETING_VERSION`(專案 4 處;每次上傳都要比上一版大) | 主 session | ⬜ |
| 2.5 | 第一次上傳後：確認 Apple 沒寄 ITMS-91053(privacy manifest 缺 required reason API)等警告信;有就補 `src/App/Purrdr/PrivacyInfo.xcprivacy` | 主 session | ⬜ |
| 2.6 | TestFlight 內部群組「內部測試」,開啟自動分發，加入測試者 | 主 session | ✅ |
| 2.7 | 驗收:TestFlight 能從 CI 收到 build(`wait-for-testflight.rb` 回報 ready for internal testing) | 主 session | ⬜ |

## 3. 後台(Cloudflare)

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 3.1 | D1 建立與 migration、Worker 部署(`https://purrdr-backend.lean-lean.workers.dev`) | 主 session | ✅ 2026-11-19 |
| 3.2 | Sign in with Apple key、APNs key、存取權杖密鑰、Apple Root CA - G3、Google OAuth client(`raychiutw/purrdr.server` 的 `README.md`) | 主 session | ✅ 2026-11-19 |
| 3.3 | app 的 `BackendConfiguration.baseURL`、`googleClientID` 換成真值(`src/App/Purrdr/BackendConfiguration.swift`) | 主 session | ✅ 2026-11-19 |
| 3.4 | 主機外掛的公開來源：已併入公開 repo `raychiutw/purrdr.host` 的 `host-plugin/`(app 以 `herdr plugin install raychiutw/purrdr.host/host-plugin` 安裝),不另開 repo | 主 session | ✅ 2026-11-19 |

## 3A. 主機服務發行(#198)

主機服務與它的 Release workflow 已搬到公開 repo `raychiutw/purrdr.host`(`host-service-release.yml`,GitHub environment `release`);以下步驟都在那個 repo 做。目前 macOS 執行檔只以 Developer ID 簽章、**不公證**(environment `release` 沒有 App Store Connect API key 時只簽章)。

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 3A.1 | Account Holder 在 Apple Developer 建立 **Developer ID Application** 憑證，匯出 `.p12`(含私鑰) | 主 session | ✅ 2026-11-19,G2 Sub-CA,到期 2027-12-18;私鑰與 `.p12` 在使用者本機 `~/.config/purrdr-developer-id/` |
| 3A.2 | purrdr.host 的 GitHub environment `release`(部署分支限定 `master`)加變數 `APPLE_TEAM_ID`、secret `DEVELOPER_ID_P12`(`base64 -i cert.p12` 的內容)、`DEVELOPER_ID_P12_PASSWORD`;要公證再加 `ASC_KEY_ID`／`ASC_ISSUER_ID`／`ASC_PRIVATE_KEY`(三個都有才公證，目前沒有、只簽章) | 主 session | ✅ 2026-11-19 已在 purrdr.host 設定 `release`(變數與兩個 Developer ID secret);ASC 三個 secret 尚未設定，所以只簽章。`host-service-v0.2.0` 已從 purrdr.host 發佈 |
| 3A.3 | 第一次發行：在 purrdr.host `gh workflow run host-service-release.yml --ref master`(之後在那裡遞增 `host-service/service/Cargo.toml` 的 version 並合併就自動發行;app 端的 `HostServiceUpdates.latestKnownVersion` 一起遞增，並跑 `scripts/sync-purrdr-host.sh`);確認 Release `host-service-v<版本>` 有 5 個壓縮檔、`SHA256SUMS`、`install.sh`、`install.ps1`,且標為 Latest | 主 session | ⬜ |
| 3A.4 | 驗收：乾淨的 macOS(從瀏覽器下載壓縮檔，有 quarantine;沒公證時 Gatekeeper 的反應也記下來，一行安裝以 curl 下載不帶 quarantine;`codesign -dv --verbose=4`、`spctl -a -vv -t install` 的結果記下來)、Linux、Windows 各跑一次一行安裝 → `pair` → app 掃 QR 連上;再跑一次一行安裝確認是更新、配對保留 | 主 session | ⬜ |
| 3A.5 | 網站加上 `host-service/` 頁(見 4.5) | 主 session | ⬜ |

## 4. 網站(`raychiutw.github.io/purrdr/`)

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 4.1 | 網頁草稿 `docs/site/purrdr/`(首頁、`privacy/`、`support/`、`style.css`),純靜態、無外部資源 | 本 repo | ✅ |
| 4.2 | 把 `REPLACE_ME@example.com`(隱私權政策、支援頁、`review-notes.md`)換成正式聯絡信箱 | 主 session | ✅ lean.lean@gmail.com |
| 4.3 | 複製到 `raychiutw/raychiutw.github.io` 的 `purrdr/` 資料夾並發佈;確認 `https://raychiutw.github.io/purrdr/privacy/` 與 `/support/` 打得開(app 的 `PurrdrLinks` 已指向這兩個網址) | 主 session | ✅ 已上線 https://raychiutw.github.io/purrdr/ |
| 4.5 | 本 repo 的 `docs/site/purrdr/` 改過後要再同步到網站(2026-11-16:支援頁改成不支援有 passphrase 的私鑰;`style.css` 已與網站上 Prettier 格式化的版本一致;2026-11-18:新增 `host-service/` 主機服務安裝說明，app 的 `PurrdrLinks.hostServiceGuide` 指向它;2026-11-19:主機端搬到 `raychiutw/purrdr.host`,安裝指令與 Releases 連結、隱私權政策與支援頁的外掛來源改指向它，macOS 版改寫成「以 Developer ID 簽章」(目前不公證)) | 主 session | ⬜ |
| 4.4 | 隱私權政策的生效日期改成實際發佈日 | 主 session | ⬜ |

## 5. 送審

| # | 步驟 | 誰做 | 狀態 |
|---|---|---|---|
| 5.1 | 依 `review-notes.md`「送審前的前提」逐項確認(後台、商品、通知網址、網站、信箱) | 主 session | ⬜ |
| 5.2 | 以送審 build 跑 `scripts/screenshots.sh`,核對 `review-notes.md` 的 Demo 描述(#36 驗收條件) | 主 session | ⬜ |
| 5.3 | Sandbox 帳號在 TestFlight build 實測：登入、試用購買、恢復購買、兌換 Offer Code、刪除會員 | 主 session | ⬜ |
| 5.4 | 版本頁勾選兩個訂閱商品一起送審，提交 | 主 session | ⬜ |

## repo 裡仍是佔位的值

無(2026-11-19 起後台設定與 app 的 `BackendConfiguration` 都已是真值)。
