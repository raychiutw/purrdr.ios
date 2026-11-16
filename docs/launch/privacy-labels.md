# App Store 隱私標籤(#36)

App Store Connect → App → App 隱私權。每題附依據(程式位置)。改了資料處理就要同步這份、隱私權政策(`docs/site/purrdr/privacy/`)與 App Store Connect。

判斷基準(Apple「App privacy details」):資料「被蒐集」= 從裝置傳出、而且我們或第三方夥伴能在即時處理所需之外保存或存取。
所以：

- **只在裝置上**的資料不算(主機設定、祕密、金鑰、偏好)。
- **經 SSH 直接送到使用者自己電腦**的資料不算：我們與第三方都拿不到(對話、prompt、終端機、圖片)。
- **只在轉送當下處理、不保存**的不算(推播經過後台的 workspace 名稱、狀態、pane id)。

## 第 1 題：你或第三方夥伴是否會從這個 App 蒐集資料?

**是。** 只有使用者登入 Purrdr 會員(Purrdr Plus)時才會蒐集;不登入的話 App 不傳任何資料到我們的伺服器。

## 第 2 題：蒐集的資料類型

| 類別 → 類型 | 蒐集? | 內容 | 依據 |
|---|---|---|---|
| 聯絡資訊 → 電子郵件地址 | **是** | Apple／Google ID token 的 email(可能是 Apple 轉寄地址) | `backend/migrations/` 的 `identities.email`;`src/PurrdrFeatures/MemberView.swift`(Sign in with Apple `requestedScopes = [.email]`);`src/PurrdrFeatures/GoogleSignIn.swift`(scope `openid email`) |
| 聯絡資訊 → 姓名、電話、實體地址、其他 | 否 | Sign in with Apple 不要求 `.fullName` | `MemberView.swift` |
| 識別碼 → 使用者 ID | **是** | 會員 ID、Apple／Google 的 subject | `identities.subject`、`members.id`;`backend/README.md`「API」 |
| 識別碼 → 裝置 ID | **是** | APNs device token(推播配對) | `push_pairings.device_token`;`src/PurrdrFeatures/PushModel.swift`;`POST /v1/members/me/push-pairings` |
| 購買項目 → 購買記錄 | **是** | App Store 交易:original transaction ID、商品、購買／到期／退款時間、自動續訂狀態 | `entitlements` 表;`backend/src/subscriptions.ts`;`src/PurrdrFeatures/SubscriptionModel.swift` |
| 使用者內容 → 其他使用者內容 | **是** | 主機同步：主機名稱、位址與埠、使用者名稱、連線方式、host key 指紋、修改時間 | `synced_hosts` 表;`src/PurrdrCore/HostSync.swift`(`SyncedHost`、`HostSyncJournal`);`backend/README.md`「主機同步」 |
| 使用者內容 → 照片或影片 | 否 | 圖片經 SSH 直接上傳到使用者自己的主機 `~/.purrdr/uploads/`,不經我們 | `src/PurrdrCore/UploadedImages.swift`;`src/PurrdrFeatures/ComposerImageViews.swift` |
| 使用者內容 → 電子郵件或簡訊、遊戲內容、客戶支援、其他 | 否 | 對話與 prompt 只在裝置與使用者的主機之間(SSH) | `src/PurrdrCore/SSHHostChannel.swift`;`backend/README.md` 開頭「聊天與終端機不經過這裡」 |
| 診斷 → 當機資料、效能資料、其他診斷資料 | 否 | 沒有當機回報或分析 SDK(相依只有 swift-nio、swift-nio-ssh、swift-crypto、SwiftTerm);「拷貝診斷資訊」只到剪貼簿，由使用者自己決定是否寄出 | `Package.swift`;`src/PurrdrFeatures/SettingsModel.swift`(`diagnostics`) |
| 使用資料 → 產品互動、廣告資料、其他 | 否 | 沒有分析;評分提示計數只在 UserDefaults | `src/PurrdrFeatures/ReviewPrompt.swift` |
| 位置 | 否 | 不使用定位 | 全 repo 沒有 CoreLocation |
| 健康與健身、財務資訊、聯絡人、敏感資訊、瀏覽紀錄、搜尋紀錄 | 否 | — | — |
| 其他資料 | 否 | 推播的 workspace 名稱／狀態／pane id 只在轉送當下處理、不保存(見上方判斷基準) | `backend/README.md`「推播」 |

> 需人工判斷的一點:後台開啟了 Cloudflare Workers Logs(`backend/wrangler.jsonc` 的 `observability.enabled`),Cloudflare 會短期保存請求紀錄(可能含 IP 位址)用於除錯。
> 這是服務供應商為提供服務而處理、只用於維運與除錯，沒有拿來推算位置、也不連結到會員，所以此處**不申報**「粗略位置」或「其他診斷資料」。
> 若之後把紀錄用於分析，或保存較久，要改申報「診斷 → 其他診斷資料」。

## 第 3 題：每種資料的用途、是否連結到使用者、是否用於追蹤

下表的每一列，在 App Store Connect 依序回答。

| 資料類型 | 用途 | 連結到使用者身分? | 用於追蹤? |
|---|---|---|---|
| 電子郵件地址 | App 功能(登入、在 App 顯示用哪個帳號登入) | 是 | 否 |
| 使用者 ID | App 功能(會員、訂閱權限) | 是 | 否 |
| 裝置 ID | App 功能(推播) | 是 | 否 |
| 購買記錄 | App 功能(判斷 Purrdr Plus 權限) | 是 | 否 |
| 其他使用者內容 | App 功能(主機同步) | 是 | 否 |

用途**都不勾**:第三方廣告、開發者的廣告或行銷、分析、產品個人化、其他用途。

## 追蹤

**沒有追蹤**:不使用 IDFA、沒有 `AppTrackingTransparency`、不與資料仲介分享、不跟其他公司的資料合併。所以也不需要 `NSUserTrackingUsageDescription` 與 ATT 提示。
依據：全 repo 沒有 `ATTrackingManager`、`advertisingIdentifier`、分析 SDK(`grep -rniE "analytics|crashlytics|sentry|telemetry|firebase|ATTrackingManager|advertisingIdentifier" src` 為空)。

## Privacy Manifest

`src/App/Purrdr/PrivacyInfo.xcprivacy`(#36 新增，app 的 buildable folder 自動打包):`NSPrivacyTracking = false`、
`NSPrivacyCollectedDataTypes` 與上表相同(五種、連結到使用者、不追蹤、用途 App 功能)、required reason API 只有
`NSPrivacyAccessedAPICategoryUserDefaults`(`CA92.1`:只讀寫這個 App 自己的資料;我們的程式沒有用到檔案時間戳、開機時間、磁碟空間、鍵盤清單這幾類 API)。
相依的 swift-nio／swift-crypto／SwiftTerm 若用到 required reason API,第一次上傳 TestFlight 後 Apple 會寄 ITMS-91053 信，依信補上。
