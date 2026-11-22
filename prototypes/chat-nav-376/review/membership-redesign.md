# 會員、訂閱、通知與同步：現況問題調查與重新設計

- 調查範圍：`purrdr.ios` origin/master `4b76d3dd`、`purrdr.server` master `9b78737`(唯讀 clone,沒有部署、也沒有呼叫正式 API)。
- 引用格式：app 是 `路徑:行`(origin/master);後台是 `server:路徑:行`。標「未證實」的是推測，還需要實機或後台資料確認。
- Apple 一手來源從 developer.apple.com 的文件 JSON 讀取(連結附在各條後面)。

---

## 0. 結論摘要

| 現象 | 最可能的原因 | 信心 |
|---|---|---|
| 1. 新會員一登入，通知與同步就顯示已開啟 | 通知開關(`PushPairingStore`)和同步開關(`hostSync.enabled`)都存在**全 app 共用的 UserDefaults**,沒有綁會員 ID,登出、刪除會員、換會員時都不清。步驟卡只看「已登入 && 本機狀態」,不看 Plus。 | 高(程式碼確認) |
| 2. 有 Plus,帳號頁卻顯示未開通 | 權限只認後台的會員紀錄。**Apple 登入和 Google 登入是兩個不同的會員**(沒有連結就不會合併),訂閱綁在購買當時的會員(appAccountToken)。用另一種方式登入會看到 `subscription: null`;按恢復購買還會被後台以 409 `subscription_in_use` 拒絕。 | 高(機制確認;實際是哪個會員買的未證實) |
| 3. 重開 app 就要重新登入 | 更新權杖**每次使用都輪替、舊的立刻作廢，沒有寬限期**;存取權杖只放記憶體，所以**每次冷啟動都會輪替一次**。如果輪替的回應沒回到 app(app 被暫停或滑掉、網路切換、逾時),後台已經刪掉舊權杖,Keychain 裡還是舊的，下次啟動就 401,app 清掉登入狀態。 | 中高(機制確認，發生頻率未證實) |

**推薦方案 B**:Plus 權限以裝置端的 StoreKit entitlement 為準(即時、離線也有效、同一個 Apple ID 的所有裝置都有)。會員只用來開雲端功能(推播轉送、主機同步),由 app 把 entitlement 的簽章交易交給後台綁定，並允許有證明的轉移。本機的通知與同步狀態都以會員 ID 分區，登出與換會員時撤銷並清除。更新權杖加冪等的寬限期。

---

## 1. 現象 1:新會員登入後，通知與同步已經是開的

### 1.1 步驟卡怎麼判斷
- 第 3、4 步只看 `isMember && isNotificationsOn`、`isMember && isHostSyncOn`,不看 `isPlusActive`(`src/PurrdrCore/PlusSetupProgress.swift:62-69`;#328 只補了「沒登入不算」)。
- `isNotificationsOn` 來自 `!notifyingHostNames.isEmpty`(`src/PurrdrFeatures/MemberView.swift:313,326`),也就是 `HostPush` 中 `support == .supported && model.state == .on` 的主機(`src/PurrdrFeatures/HostsModel.swift:1019-1025`)。
- `isHostSyncOn` 來自 `hostSync?.isEnabled`(`src/PurrdrFeatures/PlusSetupCard.swift:7-13`)。
- 步驟卡只在第一個沒完成的步驟顯示「目前」,但完成與否每一步各自計算，所以第 1 步完成、第 2 步未完成時，第 3、4 步仍會打勾(`PlusSetupProgress.swift:37-44`)。這和截圖一致：「開通 Plus」是目前步驟，3、4 步已勾。

### 1.2 本機狀態存在哪裡、有沒有綁會員

| 狀態 | 存放 | 綁會員？ | 登出／刪除會員／換會員時清除？ |
|---|---|---|---|
| 推播配對(主機 → keyHash)、已註冊 token、種類 | `UserDefaultsPushPairingStore`,key 例如 `push.registeredTokens`(`src/PurrdrFeatures/PushModel.swift:74-122`) | 否 | 否 |
| `PushModel.state` | 初始化時只要 store 有這台主機的 keyHash 就是 `.on`(`PushModel.swift:383-386`) | 否 | — |
| 主機同步開關 | `UserDefaults` 的 `hostSync.enabled`(`src/PurrdrFeatures/HostSyncModel.swift:28-49`) | 否 | 否 |
| 主機同步紀錄 `HostSyncJournal`(`synced` 是「跟後台一致的版本」) | `hostSync.journal`(`HostSyncModel.swift:31,44-49`;`src/PurrdrCore/HostSync.swift:83-123`) | 否 | 否 |
| 推播裝置 id | Keychain `KeychainPushDeviceID`(AfterFirstUnlockThisDeviceOnly,`src/PurrdrFeatures/KeychainPushDeviceID.swift:46-54`) | 否(本來就該是裝置層級) | 否(合理) |
| 更新權杖 | Keychain `com.raychiu.purrdr` / `backend.refreshToken`(`src/PurrdrFeatures/KeychainTokenStore.swift:6-43`) | 是(就是登入狀態) | 是(`src/PurrdrCore/MemberSession.swift:73-79,208-211`) |

- 登出只會撤銷更新權杖並清掉 Keychain(`MemberSession.swift:73-79`)。`MemberModel.signOut`／`deleteMember` 只改 `phase`(`src/PurrdrFeatures/MemberModel.swift:84-97`),沒有通知推播或同步做任何清理。
- 組裝程式碼裡，推播和同步的 store 都是全域單例(`src/App/Purrdr/PurrdrApp.swift:78-88,171-172`)。

### 1.3 後果(都已從程式碼推出，實際影響未證實)
1. **步驟卡誤判**:會員 A 在這支手機開過通知或同步，登出後會員 B 登入，第 3、4 步直接打勾。
2. **主機與後台的殘留**:主機上 `~/.purrdr/push-<裝置 id>/pairing` 的密鑰還在。後台的 `push_pairings` 列仍屬於 A。主機外掛照樣送推播，後台檢查的是 **A 的**訂閱(`server:README.md:105`)。所以只要 A 還有 Plus,B 登入的這支手機仍會收到 A 那邊的通知。
3. **啟動時對帳只清本機、不撤銷後台**:`refreshAtLaunch` → `reconcileRemoteRevocation` 用 B 的權杖讀 `push-devices`。B 的清單裡沒有這支裝置，所以會清掉本機配對(`PushModel.swift:194-236`)。但 `forget(hosts:)` 只清本機紀錄(`PushModel.swift:243-251`),後台不會回 410,主機上的配對也不會被清掉。結果是重開一次後步驟卡第 3 步回到未完成，但推播仍在。
4. **登出期間不對帳**:沒登入時 `pushDevices` 丟 `signedOut`,`reconcileRemoteRevocation` 回 `false`,本機維持「開」(`PushModel.swift:221-227`)。
5. **同步紀錄跨會員污染**:`pendingChanges` 只上傳 `synced[id] != modified[id]` 的主機(`HostSync.swift:112-123`)。在 A 底下已同步過的主機，換成 B 之後**不會上傳到 B**。B 的其他裝置永遠拿不到這些主機;B 從後台拉下來的主機也會混進 A 留下的本機清單。
6. 「通知」區塊只在 `isPlusActive` 時顯示(`MemberView.swift:353-357`),所以畫面上會出現「步驟卡說已開，但看不到開關可以關」的矛盾。

---

## 2. 現象 2:有 Plus,帳號頁卻顯示未開通

### 2.1 判斷鏈
1. `SubscriptionModel.isPlusActive = subscription?.isActive == true`。`subscription` **只來自後台**(`src/PurrdrFeatures/SubscriptionModel.swift:40-43`;ADR-0007)。
2. `refresh()` 呼叫 `GET /v1/members/me/subscription`:`signedOut` 時清成 `nil`,**其他錯誤吞掉並保留上次的值**(初值是 `nil`)(`SubscriptionModel.swift:65-74`)。
3. `refresh` 只在這幾個地方觸發:帳號頁 `.task(id: signedInMember?.id)`(`MemberView.swift:416`)、主機同步每次 sync 前(`HostSyncModel.swift:98,142`)、推播 `isPlusActive` 回呼(`PurrdrApp.swift:85-88`)。沒有重試，也不在回到前景時重讀。
4. 後台 `GET /v1/members/me/subscription` 依 `member_id` 查 `entitlements`(`server:src/subscriptions.ts:61-83`)。
5. 交易只會在三種情況送到後台：購買後(`SubscriptionModel.swift:79-103`)、恢復購買(`:106-120`)、`Transaction.updates`(`:133-142`,由 `TopNavigationView.swift:130` 在啟動時開始接)。另外，後台還會收 App Store Server Notifications v2(`server:src/subscriptions.ts:203-249`)。
6. 歸屬規則(`server:src/subscriptions.ts:178-190`、`server:README.md:102`):已登記的 original transaction 只屬於原會員;新交易的 `appAccountToken` 如果是另一個仍存在的會員，也不能被別人領走，一律 409 `subscription_in_use`。
7. app 收到 409 時：顯示 `.inUseByAnotherMember`,**並且 finish 這筆交易**(`SubscriptionModel.swift:161-164`)。
8. 購買必須已登入，appAccountToken = 會員 ID(`SubscriptionModel.swift:79-88`;`PlusStore.swift:111-113`)。

### 2.2 會員身分怎麼建立
- `POST /v1/sessions` 依 `(provider, subject)` 找會員，找不到就建一個新的(`server:src/index.ts:130-139`;`server:src/members.ts:28-46`)。
- **不會依 email 自動對應**(ADR-0007 `docs/adr/0007-membership-and-subscription.md:5`)。所以「Sign in with Apple」和「用 Google 登入 lean.lean@gmail.com」在沒有連結時是兩個會員。
- 連結時，如果對方會員有 `entitlements` 或 `synced_hosts`,就拒絕 409 `identity_in_use`(`server:README.md:99,126`)。所以「買了 Plus 的 Apple 會員」和「Google 會員」**事後也連結不起來**。使用者只能刪掉其中一個會員才能連結;如果刪掉的是有訂閱的那個，訂閱的歸屬會因為「原會員已刪除」轉給下一個提交的會員(`subscriptions.ts:182-184`)。

### 2.3 所有「有訂閱卻判定沒有」的路徑(依可能性排序)

1. **登入的會員不是購買當時的會員**(Apple 登入和 Google 登入是兩個會員):`GET subscription` 回 `null`。恢復購買時 `currentEntitlements` 的交易帶著 A 的 token,所以 409,畫面顯示「這個 Apple 帳號的訂閱已屬於另一個會員」。截圖的帳號是 Google `lean.lean@gmail.com`,而後台的 workers 子網域也是 `lean-lean`(`src/App/Purrdr/BackendConfiguration.swift`),所以使用者很可能是開發者本人，先用 Apple 登入買過、後來改用 Google(未證實)。
2. **用 Xcode 的 StoreKit 設定檔或本機測試購買**:這種交易不是 Apple 憑證鏈簽的，後台一律回 400 `invalid_transaction`(`server:README.md:80`)。app 會把它當成「後台明確拒絕」,finish 掉並顯示失敗(`SubscriptionModel.swift:161-164`)。結果是 StoreKit 端「有」,後台「沒有」。開發時很常見(未證實是否就是這次)。
3. **續訂沒有記到後台**:後台只靠 app 提交和 ASSN v2,**沒有用 App Store Server API 主動查**(`server:README.md:174`)。如果 ASSN 網址沒設定好，或通知漏掉(Sandbox／TestFlight 也要另外設定，`server:README.md:161`),續訂就只能靠 app 啟動時由 `Transaction.updates` 帶回並提交。只要某一期沒提交成功，第一期或試用 2 週到期後，後台就判定 `expired`。設定狀態未證實。
4. **續訂交易在別的會員登入時送出，被 409 拒絕並 finish**:`Transaction.updates` 只會在啟動時把未 finish 的交易送一次([Apple:Transaction.updates](https://developer.apple.com/documentation/storekit/transaction/updates)「receives them once, immediately after the app launches」)。如果當時登入的是 B,409 之後 app 會 finish,這筆交易不會再送。擁有者 A 的到期時間就停在舊值(除非有 ASSN)。
5. **交易送出時沒登入或連不上**:`retryLater` 不 finish,但要等**下次冷啟動**才會再送。之後登入時不會主動把 `currentEntitlements` 再交給後台(`MemberModel.submit` 不觸發任何訂閱動作，`MemberModel.swift:118-128`)。
6. **refresh 失敗被吞掉**:帳號頁打開時剛好連不上、被限流(每 IP 每分鐘 60 次，`server:README.md:87,134`;啟動時有多個請求同時發出)、或回應解析失敗，`subscription` 維持初值 `nil`。`task(id:)` 只在會員 ID 變更時重跑，沒有重試。
7. **Offer Code 在 App Store 兌換(沒有 appAccountToken)**:這種訂閱歸「第一個提交的會員」(`subscriptions.ts:176-184`)。如果先被另一個會員提交，就會跟路徑 1 一樣。
8. **過時狀態的反方向**:登出後同一個 `SubscriptionModel` 保留上一位會員的 `subscription`,要等 refresh 成功才清掉。連不上時 B 可能「看起來有 Plus」(`SubscriptionModel.swift:71-73`)。這不是這次的現象，但同屬一類錯誤。

---

## 3. 現象 3:重開 app 就要重新登入

### 3.1 現行機制
- 只有更新權杖存在 Keychain(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,`KeychainTokenStore.swift:25-34`)。存取權杖只放記憶體(`MemberSession.swift:29`)。後台的存取權杖效期 15 分鐘，更新權杖 90 天，**每次使用就輪替，舊的立刻作廢**(`server:src/tokens.ts:5-9,39-49`;`server:README.md:98`)。
- 啟動時的恢復流程：帳號鈕 `.task { if phase == .unknown { restore() } }`(`src/PurrdrFeatures/TopNavigationView.swift:357`)→ `currentMember()`:Keychain 沒有權杖就回 `nil`(`.signedOut`,不提示);有就 `authorized` → `renew()` → `POST /v1/sessions/refresh`(`MemberSession.swift:47-51,158-200`)。
- 同一時間還有其他請求會用到權杖：交易更新(`TopNavigationView.swift:130`)、主機同步(`:132`)、推播對帳(`:148`)。`renew()` 在 actor 內是 single-flight(`MemberSession.swift:180-186`),所以同一個 process 不會重複輪替。
- refresh 回 401 時，`clear()` 刪掉 Keychain 的權杖並丟 `signedOut`(`MemberSession.swift:196-199`)。`MemberModel.run` 會把畫面改成 `.signedOut` 並提示 `.signedOut`(「登入已失效」)(`MemberModel.swift:136-138`)。
- `-uiTesting` 一律用 `InMemoryTokenStore`(`PurrdrApp.swift:337-344`),不影響實機。

### 3.2 可能原因(依可能性排序)
1. **輪替沒有冪等或寬限期，而且每次冷啟動都會輪替**:後台的 `DELETE … RETURNING` 先刪舊權杖，再發新的(`tokens.ts:40-49`)。只要回應沒有成功寫進 Keychain,舊權杖就已經失效。觸發情境包括：剛開 app 就切走被系統暫停、使用者滑掉 app、Wi-Fi 與行動網路切換、30 秒逾時(`URLSessionBackendTransport.swift:19,28-33`,任何傳輸錯誤都轉成 `.unreachable`)。下次啟動一定 401,畫面跳回登入頁(會出現「登入已失效」提示)。存取權杖不落地，所以這個風險**每次啟動都有一次**。發生頻率未證實。
2. **後台少了一筆權杖**:`issueTokens` 在刪除舊權杖之後才 INSERT(`tokens.ts:32-35,42-48`),兩步沒有包在同一個 transaction。中途 D1 失敗會回 500,app 不清權杖，但下一次就是 401。比例低(未證實)。
3. **Keychain 寫入不是原子操作**:`setRefreshToken` 先 `SecItemDelete` 再 `SecItemAdd`(`KeychainTokenStore.swift:25-34`)。如果 Add 失敗，舊權杖已經刪掉，下次 `currentMember()` 讀到 `nil`,**靜默**變成 `.signedOut`(沒有提示)。比例低。
4. **看起來像沒登入，其實是 `.unknown`**:恢復失敗(連不上、429、Keychain 在第一次解鎖前讀取失敗 `errSecInteractionNotAllowed`)時 `phase` 停在 `.unknown`(`MemberModel.swift:33-41,139-145`)。帳號鈕顯示未登入的系統人頭圖(`TopNavigationView.swift:348-362`),打開帳號頁是「無法連上 Purrdr」。使用者可能把它當成「被登出」。
5. **後台資料被重設或換了簽章金鑰**:重建 D1 或清掉 `refresh_tokens` 會讓所有裝置都要重新登入。換 `ACCESS_TOKEN_SECRET` 不影響更新權杖(`server:README.md:151`)。未證實。
6. **安裝的 build 屬於不同的簽章或 access group**:例如 Xcode 用別的 team 簽，Keychain 項目會讀不到，等於沒登入。未證實;同一個 team 的 TestFlight 和 Debug 會共用 Keychain。

**區分方法**:重開後如果有「登入已失效」提示，是原因 1、2(401 路徑);沒有提示、直接是登入頁，是原因 3、6;顯示「無法連上 Purrdr」則是原因 4。目前會員路徑完全沒有 `os.Logger`,建議先加上 category `member`,記錄 refresh 的結果碼。

---

## 4. 目前的流程與狀態機(文字狀態圖)

```text
                         ┌───────────────────────── app 冷啟動 ─────────────────────────┐
                         │ phase = unknown;本機殘留：pushPairings、hostSync.enabled、journal │
                         └───────────────┬─────────────────────────────────────────────┘
                     Keychain 無權杖     │      Keychain 有權杖 → refresh(輪替)
                 ┌──────────────────────┴─────────────────────┐
                 ▼                                            ▼
          [未登入 signedOut]  ◄──── refresh 401 / 刪除會員 / 登出 ──── [已登入 signedIn(member)]
           │ 步驟卡不顯示                                         │ refresh 失敗(非 401)→ [unknown 無法連上]
           │ 本機通知／同步狀態保留(不清)                          │
           │ Apple/Google 登入                                    │ GET subscription
           │  └ 新 subject → 後台建新會員(「加入」)                ▼
           └────────────────────────────────────────►  ┌───────────────────────────────┐
                                                       │ Plus 狀態(只看後台)             │
                                                       │  nil  ─ 購買(token=member)──► active
                                                       │  nil  ─ 恢復(交易 token=他人)─► 409 仍 nil
                                                       │ active ─ 續訂(ASSN/app 提交)─► active
                                                       │ active ─ 到期／退款 ─────────► expired/revoked(needsRenewal)
                                                       │ expired ─ 續訂 ──────────────► active
                                                       └───────────────────────────────┘
   通知(每台主機)：off ─(需 Plus)→ checking → confirming → turningOn → on ─→ turningOff → off
       on 的判斷 = 本機 UserDefaults 有 keyHash;登出、換會員、到期都不會改變(到期只會讓後台拒送)
   同步：off ─(需 Plus)→ on(hostSync.enabled = true)─ 每次 sync 前查 Plus;不是 Plus 就 needsPlus,開關仍是 on
   刪除會員：後台 cascade 刪除會員、權杖、權限、配對、同步資料;本機狀態不清;Apple 訂閱不會取消
   換裝置：新裝置要重新登入;StoreKit 交易在新裝置自動可得，但只有按「恢復」或啟動時有未 finish 的交易才會提交
   換會員：上一位的本機推播與同步狀態被新會員繼承(現象 1);訂閱留在原會員(現象 2)
```

---

## 5. 一手來源要點

- **currentEntitlements**:列出目前有權限的最新交易(自動續訂是 subscribed 或寬限期中);退款或撤銷的不會出現。[Transaction.currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- **updates**:未 finish 的交易「只在 app 啟動後立即送一次」,其餘時間要用 `Transaction.unfinished` 取得。[Transaction.updates](https://developer.apple.com/documentation/storekit/transaction/updates)
- **AppStore.sync**:「只在使用者明確操作時呼叫」;平常 StoreKit 會自動保持最新，重裝或換新裝置時，交易在第一次啟動就可以取得，不需要使用者按恢復。[AppStore.sync()](https://developer.apple.com/documentation/storekit/appstore/sync())
- **appAccountToken**:你自己產生的 UUID,用來把交易對應到自家服務的帳號，App Store 會原樣放回交易裡。[appAccountToken(_:)](https://developer.apple.com/documentation/storekit/product/purchaseoption/appaccounttoken(_:))、[Transaction.appAccountToken](https://developer.apple.com/documentation/storekit/transaction/appaccounttoken)
- **App Store Server API「Set App Account Token」**:可以替 app 外的購買(例如在 App Store 兌換 Offer Code)設定 token,或**取代**既有交易的 token;自動續訂會套用到目前與之後的續訂交易，但不改過去的交易。這正好可以用來做「把訂閱轉給另一個會員」。[Set App Account Token](https://developer.apple.com/documentation/appstoreserverapi/set-app-account-token)
- **SubscriptionStoreView**:系統提供的訂閱商店畫面，顯示在地化名稱、價格與購買鈕。[SubscriptionStoreView](https://developer.apple.com/documentation/storekit/subscriptionstoreview)
- **審查準則**([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)):
  - 3.1.1 解鎖功能必須用 IAP;可恢復的購買「should make sure you have a restore mechanism」。
  - 3.1.2(a) 訂閱「must work on all of the user's devices where the app is available」,也不得要求使用者做額外的事才拿得到已付費的內容。
  - 5.1.1(v) 沒有重要帳號功能時要讓人不登入也能用;有帳號建立就要能在 app 內刪除。**準則沒有規定購買前必須登入**。
- **HIG〈Managing accounts〉**:只有核心功能需要帳號時才要求建立帳號;盡量延後登入。[Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts)
- **HIG〈Sign in with Apple〉**:只在交換價值時要求登入;商務 app 先讓人完成購買，之後再請他建立帳號;登入後要標示目前用哪種方式登入。[Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- **App Store Server Notifications V2 與 Get All Subscription Statuses**:後台可以主動查狀態、補抓漏掉的通知。目前後台沒有用(`server:README.md:174`)。[App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)、[App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)

這些原則直接對照到現況的問題：現在是「訂閱一定要綁會員，而且權限只信後台」,所以同一個 Apple ID 換一種登入方式就不能用(和 3.1.2(a)「所有裝置都能用」的精神相衝)。購買前強制登入也和 HIG 的「延後登入」相反。

---

## 6. 重新設計：三個方案

### 方案 A:保留現行架構，修補漏洞
- 權限仍然只認後台;購買仍需登入。
- 修補項目:
  1. 推播與同步的本機狀態以會員 ID 分區;登出、刪除會員前先撤銷這支裝置的配對、移除主機上的配對、關閉同步並清空 journal。
  2. 登入成功後主動把 `currentEntitlements` 交給後台;409 時顯示「這個 Apple 帳號的訂閱屬於另一個 Purrdr 會員(登入方式：Apple)」,並提供「改用那個帳號登入」。
  3. 更新權杖加寬限期(見 6.4)。
  4. `refresh` 失敗時顯示狀態並提供重試。
- 後台：409 回應附原擁有者的登入方式提示(只回 provider 種類，不回 email);修正 `issueTokens` 沒有包在 transaction 裡的問題;加 refresh 寬限期。
- 優點：改動最小，ADR-0007 不用推翻。
- 缺點：Apple ID 和會員之間的錯配仍然會發生，只是比較看得懂;不登入不能買，不符合 HIG 的「延後登入」;離線或後台故障時 Plus 畫面判斷錯誤。

### 方案 B(推薦):StoreKit entitlement 為準，會員負責雲端綁定
- **權限分兩層**:
  - **裝置端 Plus**(畫面、付費牆、步驟卡):`Transaction.currentEntitlements` 有 Plus 商品就算開通。啟動時與 `Transaction.updates` 時重算，即時、離線也有效，同一個 Apple ID 的所有裝置都有。
  - **雲端權限**(後台決定能不能推播轉送、能不能同步):仍是 `entitlements` 綁會員。綁定方式改成「有簽章交易就能證明」:登入後、或開啟通知或同步前，app 把 entitlement 的 JWS 交給後台。
- **購買不需要登入**:沒登入時 `appAccountToken` 用這支裝置的匿名 UUID,或乾脆不帶。付費牆改用 `SubscriptionStoreView`(或保留自訂 UI),主要按鈕不再是「Sign In to Subscribe」。
- **會員只在需要雲端功能時才要求**:開啟通知或同步時才請使用者登入(「通知要經過 Purrdr 伺服器轉送，所以需要帳號」)。登入和加入分成兩條:登入頁加註「沒有帳號會建立新帳號」;如果這支裝置已經有 Plus 交易但後台會員沒有，就提示「把這個訂閱連到這個帳號」。
- **訂閱轉移**:後台收到 JWS,而它已經屬於另一個會員 A 時，回 409 並附 `transferable: true` 與 A 的登入方式。使用者確認「移到目前帳號」後，後台改寫 `entitlements.member_id`,並呼叫 **Set App Account Token** 把之後的續訂 token 改成 B。A 的推播配對失去權限，由後台回 403。有能力提交有效簽章交易，就代表持有那個 Apple ID,這可以當作所有權證明;風險是 Apple ID 共用的家人可以互相搶走訂閱，可以加一個冷卻期。
- **後台補強**:App Store Server API key + Get All Subscription Statuses(綁定時與每日排程對帳)、確認 ASSN v2 的 Production 與 Sandbox 都已設定。
- **通知與同步的開關規則**(以 `(會員 ID, 裝置)` 分區):

  | 事件 | 通知 | 同步 |
  |---|---|---|
  | 登出 | 先用目前的權杖撤銷這支裝置的所有配對，再移除主機上的配對(背景佇列，盡力而為),本機清除 | 關閉、清 journal |
  | 換會員 | 同登出(上一位的資料不會讓新會員繼承) | 同登出 |
  | 刪除會員 | 後台 cascade 刪除;app 端移除主機上的配對 | 清除 |
  | 裝置端 Plus 到期 | 保留配對，但標成「暫停」(畫面上不算完成);續訂後自動恢復 | 暫停，不送請求 |
  | 後台判定不是 Plus 但裝置端是 | 自動把 JWS 交給後台補綁;轉移失敗時說明 | 同左 |

- **步驟卡**:第 3、4 步要 `isPlusActive && 雲端已綁定 && 本機(該會員分區)狀態`。
- **後台 API 影響**:
  - `POST /v1/members/me/subscription/app-store` 加 `transfer: boolean`。
  - 409 body 加 `ownerProviders`。
  - 新增排程對帳。
  - `sessions/refresh` 寬限期(6.4)。
  - 推播與同步仍然檢查 `requireActiveSubscription`,不必改。
- **遷移**:
  1. 新版 app 第一次啟動時，把現有 UserDefaults 的推播配對與 `hostSync.*` 歸到目前登入的會員 ID。沒登入就歸到「無主」:不算完成，提示登入或清除。
  2. 已有的 `entitlements` 不動。
  3. 舊版 app 仍走原本的 API,向後相容。
- **優點**:Apple ID 一致的情況下 Plus 永遠正確;不登入也能買;權限即時;錯配時可以自助修復。
- **缺點**:後台要加 App Store Server API key、轉移邏輯和排程;裝置端和後台可能短暫不一致(畫面要能說明);Android 版(Google Play)需要對應的轉移流程。

### 方案 C:不需要會員(匿名 entitlement + iCloud)
- 推播配對的授權改用 JWS 的 `originalTransactionId`(後台以它當帳號);主機同步改用 CloudKit private database。拿掉 Google 登入和會員刪除流程。
- 優點：沒有登入狀態可以壞掉;隱私最好;完全符合 HIG。
- 缺點：推翻 ADR-0007 的 Android 跨平台共用(Android 沒有 iCloud,也沒有 App Store 交易);後台要大改;「通知裝置」清單要改用交易身分;既有會員資料要遷移或淘汰。

### 比較

| | A 修補 | **B entitlement 為準** | C 無會員 |
|---|---|---|---|
| 解決現象 1 | 是 | 是 | 是(沒有會員就沒有跨會員殘留) |
| 解決現象 2 | 部分(看得懂，但仍要使用者切換帳號) | 是(裝置端即時，還能轉移) | 是 |
| 解決現象 3 | 是(寬限期) | 是(寬限期;而且登入失效不再影響 Plus 畫面) | 是 |
| 不登入也能買 | 否 | 是 | 是 |
| Android 共用 | 是 | 是(會員仍在) | 否 |
| 後台改動 | 小 | 中 | 大 |
| app 改動 | 中 | 中大 | 大 |

### 6.4 登入狀態可靠保存(A、B 共用)
1. **後台 refresh 冪等寬限期**:輪替時不刪舊權杖，改標 `rotated_at` 與 `replaced_by`。60 秒內再拿舊權杖來，回傳**同一組後繼權杖**(需要把後繼權杖的密文暫存，或改成可以重算);超過寬限期再用舊權杖，才視為重放並撤銷整個 family。刪除與 INSERT 包在同一個 `DB.batch`。
2. **減少輪替次數**:存取權杖也存進 Keychain(效期 15 分鐘，AfterFirstUnlockThisDeviceOnly),冷啟動時還沒過期就不 refresh。
3. **Keychain 寫入改用 `SecItemUpdate`,失敗才 `SecItemAdd`**,不再先刪除。寫入失敗時保留舊值並記錄。
4. **區分畫面狀態**:`.unknown`(連不上)時帳號鈕顯示「離線」樣式，不顯示未登入的人頭圖。
5. **加 `os.Logger`(category `member`)**:記錄 refresh 的結果碼、Keychain 的 OSStatus、401 前一次 refresh 的時間。

---

## 7. 推薦方案 B 的狀態圖

```text
 裝置端 Plus(StoreKit)            雲端綁定(後台)                     會員
 ─────────────────────            ────────────────                   ────
 none ─購買(不需登入)→ active      unbound ─登入後送 JWS→ bound(me)    signedOut ─登入(Apple/Google)→ signedIn(id)
 active ─到期/退款→ none           unbound ─JWS 屬於他人→ conflict      signedIn ─登出→ signedOut(先撤銷、清本機)
 active ─續訂(updates)→ active      conflict ─使用者確認轉移→ bound(me)  signedIn ─刪除會員→ signedOut(後台 cascade)
 (換裝置：啟動即得 entitlement)       bound ─後台到期(ASSN/對帳)→ lapsed   signedIn(A) ─換成 B→ 等同 登出 A + 登入 B

 Plus 畫面 = 裝置端 active || (雲端 bound 且後台 active)     ← 跨平台買的(Google Play)仍由後台判定
 可開通知／同步 = 裝置端或後台 Plus && signedIn && bound(me)
 通知(主機 × 會員分區)：off → on(配對註冊於 me)→ paused(Plus 失效)→ on(恢復)
                         任何 signedIn 改變 → 撤銷並清除 → off
```

## 8. 推薦方案 B 的畫面流程清單
1. **付費牆(Purrdr Plus 頁)**:不登入就能購買(`SubscriptionStoreView` 或自訂);恢復購買;兌換代碼;條款。購買成功顯示「已開通。要收通知或跨裝置同步，請登入」。
2. **帳號頁(未登入)**:顯示裝置端的 Plus 狀態(有就寫「Purrdr Plus・已開通(這個 Apple ID)」);Apple 和 Google 登入鈕;一句說明「沒有帳號會自動建立」。
3. **帳號頁(已登入)**:頭像和「使用 Apple／Google 登入」(HIG 要求標示登入方式);步驟卡改成 ① 開通 Plus ② 登入或連結帳號 ③ 開啟通知 ④ 同步主機;雲端綁定狀態。
4. **訂閱衝突頁**:「這個 Apple ID 的訂閱目前連到另一個 Purrdr 帳號(用 Apple 登入)」→「移到目前帳號」(說明另一個帳號的通知會停止)／「改用那個帳號登入」。
5. **開啟通知或同步(沒登入時)**:先說明為什麼需要帳號 → 登入 → 自動綁定 → 回到原本的開關。
6. **登出確認**:「這支裝置會停止通知、主機同步會關閉」→ 背景撤銷，畫面顯示進度。
7. **刪除會員確認**:沿用現有流程，另外說明會移除主機上的通知配對。
8. **離線或登入失效**:帳號鈕顯示離線樣式;401 時跳一次「請重新登入」,Plus 畫面不受影響(以裝置端為準)。

## 9. 建議的下一步
1. 先確認現象 2 是哪種情況：讀後台 D1(唯讀)的 `identities` 和 `entitlements`,看 lean.lean@gmail.com 的會員和 Apple 身分的會員各有什麼;確認 ASSN 網址(Production 和 Sandbox)是否已設定。
2. 加上 `member` 的 logger,收集現象 3 重開時有沒有「登入已失效」提示(用來區分 401 路徑和靜默路徑)。
3. 照第 6 節選定方案後，走 `/grill-with-docs` → 新的 ADR(取代或補充 ADR-0007 的「權限只記在會員身上」)。
