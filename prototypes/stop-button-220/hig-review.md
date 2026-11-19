# 停止鈕原型(#220)HIG 檢核:版面 B(狀態膠囊)

- 對象：`C:\Users\RayChiu\Downloads\purrdr-stop-button-prototype.html` 的版面 B(輸入列上方的狀態膠囊，含「停止」與 `⋯`),以及共通部分(選單、強制結束、結果提示、離線與唯讀)。使用者已選定 B,A 與 C 不在範圍內。
- 專案規則：`purrdr.ios-220/DESIGN.md`(衝突時以專案規則為準，並在文中標出)
- 來源：2026-11-19 從 developer.apple.com 下載的 HIG 頁面 JSON(與網頁同一份內容)與 SwiftUI 文件。引文保留英文原文。
- 標記：**〔HIG〕** 可直接追到引文；**〔DESIGN〕** 來自專案規範；**〔推論〕** 是根據規則做的延伸判斷，HIG 沒有直接寫。
- 單位：原型的 CSS px 在 390 寬手機框內等同 pt。

---

## 1. 適用的 HIG 規則

### 1.1 Buttons — https://developer.apple.com/design/human-interface-guidelines/buttons

| # | 規則 | 原文關鍵句 |
|---|---|---|
| B1 | 命中區至少 44×44 pt | "a button needs a hit region of at least 44x44 pt" |
| B2 | 自訂按鈕要有按下狀態 | "Always include a press state for a custom button." |
| B3 | 每個畫面 prominent 按鈕一到兩個 | "Keep the number of prominent buttons to one or two per view." |
| B5 | 熟悉的動作配熟悉的圖示；文字比較清楚時用文字 | "Try to associate familiar actions with familiar icons." / "Consider using text when a short label communicates more clearly than an icon." |
| B6 | destructive 是會造成資料毀損的動作，用系統紅 | "Destructive. The button performs an action that can result in data destruction." / "a destructive button uses the system red color" |
| B7 | 不要把 primary 角色給破壞性動作 | "Don't assign the primary role to a button that performs a destructive action" |
| B8 | iOS:動作不會立刻完成時，按鈕內顯示 activity indicator 並換成「進行中」文字 | "Configure a button to display an activity indicator when you need to provide feedback about an action that doesn't instantly complete." / "the label "Checkout" could change to "Checking out…"" |

### 1.2 Toolbars(導覽列，B 保留了 `↻` 與 `⋯`) — https://developer.apple.com/design/human-interface-guidelines/toolbars

| # | 規則 | 原文關鍵句 |
|---|---|---|
| T2 | 少用工具列背景與上色控制項 | "Reduce the use of toolbar backgrounds and tinted controls." |
| T4 | 用沒有外框的系統符號 | "Prefer system-provided symbols without borders." / "Borders (like outlined circle symbols) aren't necessary because the section provides a visible container" |
| T7 | More 選單只在真的需要時加 | "Try to include all actions in the toolbar if possible, and only add this menu if you really need it." |

### 1.3 Menus／Pull-down buttons／Context menus／Standard icons

- Menus — https://developer.apple.com/design/human-interface-guidelines/menus
  - M1 不可用的項目要顯示為停用："An unavailable menu item often appears dimmed and doesn't respond to interactions."
  - M2 同一組的圖示要一致："provide icons for all menu items in a group, or none of them."
- Pull-down buttons — https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons
  - P1 **破壞性項目要標示並請使用者確認**:"Let people know when a pull-down button's menu item is destructive, and ask them to confirm their intent. … When people choose a destructive action, the system displays an Action sheets (iOS) or Popovers (iPadOS) in which they can confirm their choice or cancel the action."
  - P2 選單至少三項才值得："listing a minimum of three items can help the interaction feel worthwhile. If you need to list only one or two items, consider using alternative components"
  - P3 選單的內容要跟按鈕的動作直接相關："Use a pull-down button to present commands or items that are directly related to the button's action."
  - P4 More 按鈕會降低可發現性："the ellipsis icon doesn't necessarily help them predict its contents."
- Context menus — https://developer.apple.com/design/human-interface-guidelines/context-menus
  - X1 破壞性項目放最後並標 destructive:"list them at the end of the menu and identify them as destructive"
- Standard icons — https://developer.apple.com/design/human-interface-guidelines/icons
  - I1 More 的標準符號是 `ellipsis`,Cancel／Close 是 `xmark`(表格 "More | `ellipsis`"、"Cancel | `xmark`")。表格裡沒有 Stop 與 Reload。

### 1.4 Progress indicators — https://developer.apple.com/design/human-interface-guidelines/progress-indicators

- PI1 讓指示器一直動，停住要說明原因："Keep progress indicators moving … If a process stalls for some reason, provide feedback that helps people understand the problem and what they can do about it."
- PI2 進度指示放在固定位置："Display a progress indicator in a consistent location."
- PI3 描述要精確："Avoid vague terms like loading or authenticating because they seldom add value."
- PI4 **能中斷就給中斷鈕；中斷會造成損失時用 alert 確認**:"If people can interrupt a process without causing negative side effects, include a Cancel button." / "When canceling a process results in lost progress, it's helpful to provide an alert that includes an option to confirm the cancellation or resume the process."

### 1.5 Feedback／Alerts／Action sheets

- Feedback — https://developer.apple.com/design/human-interface-guidelines/feedback
  - F1 狀態回饋放在它描述的東西附近："When status feedback is available near the items it describes, people get important information without having to take action or leave their current context."
  - F2 只在**非預期且不可逆**的資料損失時警告："Warn people when they initiate a task that can cause data loss that's unexpected and irreversible. In contrast, don't warn people when data loss is the expected result of their action."
  - F3 做不到時要說明原因："Show people when a command can't be carried out and help them understand why."
  - F4 用多種方式傳達："when you provide feedback using color, text, sound, and haptics, people can receive it whether they silence their device, look away from the screen, or use VoiceOver."
  - F5 重要動作完成時才確認成功："reserve this type of confirmation for activities that are sufficiently important"
- Alerts — https://developer.apple.com/design/human-interface-guidelines/alerts
  - A1 只提供資訊的情況不要用 alert:"Avoid using an alert merely to provide information. … when a server connection is unavailable, Mail displays an indicator"
  - A2 少見且不可復原的破壞性動作才需要 alert:"when people take an uncommon destructive action that they can't undo, it's important to display an alert"
  - A3 有破壞性動作就要有「取消」:"If there's a destructive action, include a Cancel button"
  - A4 iOS:針對使用者**主動**動作的選擇用 action sheet:"Use an action sheet — not an alert — to offer choices related to an intentional action."
- Action sheets — https://developer.apple.com/design/human-interface-guidelines/action-sheets
  - AS1 破壞性選項用 destructive 樣式、放上方；「取消」在底部："Use the destructive style for buttons that perform destructive actions, and place these buttons at the top" / "Place the Cancel button at the bottom"

### 1.6 Color — https://developer.apple.com/design/human-interface-guidelines/color

- C1 同一個顏色不要代表不同意思："Avoid using the same color to mean different things."
- C2 不只靠顏色傳達："Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information."
- C3 自訂色要有淺色、深色與各自的高對比版本："supply light and dark variants, and an increased contrast option for each variant"
- C4 Liquid Glass 上少用顏色，不要多顆控制項都上色背景："To emphasize primary actions, apply color to the background rather than to symbols or text." / "Refrain from adding color to the background of multiple controls."

### 1.7 Accessibility／VoiceOver／Typography

- Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility
  - AX1 對比:17pt 以下文字 4.5:1,18pt 以上或粗體 3:1(表格 "Up to 17 pts | All | 4.5:1")。
  - AX2 控制項尺寸 iOS 預設 44×44 pt、最小 28×28 pt。
  - AX3 間距："add about 12 points of padding around elements that include a bezel. For elements without a bezel, about 24 points of padding"
  - AX4 Reduce Motion:"ensure your app or game responds by reducing automatic and repetitive animations"
- VoiceOver — https://developer.apple.com/design/human-interface-guidelines/voiceover
  - VO1 label 要隨介面更新："Be sure to keep your descriptions up-to-date as your app's interface and content change."
  - VO2 畫面內容變化要通知:"Inform VoiceOver when visible content or layout changes occur."
  - VO3(SwiftUI `accessibilityLabel`)label 不要重複「按鈕」:"don't use the label "Play button" because a button already has a trait that identifies it as a button." — https://developer.apple.com/documentation/swiftui/view/accessibilitylabel(_:)
- Typography — https://developer.apple.com/design/human-interface-guidelines/typography
  - TY1 用 text style 支援 Dynamic Type,盡量不截斷："Keep text truncation to a minimum as font size increases."

### 1.8 Materials(Liquid Glass)／Virtual keyboards／SF Symbols

- Materials — https://developer.apple.com/design/human-interface-guidelines/materials
  - G1 Liquid Glass 只在控制與導覽層:"Don't use Liquid Glass in the content layer."
  - G2 少用："Use Liquid Glass effects sparingly. … Limit these effects to the most important functional elements"
  - G3 有文字的元件用 regular 變體："Use the regular variant when … components have a significant amount of text"
- Virtual keyboards — https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards
  - K1 鍵盤出現時重要介面要看得到："helps you keep important parts of your interface visible while the virtual keyboard is onscreen."
  - K2 鍵盤上方的自訂控制項要跟當下任務相關，風格與其他 Liquid Glass 一致："make sure they're relevant to the current task … apply Liquid Glass to the view that contains your controls to maintain consistency."
- SF Symbols — https://developer.apple.com/design/human-interface-guidelines/sf-symbols
  - S1 "Symbols that use an enclosing shape … can improve legibility at small sizes." / fill 變體 "give a symbol more visual emphasis"

### 1.9 SwiftUI 官方文件

| API | 重點 | URL |
|---|---|---|
| `ButtonRole.destructive`(iOS 15) | "Use this role for a button that deletes user data, or performs an irreversible operation." | https://developer.apple.com/documentation/swiftui/buttonrole/destructive |
| `ButtonRole.cancel`(iOS 15) | "a cancel action implies progress will be lost" | https://developer.apple.com/documentation/swiftui/buttonrole/cancel |
| `ButtonRole.close`(iOS 26) | "Unlike a cancel operation, a close operation doesn't lose progress for a user." | https://developer.apple.com/documentation/swiftui/buttonrole/close |
| `confirmationDialog` | "the system displays a confirmation dialog with a cancel action and a destructive action." / "Dialogs include a standard dismiss action by default." | https://developer.apple.com/documentation/swiftui/view/confirmationdialog(_:ispresented:titlevisibility:actions:) |
| `glassEffect(_:in:)`(iOS 26) | 預設 regular 變體，通常搭配 `GlassEffectContainer` | https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:) |
| `sensoryFeedback(_:trigger:)`(iOS 17) | 值改變時播放觸覺回饋 | https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:) |

---

## 2. 不合規處與修正

### 2.0 角色判定

| 動作 | 送出的鍵 | 角色 | 是否確認 |
|---|---|---|---|
| 停止 | Esc | **不是 destructive**。〔推論〕Esc 中斷這一輪，已產生的內容留著，屬 PI4「可中斷且沒有負面副作用」→ 給一顆中斷鈕即可。 | **不確認**(F2:停下來是使用者預期的結果)。 |
| 強制結束 | Ctrl-C | **destructive**。〔推論〕Ctrl-C 可能終止進行中的工具呼叫或程式、不可復原，符合 `ButtonRole.destructive` 的 "performs an irreversible operation"。 | **要確認**(P1 + A2)。用 action sheet(A4,SwiftUI `confirmationDialog`),不用 alert;確認鈕標 destructive、「取消」在底部(AS1)。 |

### 2.1 膠囊本身(版面 B)

| # | 問題 | 依據 | 修正 |
|---|---|---|---|
| B-1 | **膠囊按鈕約 28pt 高**(13pt 字 + 上下 6pt padding),`■ 停止` 與 `⋯` 相距 8pt。停止旁邊就是藏著強制結束的選單，誤觸代價高。 | B1、AX2、AX3 | 膠囊列高 ≥ 44pt,停止與 `⋯` 命中區各 ≥ 44×44,兩鈕間距 ≥ 12pt。SwiftUI:`.frame(minHeight: 44)` + `.contentShape(.rect)`。 |
| B-2 | **兩個「工作中」指示**:膠囊的「Claude 工作中…」與對話底部的「● ● ● Claude 正在回覆」同時出現;DESIGN 也規定工作中指示在對話最底下的內容層(即時預覽、3×3 點陣、經過時間)。 | PI2;〔DESIGN〕「對話」段 | 〔推論〕保留 DESIGN 的內容層指示，膠囊的左側改成簡短狀態(例如只放停止鈕與結果)，不再重複「工作中…」與 spinner。若要保留膠囊的狀態字，就把對話底部的指示拿掉，二擇一。 |
| B-3 | **膠囊屬於哪一層不明確**:它有按鈕(控制層)，卻用不透明白底 + 陰影，跟玻璃輸入卡片並排成兩個不同材質的浮層。 | G1、G2、G3、K2;〔DESIGN〕玻璃只在導覽層與控制層、自訂玻璃只用 regular 並包 `GlassEffectContainer` | 〔推論〕膠囊算控制層：跟輸入卡片放進同一個 `GlassEffectContainer`,`glassEffect(.regular)`;或做成輸入卡片內最上面的一列，不另外浮一層(較省高度，也符合 G2 少用)。 |
| B-4 | **工作中有兩顆紅底按鈕**(膠囊「停止」+ 送出)。 | B3、C4;〔DESIGN〕每個畫面 prominent 按鈕最多 2 個、送出是輸入列唯一 tinted 主要動作 | 數量在上限內，但 C4 說不要多顆控制項上色背景，DESIGN 也說送出是唯一 tinted 動作。〔推論〕停止改成中性 bordered(`.buttonStyle(.bordered)`)+ `stop.fill` 符號 + 文字「停止」,送出維持唯一紅底。停止不是 destructive(2.0),不需要紅色。 |
| B-5 | **膠囊的 `⋯` 打開的選單出現在畫面右上角**(原型把選單畫在導覽列下)，離按下的位置很遠；而且導覽列也有一個 `⋯`,兩顆 `⋯` 開同一個選單。 | P3、T7、P4 | 〔推論〕只留一個入口。建議：膠囊的 `⋯` 改成 SwiftUI `Menu`,選單從膠囊本身展開，內容只放跟停止直接相關的項目(強制結束);導覽列的 `⋯` 放終端機、重新載入等其他項目，不再放強制結束。若膠囊選單只剩強制結束一項(P2),改成**長按停止鈕**出現同一個選單(`Menu(primaryAction:)`),並在結果提示「仍在工作」時提供入口(見 2.3),讓它在主介面看得到。 |
| B-6 | **停止中時膠囊的停止鈕停用，文字仍是「停止」**,左側另有「停止中…」。 | B8、VO1 | 停用的停止鈕直接拿掉，只留左側系統 `ProgressView()` + 「正在停止…」;或停止鈕內換成 `ProgressView` + 「正在停止…」並 `.disabled(true)`。兩種擇一，不要同時出現。 |
| B-7 | **膠囊多佔一列高度**,鍵盤出現時壓縮對話。 | K1;〔DESIGN〕鍵盤讓位規則(#196,對話至少保留 132pt) | 膠囊要加入 `ComposerKeyboardLayout` 的讓位順序。〔推論〕它是唯一的停止入口，不能被拿掉：排在輸入列之後、建議提示詞之前；空間不夠時先收成只有停止鈕的一行(44pt)。 |
| B-8 | **結果態的關閉鈕 `✕`** 是 ghost 小鈕，沒有 label。 | I1、B1、VO1 | `Button(role: .close)`(iOS 26)搭 `Image(systemName: "xmark")`、label「關閉」、44pt 命中區。 |
| B-9 | **停止鈕的方塊是文字字元 `■`**,VoiceOver 會念出來。 | B5、VO3 | 用 `Label("停止", systemImage: "stop.fill")`,VoiceOver label「停止 Claude」(不加「按鈕」)。符號名稱請在 SF Symbols app 確認。 |
| B-10 | 〔DESIGN 衝突〕DESIGN「對話」段寫「標題列右側：不在工作中『重新載入』,工作中『停止』(長按選單『強制結束』)」。 | — | 採 B 要改寫這段：停止移到輸入列上方的膠囊，標題列右側只剩重新載入與 `⋯`;強制結束的入口依 B-5 的決定寫清楚。鍵盤讓位段也要加入膠囊。 |

### 2.2 選單與強制結束

| # | 問題 | 依據 | 修正 |
|---|---|---|---|
| 選-1 | **強制結束沒有確認**:選單項目點了直接執行；「仍在工作」提示裡的「強制結束」也直接執行。 | P1、A2、A4、AS1 | 兩個入口都改成開 `confirmationDialog`:標題「強制結束 Claude?」、訊息一行「會送出 Ctrl-C,進行中的工具呼叫可能中斷。」、`Button("強制結束", role: .destructive)`;取消由系統提供。 |
| 選-2 | **提示裡的「強制結束」用中性 ghost 樣式**,看起來跟「再試一次」「重新載入」一樣安全。 | B6、X1 | `Button("強制結束…", role: .destructive)`,系統套系統紅。〔推論〕結尾加「…」表示後面還有確認步驟(Menus 頁:需要更多輸入時加刪節號；確認對話框是否算「更多輸入」HIG 沒有明說)。 |
| 選-3 | **破壞性項目用品牌紅**(`--bad` 等於品牌紅 #D80521)。 | C1、B6;〔DESIGN〕「真正的錯誤與刪除用系統 `.red`／destructive role,不用品牌紅」 | 選單項目用 `role: .destructive`,不手動上色。 |
| 選-4 | **圖示**:強制結束用 `⏻`(電源)、終端機用 `⌨︎` 字元。 | B5、M2 | 〔推論〕電源符號會被讀成「關機」;改 SF Symbol `xmark.octagon`,終端機用 `apple.terminal`;同一組要嘛全部有圖示、要嘛都沒有。 |
| 選-5 | **導覽列的 `↻`、`⋯` 包在灰色圓底**。 | T2、T4、I1 | iOS 26 工具列項目由系統套玻璃，不加自訂底；符號用 `ellipsis`(標準 More)、`arrow.clockwise`(〔推論〕HIG 沒有 Reload 的標準符號)。 |
| 選-6 | **「需要你」時強制結束停用，說明文字做成選單裡的一列**。 | M1、F3 | 停用並顯示是對的(一般選單要讓人看到不可用的項目)。說明改成 `Section` 的 footer 文字，不要看起來像可點的項目。 |

### 2.3 結果提示(B 寫在膠囊內)

| # | 問題 | 依據 | 修正 |
|---|---|---|---|
| 結-1 | **位置**:結果寫在膠囊裡，緊鄰停止的地方。 | F1、PI2 | 合規，維持。 |
| 結-2 | **對比不足**:淺色 `--warn` #C25E00 對膠囊白底 4.29:1、對 #F2F2F7 3.84:1;`--ok` #248A3D 對白底 4.40:1、對 #F2F2F7 3.94:1;都是 13pt 文字，需要 4.5:1。也沒有高對比值。 | AX1、C3;〔DESIGN〕「一般 ≥ 4.5:1、高對比 ≥ 7:1」、四個值都要有對比測試 | 加深淺色值到 ≥ 4.5:1(對膠囊實際背景計算，若改成玻璃要對取樣不穩定的情況另外處理)，補兩個高對比值並加進 `AccessibleColorsTests`;或文字一律 `secondaryText`,狀態色只放在前導符號(〔推論〕符號是非文字圖形，3:1 即可)。 |
| 結-3 | **錯誤用品牌紅**(「送不出」)。 | C1;〔DESIGN〕錯誤文字用 `errorText` | 改 `errorText`,前導符號 `exclamationmark.triangle.fill`(C2:不只靠顏色)。 |
| 結-4 | **長句在窄膠囊裡**:「已送出停止，但讀不到狀態，無法確認是否已停止。」+ 動作鈕 + `✕` 在 390 寬很擠，AX 字級必定截斷。 | TY1;〔DESIGN〕「文字一律用 text style,支援到 AX5 不截斷」 | 文字用 `.footnote` text style、`lineLimit(nil)`;句子精簡成「無法確認是否已停止」,原因放第二行；AX 字級時動作鈕換到文字下方(`ViewThatFits` 或 `AnyLayout` 切換水平／垂直)。 |
| 結-5 | **提示的動作鈕命中區不足**(約 28pt)。 | B1 | 同 B-1,≥ 44pt。 |
| 結-6 | **沒有觸覺與 VoiceOver 公告**。 | F4、VO2 | 已停止 `.sensoryFeedback(.success, trigger:)`、送不出 `.error`、仍在工作／無法確認 `.warning`;結果出現時 `AccessibilityNotification.Announcement(...).post()`。 |
| 結-7 | **「已停止」要手動按 `✕` 關閉**。 | F5 | 〔推論〕成功是使用者預期的結果，短暫顯示後自動收起(或在狀態變閒置後收起);失敗類(送不出、仍在工作、無法確認)留到使用者處理或狀態改變。DESIGN 禁止的是「連線中斷」用自動消失提示，不包括成功結果。 |
| 結-8 | **停止中一直轉**,沒有上限。 | PI1 | 〔推論〕超過一段時間(例如 10 秒)仍沒有變化就轉成「仍在工作」結果，提供強制結束入口，不讓指示器停在原地。 |
| 結-9 | **spinner 是自畫的 CSS 圓圈**。 | AX4 | 用系統 `ProgressView()`。 |
| 結-10 | **「無法確認」不當成功**,動作是「重新載入」。 | F3、PI1 | 合規，維持。 |

### 2.4 離線與唯讀

| # | 問題 | 依據 | 修正 |
|---|---|---|---|
| 離-1 | 離線用頂端橫幅 +「再試一次」,不用 alert。 | A1;〔DESIGN〕「連線中斷」段 | 合規，維持。 |
| 離-2 | **離線時膠囊與停止鈕直接消失**,沒有說明為什麼不能停。 | F3 | 〔推論〕如果斷線前是工作中，橫幅多一句「重新連上後才能停止」;DESIGN「不再顯示斷線前的工作中」維持。 |
| 離-3 | **橫幅的「再試一次」**是 13pt 文字、沒有 padding。 | B1 | 命中區 ≥ 44pt;紅點旁有文字，合規(C2)。 |
| 離-4 | 離線時強制結束停用。 | M1 | 合規。 |
| 唯-1 | 唯讀時膠囊、停止與強制結束都不顯示，橫幅說明「不能送訊息或停止」。 | F3 | 合規。 |
| 唯-2 | **唯讀時導覽列 `⋯` 只剩「終端機」一項**。 | P2 | 〔推論〕只剩一項時不要用選單，改成直接的終端機按鈕。 |

---

## 3. 依 HIG 對版面 B 的整體評價

- **符合 HIG 的地方**:狀態、停止與結果放在同一處，靠近使用者正在看的輸入列(F1);送出鈕不被佔走，工作中仍能打字;停止不需要確認(F2、PI4);離線用橫幅不用 alert(A1);「無法確認」不當成功、「需要你」不中斷且說明原因(F3)。
- **一定要修的(HIG 明文)**:膠囊按鈕與提示動作鈕命中區小於 44pt(B1);強制結束沒有確認也沒有 destructive 角色(P1、B6);紅色一色多用(C1);警告與成功文字對比不足(AX1);長句截斷(TY1);label 與公告(VO1、VO2)。
- **要做的設計決定(HIG 給原則，細節是推論)**:
  1. 工作中指示只留一個(PI2):膠囊或對話底部，二擇一。
  2. 膠囊的材質與層級(G1、G2):建議併入輸入卡片的 `GlassEffectContainer`。
  3. 強制結束的入口(P2、P3):建議長按停止鈕的選單，加上「仍在工作」提示裡的按鈕，兩處都走同一個確認對話框；導覽列 `⋯` 不放強制結束。
  4. 停止鈕改中性樣式，讓送出維持唯一紅底(C4、DESIGN)。
  5. 鍵盤讓位：膠囊排在輸入列之後、建議提示詞之前，空間不夠時收成一行(K1、DESIGN #196)。
- **DESIGN.md 要同步改**:「對話」段的停止位置與強制結束入口、「鍵盤出現時的讓位」段加入膠囊。

## 4. 查不到或沒有一手依據的事項

- HIG 沒有 Stop 與 Reload 的標準符號(Standard icons 表格只有 More、Cancel、Close 等)。本文的 `stop.fill`、`arrow.clockwise`、`xmark.octagon`、`apple.terminal`、`exclamationmark.triangle.fill` 是〔推論〕,名稱請在 SF Symbols app 確認存在與 iOS 版本。
- HIG 沒有「狀態膠囊」或 toast 元件，也沒有拇指可及範圍的條文。
- Liquid Glass 在 HIG 沒有獨立頁(`liquid-glass` 頁面 JSON 不存在)，規則散在 Materials、Color、Toolbars、Buttons 的 2025-06／2025-12 更新。
