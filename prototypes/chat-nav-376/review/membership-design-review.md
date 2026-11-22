# 會員與 Purrdr Plus 設計稿審查(#402)

審查日期:2026-11-22
審查對象:`design377/project/` 的 `AccFlow.dc.html`(26,登入與加入 7 種)、`AccPage.dc.html`(27,帳號頁 9 種)、`AccSub.dc.html`(28,子頁與確認 7 種),共用 `purrdr.css`;比對已定稿的 `Settings`、`Host`、`HostSub`、`Welcome`、`Tabs`。
方法:讀原始碼推斷畫面(沒有渲染);對比以 WCAG 相對亮度公式計算 token 實際值。
規格:`gh issue view 402`;設計規範:`origin/master:DESIGN.md`;研究背景:`research/membership-redesign.md`。

**結論:必修不是零，共 4 項**(Sign in with Apple 按鈕標題、刪除會員的訂閱處理、加入流程略過 Plus 後仍能開通知與同步、缺通知裝置畫面)。另有應修 22 項、建議 14 項。

---

## 0. 一手依據(本次實際讀過的)

| 代號 | 來源 | 這次用到的原文要點 |
|---|---|---|
| G3.1.1 | [App Review Guidelines 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase) | 解鎖功能必須用 IAP;「you should make sure you have a restore mechanism」;非美國 storefront 不得有導向其他購買方式的「buttons, external links, or other calls to action」(3.1.1(a)) |
| G3.1.2 | [3.1.2(a)、3.1.2(c)](https://developer.apple.com/app-store/review/guidelines/#subscriptions) | 訂閱「must work on all of the user's devices」;不得要求額外動作才拿得到已付費內容;訂閱前「clearly describe what the user will get for the price」,並遵守 Schedule 2 |
| S2 3.8(b) | [Apple Developer Program License Agreement, Schedule 2 §3.8(b)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) | 必須「clearly and conspicuously disclose」:訂閱名稱、週期、價格(必要時含單位價格)、隱私權政策與使用條款連結 |
| G3.1.3(b) | [3.1.3、3.1.3(b)](https://developer.apple.com/app-store/review/guidelines/#other-purchase-methods) | 多平台服務可讓使用者使用在其他平台取得的訂閱，前提是 app 內也有 IAP 可買;app 內不得「encourage users to use a purchasing method other than in-app purchase」 |
| G4.8 | [4.8 Login Services](https://developer.apple.com/app-store/review/guidelines/#login-services) | 用 Google 等第三方登入建立主要帳號時，要提供符合隱私條件的「equivalent option」(Sign in with Apple 符合) |
| G5.1.1(v) | [5.1.1(v) Account Sign-In](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage) | 沒有重要帳號功能就要能免登入使用;支援建立帳號就要能在 app 內刪除;不得要求個資才能運作，除非與核心功能直接相關 |
| AD | [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/) | 「If a person has an auto-renewable subscription, notify them that billing will continue through Apple and ask them to cancel their subscription before continuing.」;用 `showManageSubscriptions` 或 `https://apps.apple.com/account/subscriptions/`;Sign in with Apple 要以 REST API 撤銷 token;不可讓刪除不必要地困難 |
| HIG-MA | [HIG: Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts) | 要求帳號時說明理由;「Refer only to authentication methods that are available in the current context」(沒有 Face ID 的裝置不提 Face ID);刪除要告知何時完成並通知完成;要說明訂閱帳單會繼續由 Apple 收取直到取消、以及如何取消 |
| HIG-SIWA | [HIG: Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple) | 「Make a Sign in with Apple button no smaller than other sign-in buttons」;深色底用白色、淺色底用黑色;自訂按鈕「Titles. Use only Sign in with Apple, Sign up with Apple, or Continue with Apple」;系統按鈕自動在地化、可調圓角 |
| HIG-AL | [HIG: Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | 只有 macOS 與 visionOS 的 alert 可以有圖示;有破壞性動作要有「Cancel」;「Use an action sheet — not an alert — to offer choices related to an intentional action」 |
| HIG-IAP | [HIG: In-app purchase](https://developer.apple.com/design/human-interface-guidelines/in-app-purchase) | (JSON 端點本次取不到，只引用研究報告已摘錄的部分) |
| HIG-TG / HIG-SH | [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)、[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | 用系統 switch;sheet 要有明確的關閉方式 |
| GSI | [Google Sign-In branding guidelines](https://developers.google.com/identity/branding-guidelines) | Google 按鈕要用標準「G」標誌與規定文字 |
| WCAG | [WCAG 2.2 1.4.3、1.4.11、2.5.8](https://www.w3.org/TR/WCAG22/) | 文字 4.5:1(大字 3:1)、非文字 3:1、目標至少 24×24 CSS px(或符合間距例外);Apple HIG 另要求 44×44pt |

---

## 1. 規格覆蓋:#402 的 45 條使用者故事

符號:✅ 有畫面且符合 ／ ◐ 部分(缺狀態或與規格有出入)／ ✗ 沒有畫面 ／ — 純後台或邏輯，不需要畫面

| # | 故事(摘要) | 對應 artboard | 判定與缺口 |
|---|---|---|---|
| 1 | 沒登入先選登入或加入 | 26「未登入:選擇」 | ✅ |
| 2 | 加入走 4 步 | 26「加入 1/4～4/4」「加入完成」 | ◐ 略過 Plus 後的分支沒有畫(見必修 M3);沒有主機時的第 3、4 步沒有畫 |
| 3 | 登入後直接進帳號頁 | 26「登入」(註腳「登入後直接回到帳號頁」) | ◐ 用沒有會員的 Apple／Google 帳號按「登入」時的狀態沒有畫(應修 S6) |
| 4 | 用 Apple 或 Google 加入 | 26「加入 1/4」 | ◐ Apple 按鈕標題不合規(必修 M1) |
| 5 | 帳號頁新增登入方式 | 28「登入方式」的「新增登入方式…」 | ◐ 點下去後的選擇(只列尚未綁定的提供者)、Face ID、成功結果沒有畫 |
| 6 | 已驗證 email 相同自動合併 | 26「加入 1/4」註腳 | ◐ 只有一句註腳；自動合併後沒有告知(例如「已登入既有會員 r***@gmail.com」) |
| 7 | 隱藏 email 的人手動綁定 | 28「新增 Google 時發現已是會員」 | ◐ 這張畫的是「要綁的帳號已經屬於另一個會員 → 合併兩個會員」,規格沒有定義這種會員合併(應修 S16);一般的手動綁定流程(選 Google → 綁上)沒有畫 |
| 8 | 移除登入方式(至少留一種) | 28「登入方式」 | ◐ 只剩一種時「移除」要停用或隱藏的狀態、移除確認沒有畫 |
| 9 | 看到訂閱與付款來源 | 27「有 Plus(App Store)」「Google Play 訂閱」 | ✅ |
| 10 | 帳號頁單獨開通 Plus | 27「沒有 Plus」的「開通 Purrdr Plus」 | ◐ 從帳號頁開的付費牆(沒有步驟、左上關閉或返回、沒有「稍後再說」)沒有畫(應修 S4) |
| 11 | 帳號頁恢復購買 | 27「沒有 Plus」「已到期」 | ◐ 恢復結果(沒有可恢復的購買、恢復成功、屬於其他會員)沒有畫 |
| 12 | iPhone 只看到 App Store 購買 | 26「加入 2/4」(「透過 App Store 付款」) | ✅ |
| 13 | Google Play 訂閱在 iPhone 有 Plus | 27「Google Play 訂閱」 | ✅ |
| 14 | 顯示「透過 Google Play 訂閱」且沒有購買鈕 | 27「Google Play 訂閱」 | ✅ 沒有按鈕、沒有外部連結 |
| 15 | 換商店的說明 | 27「Google Play 訂閱」「轉移被擋下」 | ✅ |
| 16 | 系統管理訂閱畫面 | 27「有 Plus」的「管理訂閱」 | ✅(實作要用 `showManageSubscriptions`) |
| 17 | 訂閱屬於其他會員(部分遮蔽 email) | 27「訂閱屬於其他會員」 | ◐ 用了舊名「Apple ID」(應修 S14) |
| 18 | Face ID 後轉移 | 28「轉移訂閱確認」 | ◐ 轉移成功後的狀態沒有畫；文案不完整(應修 S13) |
| 19 | 已有其他訂閱時轉移被擋 | 27「轉移被擋下」 | ◐ 這個狀態把「已開通(Google Play)」蓋掉了(應修 S12) |
| 20 | 有 Plus 才能開通知與同步 | 27「沒有 Plus」、28 主機 tab | ◐ 加入流程略過 Plus 後仍可開(必修 M3) |
| 21 | 沒 Plus 顯示鎖定與「需要 Purrdr Plus」 | 27「沒有 Plus」「已到期」、28 主機 tab | ◐ 鎖定樣式兩處不一致(應修 S9) |
| 22 | 新會員從「未開啟」開始 | 26「加入 3/4」 | ◐ 第 3 步 Ray Mac Mini 預設是開(應修 S19) |
| 23 | 登出前撤銷推播配對、停止同步 | 28「登出確認」 | ✅(文案有寫) |
| 24 | 不收到上一位會員的通知 | — | — 邏輯 |
| 25 | 重開 app 仍是登入 | — | — 邏輯 |
| 26 | 網路不穩只顯示「暫時連不上」 | 27「暫時連不上(仍是登入)」 | ✅ |
| 27 | App 鎖 Face ID 解鎖 | 25「App 鎖」(既有) | ✅ |
| 28 | 敏感動作要 Face ID | 28 三個確認 alert、各子頁註腳 | ◐ 移除登入方式、新增登入方式、撤銷裝置沒有確認畫面，Face ID 時機不明(應修 S11);文字寫死 Face ID(應修 S10) |
| 29 | 登入中的裝置與撤銷 | 28「登入中的裝置」 | ◐ 撤銷沒有確認 |
| 30 | app 內刪除會員(Face ID＋確認) | 27 帳號頁「刪除會員…」、28「刪除會員確認」 | ◐ 刪除完成的告知沒有畫(應修 S8) |
| 31 | 刪除時提醒 App Store 訂閱要另外取消 | 28「刪除會員確認」 | ◐ 只有一句，沒有路徑、沒說帳單繼續(必修 M2) |
| 32 | 免費功能不需要會員 | 26「未登入:選擇」註腳 | ✅ |
| 33 | 沒登入想開通 Plus 先被引導 | 28 主機 tab 註腳 | ◐ 從 Plus 入口進來的選擇頁沒有說明為什麼要先登入(建議 R2) |
| 34 | 購買後立即生效 | 26「加入完成」 | ◐ 購買處理中、Ask to Buy 等待核准(StoreKit `.pending`)、後台確認前的狀態沒有畫(應修 S7) |
| 35 | 續訂、退款、到期自動更新 | — | — 後台 |
| 36 | 帳單寬限期仍有 Plus 並提示 | 27「帳單寬限期」 | ◐ 寬限期結束後的「帳單重試期」沒有畫(應修 S5);Google Play 寬限期版本沒有畫(建議) |
| 37 | 到期自動停止並提示續訂 | 27「已到期」 | ✅ |
| 38 | 舊版兩個會員升級後自動合併 | 27「升級後待處理」 | ✅ |
| 39 | 兩邊都有訂閱時保留較晚到期並提示 | 27「升級後待處理」 | ✅ |
| 40 | 升級後只需要重新登入一次 | — | ✗ 升級後第一次看到登入的人不知道為什麼被登出，需要說明(應修 S17) |
| 41 | Android 同一個會員 | — | — 範圍外(文案已提到 Android) |
| 42 | 通知裝置清單只列這個會員的 | — | ✗ **帳號頁沒有「通知裝置」**(必修 M4) |
| 43 | 主機同步只在這個會員的裝置之間 | 26「加入 4/4」文案 | — 邏輯 |
| 44 | VoiceOver 念得出狀態與鎖定原因 | 各處 aria-label | ◐ 步驟「1 / 4」、付費牆方案群組、可點的鎖定列(應修 S9、建議 R7) |
| 45 | 會員流程診斷紀錄 | — | — 邏輯 |

**完全沒有畫面的故事**:#40(升級後重新登入的說明)、#42(通知裝置)。
**規格「畫面流程」列了但沒畫的**:帳號頁的「通知裝置」;帳號頁開的獨立付費牆;帳號頁「通知」列點進去的畫面(只畫了列，沒畫目的地)。
**跨故事都缺的狀態**:載入中(第一次讀會員與訂閱)、Apple／Google 登入取消或失敗、Face ID 失敗或取消、恢復購買結果、購買處理中與 `.pending`、轉移成功、刪除完成、被其他裝置撤銷後的登出說明。

---

## 2. 合規

### 2.1 付費牆必要揭露(26「加入 2/4」)

| 項目(S2 3.8(b)、G3.1.2(c)) | 狀態 |
|---|---|
| 訂閱名稱 | ✅ 標題「開通 Purrdr Plus」 |
| 週期 | ✅ 年繳／月繳 |
| 價格(粗體、在方案列標題) | ✅「[年費]/年」「[月費]/月」;收費金額是最顯眼的價格元素，試用是副標 |
| 得到什麼 | ✅「Plus 讓你收通知、同步主機清單。聊天與終端機不受影響。」 |
| 自動續訂與取消方式 | ✅「透過 App Store 付款，試用結束後自動續訂，可隨時在設定中取消。」 |
| 使用條款、隱私權政策連結 | ✅ 有，但觸控目標太小(應修 S15) |
| 恢復購買 | ✅(G3.1.1) |

揭露本身齊全。需要修的是動態文案:
- 選「月繳」(沒有試用)時，按鈕仍寫「開始免費試用」、註腳仍寫「試用結束後」,會變成誤導(G3.1.2「trick users into purchasing … under false pretenses」)。要依選取方案與 `isEligibleForIntroOffer` 切換按鈕與註腳(應修 S3)。
- 已用過試用的 Apple 帳號不能再試用，同上。

### 2.2 Google Play 訂閱在 iOS 的呈現(27「Google Play 訂閱」「轉移被擋下」「升級後待處理」)

**不違反 3.1.1／3.1.3(b)**。理由:
- 沒有購買按鈕、沒有連到 Google Play 的連結或按鈕，只有說明文字，不構成 3.1.1(a) 的「buttons, external links, or other calls to action that direct customers to purchasing mechanisms」。
- 3.1.3(b) 允許使用者使用在其他平台取得的訂閱，前提是 app 內也能用 IAP 買到同樣的訂閱——Purrdr Plus 有 App Store 方案，成立。
- 「要改用 App Store,請先在 Google Play 取消」是引導**回到 IAP**,不是引導外部購買。「請在 Google Play 取消，避免重複付費」(待處理)是管理既有訂閱，不是購買。

注意:實作時不要把「在 Google Play 管理」做成可點的連結或按鈕(規格 Implementation Decisions 已寫「不放外部連結」,設計稿也符合)。

### 2.3 Sign in with Apple(26「登入」「加入 1/4」)

| 檢查 | 判定 |
|---|---|
| 4.8 等價選項 | ✅ Apple 與 Google 並列 |
| 不小於其他登入鈕 | ✅ 兩顆都是 50pt 高、整寬;Apple 在上面、填色，比 Google(外框)更顯著 |
| 顏色 | ✅ 深色底用白色(`--text` #FFFFFF 底、黑字),淺色底用黑色;對 sheet 底 13.9:1／18.8:1 |
| 圓角 | ✅ 膠囊(系統按鈕可設定 cornerRadius) |
| **標題** | ✗ 「使用 Apple 加入」不是允許的標題。HIG-SIWA 只允許 Sign in／Sign up／Continue with Apple,系統按鈕(`ASAuthorizationAppleIDButton`)的繁中是「使用 Apple 登入」「使用 Apple 註冊」「透過 Apple 繼續」,畫不出「加入」。設計稿自己的 aria-label 也寫「系統 Sign in with Apple 按鈕」(**必修 M1**) |
| Google 按鈕 | 沒有 Google「G」標誌(GSI;應修 S18) |

### 2.4 刪除會員(28「刪除會員確認」)

- ✅ 入口好找(帳號頁最下面，G5.1.1(v)、AD「easy to find」)。
- ✅ 確認一次加 Face ID,不算「unnecessarily difficult」。
- ✗ AD 對有自動續訂訂閱的人要求「notify them that billing will continue through Apple and ask them to cancel their subscription before continuing」;HIG-MA 要求說明怎麼取消。現在只有一句「App Store 的訂閱要另外在設定中取消」,沒有說帳單會繼續，也沒有在刪除前給取消的路徑;Google Play 訂閱者看到的也是「App Store」(**必修 M2**)。
- ✗ HIG-MA「notify them when it's finished」:刪除完成的畫面沒有(應修 S8)。
- 實作備註(不是設計):刪除會員與移除 Apple 登入方式時要以 Sign in with Apple REST API 撤銷 token(AD、HIG-MA)。

### 2.5 轉移訂閱的文案(27「訂閱屬於其他會員」、28「轉移訂閱確認」)

沒有欺騙性，但有三處會讓人誤會(應修 S13、S14):
1. 「這支裝置的會員會取得 Plus」:會員不是裝置的。改成「目前登入的會員(r***@gmail.com)」。
2. 沒說付款不變：使用者可能以為轉移會重新收費或換付款人。補「付款仍由同一個 Apple 帳號支付，不會另外收費」。
3. 沒說原會員的通知與同步會停止(規格 Implementation Decisions「其推播配對與同步停止」)。
另外「Apple ID」已改名為「Apple 帳號」。

「訂閱屬於其他會員」狀態旁的「恢復購買」按下去只會得到同樣結果，容易讓人反覆嘗試(建議 R3)。

### 2.6 「購買前要登入」的審查風險(故事 33)

5.1.1(v) 準則沒有禁止購買前登入，Plus 的兩個功能(跨裝置主機同步、後台推播配對)本身就是帳號功能，理由成立。但審查員常以 5.1.1 退回「要求先註冊才能購買」。建議在 App Review Notes 寫明 Plus 為何必須綁會員，選擇頁也加一句理由(HIG-MA「Explain the benefits of creating an account」)(建議 R1、R2)。

### 2.7 3.1.2(a)「所有裝置都能用」

訂閱屬於另一個會員時，付款的 Apple 帳號在這支裝置上看不到 Plus,要轉移才有。這是「訂閱綁服務帳號」的常見做法，有轉移選項就不算卡住，但審查時可能被問到。規格已採「後台確認前依 StoreKit 權限先生效」,設計稿要確保「屬於其他會員」時至少有清楚的一步轉移(目前有，OK)。

---

## 3. 流程與一致性

### 3.1 登入／加入分流
- ✅ 選擇頁兩個 cell 並列，副標說清楚差別;登入頁與加入頁底部互相切換的連結(「還不是會員?加入會員」)。
- ✗ 「登入」用了沒有會員的帳號 → 沒有畫(應修 S6)。建議：顯示「找不到會員」並提供「用這個帳號加入」。
- ✗ 「加入」用了已經是會員的帳號 → 註腳說會直接登入，但接下來是進帳號頁還是繼續第 2 步、已有 Plus 時是否跳過付費牆，沒有畫(併入 S6)。

### 3.2 步驟可略過
- ✅ 第 2 步「稍後再說」、第 3、4 步「略過」。
- ✗ 略過第 2 步後，第 3、4 步的開關仍可開，違反故事 20 與狀態模型「通知與同步的完成必須同時滿足已登入且有 Plus」(**必修 M3**)。
- ✗ 第 3、4 步在沒有任何主機時沒有畫(新使用者很常見)。

### 3.3 返回與關閉位置
- ✅ 頂層 sheet 左上 xmark(選擇頁、帳號頁、加入完成),與 Attach、Model、Welcome、Shell 一致;推入的子頁左上返回箭頭，與 Model「返回模型選擇」、Shell「返回帳號」一致;都是 44×44。
- ✗ 第 2～4 步左上是返回：第 2 步返回會回到「建立會員」,但會員已經建立，這一步是死路;第 2～4 步沒有關閉鍵，只能下滑關掉(應修 S2)。
- 「新增 Google 時發現已是會員」是從「登入方式」推入的，返回鍵 aria-label 卻是「返回帳號」(建議 R8)。
- DESIGN.md 仍寫「不編輯內容的 sheet 一律以右上『完成』關閉，不混用 Close(xmark)」,與 #376 畫布全面改用左上 xmark 衝突，要更新 DESIGN.md(應修 S22)。

### 3.4 Face ID 確認時機
- ✅ 登出、刪除、轉移、合併：先說明後果，按下「用 Face ID …」才驗證，時機正確(先確認意圖、再驗證身分)。
- ✗ 移除登入方式、新增登入方式、撤銷其他裝置只有註腳「需要 Face ID」,沒有確認畫面;撤銷與移除是破壞性動作，應先確認(應修 S11)。新增登入方式要決定 Face ID 在 Apple／Google 授權前還是後(建議在前，避免授權完才被擋)。
- ✗ 按鈕寫死「Face ID」。HIG-MA 要求只提裝置上有的驗證方式;DESIGN.md 的 App 鎖已規定依裝置顯示 Face ID／Touch ID／Optic ID／裝置密碼(應修 S10)。

### 3.5 鎖定狀態說明
- ✅ 帳號頁與主機 tab 都寫「需要 Purrdr Plus」,鎖頭圖示有 `role="img"`、`aria-label`。
- ✗ 兩處樣式不一致：帳號頁的鎖定列套 `.dis`(灰字),主機 tab 的「通知」不套;帳號頁「主機同步」是不能點的 `div`,「通知」卻是可點的 `button`(點了去哪沒畫)。可點的列套用停用色，文字 #8E8E93 對白底只有 3.26:1,不符 1.4.3(停用豁免只適用於真的不能操作的元件)(應修 S9)。
- 「訂閱屬於其他會員」時鎖定原因仍是「需要 Purrdr Plus」,可以更具體(建議 R4)。

### 3.6 與已定稿畫面的一致性
| 項目 | 判定 |
|---|---|
| sheet 結構(grabber、sheettop、`.scard` 卡片) | ✅ 與 Attach、Model、Welcome 相同 |
| cell(min-height 48、分隔線、chevron 13px) | ✅ |
| 勾選列(方案 `menuitemradio` 列尾打勾) | ✅ 與 Settings 外觀一致;但 DESIGN.md 寫「Purrdr Plus 方案卡保留卡片與外框，選中的那張右上角打勾」,兩者要擇一並同步 DESIGN.md(併入 S22) |
| alert | ◐ 與 HostSub 同一套版型，但 28 的三個 alert 加了 Face ID 圖示：iOS 系統 alert 不能放圖示(HIG-AL),實作做不出來(應修 S20);遮罩寫死 `rgba(0,0,0,.35)` 沒用 `--scrim`(建議 R10,HostSub 也一樣) |
| 破壞性按鈕 | ✅ 登出、刪除用 `--redtext`,alert 的取消鈕有底色、破壞性鈕沒有，與 HostSub 一致 |
| 色彩 token | ✅ 沒有新增色值;Apple 鈕用 `--text`／`--bg` 反轉 |
| 主機 tab 頂列(28 最後一張) | ◐ `hostcap` 少了 Host.dc.html 的螢幕圖示與 aria-label「選取中主機:…,點兩下更改」(建議 R11) |
| 頁面說明段落 | ◐ DESIGN.md(#236)規定頁面不放功能說明、已拿掉帳號頁「登入方式」與「刪除會員」的註腳;28「登入方式」又加回「至少要保留一種登入方式。移除或新增都需要 Face ID。」,「登入中的裝置」也有註腳。要嘛拿掉，要嘛改 DESIGN.md(併入 S22) |
| 裝飾圖示 | 選擇頁的品牌圖示、完成頁的大勾，DESIGN.md「不放重複標題的裝飾圖示」;歡迎頁類的畫面可以例外，建議在 DESIGN.md 寫明(建議 R12) |

---

## 4. 對比與觸控目標

### 4.1 對比(WCAG 相對亮度公式;半透明填色先與底色混合再算)

| 組合 | 深色 | 淺色 | 門檻 | 判定 |
|---|---|---|---|---|
| 次要文字 `--sec` / sheet 卡片 `--scard` | #AEAEB2 / #3A3A3C = 5.13 | #636366 / #FFFFFF = 5.99 | 4.5 | ✅ |
| 次要文字 / sheet 底 `--sheet` | 6.30 | #636366 / #F2F2F7 = 5.37 | 4.5 | ✅ |
| 主色連結(付費牆條款、「恢復購買」、「新增登入方式…」)/ sheet 底 | #3CCF9E / #2C2C2E = 7.04 | #0B7A5C / #F2F2F7 = 4.76 | 4.5 | ✅(淺色餘裕小) |
| 主色 / 卡片 | 5.73 | 5.31 | 4.5 | ✅ |
| 主要按鈕字 `--on` / `--accent` | 黑 / #3CCF9E = 10.61 | 白 / #0B7A5C = 5.31 | 4.5 | ✅ |
| 破壞性文字 `--redtext` / 卡片(登出、刪除、移除、撤銷、alert) | #FF8A82 / #3A3A3C = 4.98 | #D70015 / #FFFFFF = 5.38 | 4.5 | ✅ |
| `.dis` 灰字 / 卡片(帳號頁可點的鎖定列) | #8E8E93 / #3A3A3C = 3.48 | #8E8E93 / #FFFFFF = 3.26 | 4.5 | ✗(列可點，不能用停用豁免;應修 S9) |
| `btn-tint`(管理訂閱)字 / 填色 | 白 / #4E4E52 = 8.28 | 黑 / #E9E9EB = 17.3 | 4.5 | ✅ |
| Apple 鈕 / sheet 底(非文字) | 13.9 | 18.8 | 3 | ✅ |
| Google 鈕外框 `--sec` / sheet 底 | 6.30 | 5.37 | 3 | ✅ |
| 開關「開」/ 卡片 | 5.73 | 5.31 | 3 | ✅ |
| 開關「關」軌道 / 卡片 | 1.48 | 1.27 | 3 | ✗ 但與系統 UISwitch 相同，用系統元件即可(1.4.11 對未修改外觀的系統元件不要求;建議 R13) |
| 警告三角形 `--orange` / 卡片 | 5.52 | #FF9500 / #FFFFFF = 2.20 | 3 | ✗ 淺色不足;DESIGN.md 已接受系統橙只上在符號且一定配文字，資訊不只靠顏色，所以不列必修(建議 R14:淺色可改用高對比橙或加深) |

### 4.2 觸控目標
| 元件 | 尺寸 | 判定 |
|---|---|---|
| sheet 左上關閉／返回 `.ib` | 44×44 | ✅ |
| cell | ≥ 48 高 | ✅ |
| 「移除」「撤銷」「恢復購買」「稍後再說」`btn-plain` | 44 高 | ✅ |
| 主要按鈕、Apple／Google 鈕 | 50 高 | ✅ |
| alert 按鈕 | 48 高 | ✅ |
| **付費牆「恢復購買／使用條款／隱私權政策」** | 13px 文字連結，高約 17px,與上方「稍後再說」只隔 2px | ✗ 低於 Apple 44pt;WCAG 2.5.8 的 24px 間距例外在垂直方向也不成立(以連結中心 24px 圓會碰到上方按鈕)(應修 S15) |

---

## 5. 結論清單

### 必修(4)

| # | artboard | 證據 | 依據 | 修正 |
|---|---|---|---|---|
| M1 | 26「加入 1/4:建立會員」 | `appleBtn: '使用 Apple 加入'`,aria-label 卻宣稱是系統 Sign in with Apple 按鈕 | HIG-SIWA 自訂按鈕只允許 Sign in／Sign up／Continue with Apple;系統按鈕沒有「加入」 | 改用 `ASAuthorizationAppleIDButton` 的 `.signUp`(「使用 Apple 註冊」)或 `.continue`(「透過 Apple 繼續」);Google 鈕同步改成對應文字。登入頁維持 `.signIn` |
| M2 | 28「刪除會員確認」 | `aMsg` 只有「App Store 的訂閱要另外在設定中取消」,沒有取消路徑、沒說帳單繼續;不分 App Store／Google Play | AD「notify them that billing will continue through Apple and ask them to cancel their subscription before continuing」;HIG-MA 刪除段;G5.1.1(v) | 有有效 App Store 訂閱時，刪除前先出一頁(或 alert 前一步):「Purrdr Plus 會繼續由 Apple 收費，直到你取消」+「管理訂閱」(`showManageSubscriptions`)+「繼續刪除」;Google Play 訂閱者改寫「請在 Google Play 取消」(純文字、不放連結);沒有訂閱的不顯示這段 |
| M3 | 26「加入 2/4」→「3/4」「4/4」「完成」 | 「稍後再說」後沒有分支，第 3、4 步的開關可直接打開，完成頁寫死「Purrdr Plus 已開通」 | #402 故事 20、Implementation Decisions「通知與同步的『完成』必須同時滿足已登入且有 Plus」 | 略過 Plus 直接到完成頁的另一個版本(「會員已建立，之後可在帳號頁開通 Purrdr Plus」),或第 3、4 步顯示鎖定與「需要 Purrdr Plus」;完成頁文案依實際完成的步驟組 |
| M4 | 27 帳號頁(全部 9 種) | 沒有「通知裝置」區段(舊版 Shell.dc.html 有);「登入中的裝置」是工作階段，不含重新命名、遠端關閉通知 | #402 故事 42、畫面流程「帳號頁:…通知裝置…」;既有功能 `PushDevicesSection`(AGENTS.md #266) | 帳號頁加回「通知裝置」(或明確把它併進「登入中的裝置」並保留重新命名、只關通知不登出兩個動作，再回頭修規格);畫出清單與單一裝置頁 |

### 應修(22)

| # | artboard | 證據 | 依據 | 修正 |
|---|---|---|---|---|
| S1 | 26「加入 3/4」「4/4」 | 只畫了有 2 台主機的情況 | 新會員常沒有主機 | 畫「還沒有主機」:說明加主機後可在主機 tab 開，按鈕直接「繼續」 |
| S2 | 26「加入 2/4～4/4」 | 左上一律返回(`leftIcon: BK`),沒有關閉 | HIG-SH 要有明確關閉;第 2 步返回到已完成的建立會員是死路 | 第 2 步左上改 xmark(會員已建立，關閉即離開流程);第 3、4 步左上返回上一步，右上或左上加關閉二擇一並全流程一致 |
| S3 | 26「加入 2/4」 | 選月繳時按鈕仍是「開始免費試用」、註腳仍寫「試用結束後」 | G3.1.2(a) 不得誤導;S2 3.8(b) | 按鈕與註腳依選取方案與試用資格切換(「訂閱 [月費]/月」;沒有試用資格時拿掉「免費試用」) |
| S4 | 27「沒有 Plus」「已到期」→ 付費牆 | 帳號頁開的付費牆沒有畫 | #402 故事 10、畫面流程 | 畫獨立付費牆：左上返回帳號(推入)或 xmark,沒有步驟、沒有「稍後再說」,揭露與 26 相同 |
| S5 | 27 | 只有寬限期與已到期，沒有帳單重試期(`billing_retry`) | #402 訂閱規則把 billing_retry 算有效 | 決定重試期是否保有 Plus(Apple 沒設寬限時重試期不提供服務),畫對應狀態與「更新付款方式」 |
| S6 | 26「登入」「加入 1/4」 | 登入用了沒有會員的帳號、加入用了已是會員的帳號，兩種結果都沒畫 | #402 故事 1～3 的分流 | 登入失敗頁「找不到會員」+「用這個帳號加入」;加入遇到既有會員 → 告知「已登入既有會員」並直接到帳號頁(已有 Plus 時不顯示付費牆) |
| S7 | 26「加入 2/4」、27 | 購買處理中、Ask to Buy 等待核准(`.pending`)、後台確認前、恢復結果都沒畫 | #402 故事 34、11;StoreKit 購買結果 | 畫「處理中」「等待核准」「沒有可恢復的購買」「已恢復」 |
| S8 | 28「刪除會員確認」之後 | 沒有完成畫面 | HIG-MA「notify them when it's finished」 | 刪除後回到未登入選擇頁並顯示「會員已刪除」;需要時間時說明何時完成 |
| S9 | 27「沒有 Plus」「訂閱屬於其他會員」「已到期」、28 主機 tab | 帳號頁鎖定列套 `.dis` 而主機 tab 不套;「主機同步」是 `div`、「通知」是 `button`;可點列灰字 3.26:1 | WCAG 1.4.3;一致性 | 鎖定列一律可點(點了開付費牆或登入選擇)、主要文字用 `--text`、副標「需要 Purrdr Plus」用 `--sec`、列尾鎖頭;兩處相同 |
| S10 | 28 三個 alert、合併頁 | 「用 Face ID 轉移／登出／刪除會員／確認合併」寫死 | HIG-MA「Refer only to authentication methods that are available」;DESIGN.md App 鎖 | 依 `LAContext.biometryType` 換 Face ID／Touch ID／Optic ID,沒有生物辨識時「用裝置密碼…」;設計稿註明是動態文字 |
| S11 | 28「登入方式」「登入中的裝置」 | 移除、撤銷、新增登入方式沒有確認，只有註腳 | #402 故事 28;HIG-AL 破壞性動作要有 Cancel | 移除、撤銷各一個確認(標題說後果、破壞性按鈕「用 Face ID 移除／撤銷」、取消);只剩一種登入方式時「移除」停用並說明 |
| S12 | 27「轉移被擋下」 | `plusTitle: '無法轉移'` 加 `...ON`,看不到「已開通(Google Play)」 | 故事 9、19 | Plus 卡維持「已開通 · 透過 Google Play」,另以一行說明「這個 Apple 帳號的 App Store 訂閱無法轉移,因為…」 |
| S13 | 28「轉移訂閱確認」 | 「這支裝置的會員會取得 Plus」;沒說付款不變、原會員通知與同步停止 | G3.1.2 不得誤導;#402 轉移決策 | 「r***@icloud.com 會失去 Plus,通知與主機同步會停止。目前登入的 r***@gmail.com 會取得 Plus,之後的續訂也歸這個會員。付款仍由同一個 Apple 帳號支付，不會另外收費。」 |
| S14 | 27「訂閱屬於其他會員」 | 「這個 Apple ID 的訂閱」 | Apple 已改稱 Apple 帳號(Apple Account) | 改「這個 Apple 帳號的訂閱」;全稿同步 |
| S15 | 26「加入 2/4」 | 條款三連結 13px、高約 17px、與上方按鈕隔 2px | WCAG 2.5.8;HIG 44pt | 連結改成 44pt 高的 `btn-plain`(15pt),或拉開間距；「恢復購買」與條款分兩行 |
| S16 | 28「新增 Google 時發現已是會員」 | 把兩個既有會員合併 | #402 只定義「同一提供者同一 subject 只能屬於一個會員」與 email 自動合併，沒有手動合併兩個會員 | 回規格決定：要支援就補進 #402(資料、訂閱、主機、推播配對怎麼合),不支援就改成「這個 Google 帳號已屬於另一個會員，請先在那個會員移除它」 |
| S17 | (無) | 升級後第一次被要求重新登入，沒有說明 | #402 故事 40 | 選擇頁上方加一次性的說明「Purrdr 更新了會員系統，請再登入一次，之後不會再無故登出」 |
| S18 | 26「登入」「加入 1/4」 | Google 鈕只有文字 | GSI 品牌規範 | 加官方「G」標誌、用規定文字(「使用 Google 帳戶登入」或規範允許的繁中) |
| S19 | 26「加入 3/4」 | Ray Mac Mini 開關預設開 | 故事 22;開啟會在主機安裝外掛(ADR-0002 經同意) | 預設全關，由使用者開;開第一台時才請求系統通知權限 |
| S20 | 28 三個 alert | alert 內有 Face ID 圖示 | HIG-AL:只有 macOS、visionOS 的 alert 能放圖示 | 拿掉圖示，與 HostSub 一致;或改成 sheet(若真的需要圖示) |
| S21 | 27 帳號頁「通知」列 | 點進去的畫面沒畫 | 規格畫面流程 | 畫目的地(逐台主機開關的彙總，或導到主機 tab);與 M4 一起決定 |
| S22 | DESIGN.md | 仍寫 sheet 右上「完成」不用 xmark、方案用外框卡片、帳號頁不放「登入方式」註腳 | 設計規範與畫布不一致 | 定稿後同步 DESIGN.md(關閉位置、方案樣式、註腳規則) |

### 建議(14)

| # | artboard | 建議 |
|---|---|---|
| R1 | (送審) | App Review Notes 寫明 Plus 的通知與同步是帳號功能(後台推播配對、跨裝置同步),所以購買前要登入(G5.1.1(v)) |
| R2 | 26「未登入:選擇」 | 從 Plus 入口(主機 tab 的鎖定通知、帳號頁)進來時，選擇頁加一句「開通 Purrdr Plus 前要先登入，訂閱才能在你的其他裝置使用」(HIG-MA、故事 33) |
| R3 | 27「訂閱屬於其他會員」 | 拿掉「恢復購買」,避免反覆得到同樣結果 |
| R4 | 27「訂閱屬於其他會員」 | 鎖定列副標改「訂閱在另一個會員名下」 |
| R5 | 27 帳號頁會員卡 | 自己的 email 不必遮蔽;標出這支裝置用哪種方式登入(HIG-SIWA 建議登入後標示方式) |
| R6 | 26「加入 4/4」 | 同步開關預設關或按鈕改「開啟同步」,讓上傳主機資料是明確選擇 |
| R7 | 26 步驟「1 / 4」 | VoiceOver 念「第 1 步，共 4 步」;付費牆兩個方案包成一個有名稱的群組 |
| R8 | 28「新增 Google 時發現已是會員」 | 返回鍵 aria-label 改「返回登入方式」 |
| R9 | 28 登出、刪除 | HIG-AL 建議對刻意的動作用 action sheet(`confirmationDialog`);若維持 alert,與 HostSub 一致即可 |
| R10 | 28、HostSub | alert 遮罩改用 `--scrim` token |
| R11 | 28 主機 tab | `hostcap` 補螢幕圖示與 aria-label,與 Host.dc.html 相同 |
| R12 | 26 選擇頁、完成頁 | 在 DESIGN.md 寫明引導類畫面可放品牌與完成圖示 |
| R13 | 26、27 開關 | 實作一律用系統 Toggle(關閉軌道 1.27:1 是系統外觀，自繪會失去 1.4.11 豁免) |
| R14 | 27 警告三角形 | 淺色橙對白 2.20:1,可改用較深的橙或確保旁邊一定有文字(現在有) |
| (附) | 27「帳單寬限期」 | 補 Google Play 寬限期版本(純文字「請在 Google Play 更新付款方式」,沒有按鈕) |
| (附) | iPad | 規格是 Universal,帳號 sheet 在 iPad 的 form sheet 寬度未畫 |

---

## 6. 摘要
1. 必修 4 項：Apple 按鈕「使用 Apple 加入」不是允許的標題;刪除會員沒有在刪除前提供取消 App Store 訂閱的路徑;加入流程略過 Plus 後仍能開通知與同步;帳號頁少了規格要求的「通知裝置」。
2. 付費牆揭露(名稱、週期、價格、自動續訂、取消、條款與隱私權連結、恢復購買)齊全，但按鈕與註腳要依方案與試用資格切換，條款連結太小。
3. Google Play 訂閱在 iOS 只顯示來源、沒有購買與連結，不違反 3.1.1／3.1.3(b);Sign in with Apple 顯著度與顏色合規，只有標題要改。
4. 流程缺很多狀態：沒會員時按登入、購買處理中與等待核准、恢復結果、轉移成功、刪除完成、帳單重試期、升級後重新登入說明;第 2 步返回是死路。
5. 一致性大致跟著定稿(左上 xmark、cell、token、44pt),但鎖定列兩處樣式不同且可點列灰字只有 3.26:1、alert 放了 iOS 不支援的圖示、Face ID 寫死，DESIGN.md 也要同步更新。

---

## 7. 複驗(2026-11-22,修正版 15:18)

範圍：只複驗必修 M1～M4;順手修的項目只記錄看到的結果，不重做全面審查。方法同前(讀原始碼)。

**結論：必修已歸零。**

| # | 複驗證據 | 判定 |
|---|---|---|
| M1 Apple 按鈕標題 | AccFlow「加入 1/4」`appleBtn: '使用 Apple 註冊'`(= 系統 `.signUp` 的繁中標題)、`googleBtn: '使用 Google 註冊'`;「登入」維持「使用 Apple 登入」(`.signIn`)。按鈕大小、顏色、位置不變，仍符合 HIG-SIWA | ✅ 已修 |
| M2 刪除會員的訂閱處理 | AccSub 新增「刪除前:先處理 App Store 訂閱」:明寫「刪除會員不會取消訂閱,Apple 會繼續收費。請先取消訂閱，再繼續刪除」+「管理訂閱」+「繼續刪除會員」+「取消」;「刪除前:Google Play 訂閱」:同樣說明、沒有連結或按鈕(符合 3.1.3)。之後才是「刪除會員確認」alert。符合 AD「notify them that billing will continue through Apple and ask them to cancel … before continuing」與 HIG-MA 刪除段 | ✅ 已修 |
| M3 略過 Plus 後的分支 | AccFlow 新增「略過 Plus:3/4 通知鎖定」:兩台主機都是「需要 Purrdr Plus」+ 鎖頭(`role="img"`),沒有開關;按鈕「開通 Purrdr Plus」/「完成，之後再說」(直接到完成，不經第 4 步同步)。「略過 Plus:完成」`doneMsg` 改為「會員已建立。之後可以在帳號頁開通 Purrdr Plus,開通後才能收通知、同步主機清單」;完成頁文案依狀態(`doneMsg`)。第 2 步左上改 xmark(`leftLabel: '關閉,之後在帳號頁繼續'`),順帶解決應修 S2 的死路 | ✅ 已修 |
| M4 通知裝置 | AccPage 模板在「Plus 功能」之後固定有「通知裝置」區段(9 種狀態都有，不受條件控制),列「2 台 · 可改名或只關閉通知」;AccSub 新增「通知裝置」子頁(兩台裝置、chevron、註腳「點一下可以重新命名，或只關閉那支裝置的通知(不會登出)」)。與「登入中的裝置」分開，符合故事 42 | ✅ 已修 |

畫布：AccFlow 9 種 × 2 = 3910px、AccSub 10 種 × 2 = 4340px,`canvas.json` 的寬度已同步，版面不會重疊。

### 順手修的項目(看到的結果)

| 原項目 | 結果 |
|---|---|
| S15 付費牆連結 | ✅ 三個連結 `min-height:44px`、左右 8px 內距 |
| S20 alert 圖示 | ✅ 已拿掉 |
| S9 可點的鎖定列灰字 | ✅ 模板不再套 `.dis`(`featCls` 留在資料但沒用到，可刪) |
| S14 Apple ID | ✅ 改「Apple 帳號」 |
| S13 轉移文案 | ✅ 補「付款方式與續訂日不變」「原會員的通知與主機同步會停止」;alert 改「目前的會員」 |
| S12 轉移被擋下 | ◐ 標題改「已開通(透過 Google Play),無法轉移」✅;但副標重複一句:「一個會員只能有一個訂閱。一個會員只能有一個訂閱;」,要刪一句 |
| S10 Face ID 寫死 | ◐ alert 按鈕已不寫 Face ID,但新加的附註「按下後會用 Face ID 或密碼確認身分」仍是固定文字;合併頁「用 Face ID 確認合併」、登入方式與登入中的裝置註腳仍寫 Face ID。實作時依 `biometryType` 換字即可(HIG-MA),仍是應修 |
| S18 Google 標誌 | ◐ 加了白圓上的藍色字母「G」,不是 Google 官方四色標誌;實作要用官方素材(GSI) |

### 仍待處理(都不是必修)
- 加入頁 Apple 按鈕的 `aria-label` 仍寫「使用 Apple 登入(系統…)」,與畫面上的「使用 Apple 註冊」不一致(實作用系統按鈕會自帶正確的 VoiceOver 標籤，設計稿改一下即可)。
- 「略過 Plus:完成」標題仍是「設定完成」,可改「會員已建立」與文案一致。
- 首次審查的其他應修(S1、S3～S8、S11、S16、S17、S19、S21、S22)與建議項目沒有在這次範圍內，狀態不變。
