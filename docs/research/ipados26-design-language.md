# iPadOS 26 平板設計語言(給 Purrdr iPad 版重新設計用)

> 研究日期:2026-11-24。所有出處取得日期皆為 **2026-11-24**,以下不逐條重複。
> 範圍：只寫 iPad 特有或 iPad 上跟 iPhone 不同的部分。Liquid Glass 材質本身、tab bar／toolbar／sheet／選單在 iPhone 上的結論見 `docs/research/ios27-design-language.md`,這裡不重複。
> 只採一手來源:HIG、WWDC25／WWDC26 session 逐字稿、iOS & iPadOS 26／27 Release Notes、SwiftUI／UIKit API 文件。
> HIG 頁面以 developer.apple.com 的 JSON 資料端點(`/tutorials/data/design/human-interface-guidelines/<頁>.json`)取全文;API 可用版本取自 `/tutorials/data/documentation/<路徑>.json` 的 `platforms`;WWDC 逐字稿取自 session 頁面的 transcript 區塊。
> 標記:**【26】** iPadOS 26 就能用(含更早就有、Purrdr 最低版本已涵蓋的 API);**【27】** iPadOS 27 SDK 才有或 iPadOS 27 才改變(要 `if #available(iOS 27, *)`,或用 Xcode 27 建置就自動生效);**【未證實】** 查不到一手依據;**【推論】** 由一手事實推出的建議，不是 Apple 原文。

---

## 結論摘要(Purrdr 平板畫面的設計建議)

整體前提:iPadOS 26 起 iPad 有兩種多工模式——**全螢幕**(視窗填滿螢幕、用 app switcher 切換)與**視窗化**(可自由調整大小、可多個視窗並排，類似 macOS),使用者在「多工與手勢」設定選擇;**app 無法控制、也收不到使用者選了哪一種**。【26】所以 iPad 版要以「任意寬度」為前提設計，只看 size class 與實際可用寬度，不看裝置、不看方向。iPadOS 27 更明說 idiom 與 interface orientation「對版面決策不再有意義」。【27】

### 1. 整體骨架(主機／Agent 列表 → 聊天 → 詳細)
- HIG:sidebar 最多兩層;資料超過兩層時，用 split view 在 sidebar 與 detail 之間放一個內容列表。【26】Purrdr 的層級是「主機(workspace)→ Agent → 對話」,正好是 HIG 說的三欄情境——**sidebar 放主機與 workspace、內容欄放 Agent 列表、detail 放聊天**,目前 `TopNavigationView` 的三欄 `NavigationSplitView` 方向正確。【推論】
- 第三欄的「詳細」(檔案、變更、方案用量這類**跟著選取的聊天走的補充資訊**)改用 `.inspector`:regular 寬度是尾端欄、compact 自動變成 sheet,且框架會還原它的開關狀態;再加 `InspectorCommands` 讓選單列有「顯示／隱藏 Inspector」與快捷鍵。【26】→ 比自己做第四欄或 sheet 更符合 iPad 慣例。【推論】
- WWDC25〈Elevate the design of your iPad app〉建議「不確定就先用 tab bar」,而且 sidebar 與 tab bar 可以互相 morph。【26】Purrdr 若 iPhone 版改成 5 個 tab(見 iPhone 研究),iPad 用同一個 `TabView` 加 `.tabViewStyle(.sidebarAdaptable)`:regular 寬度時 tab bar 在**頂部**、可切成 sidebar,視窗縮窄時自動變回 tab bar。【26】但 sidebarAdaptable 的 sidebar 是「tab 清單」,不是三欄的導覽列;Agent 列表 → 聊天的兩欄仍要放在「聊天」tab 裡面。HIG 只在 tvOS／visionOS 段落寫「可以在 tab 裡用 sidebar 做次要導覽，選 sidebar 項目時不要切換 tab」,**iPad 段落沒有明文**支持 tab 裡再套 `NavigationSplitView`。【未證實】→ 兩條路要在設計稿上擇一並寫 ADR:(A) 保留現行三欄 `NavigationSplitView`(sidebar = 主機，iPad 沒有 tab bar);(B) `sidebarAdaptable` TabView,聊天 tab 內是兩欄。(A) 改動小、最貼近 HIG 的三欄說法;(B) 與 iPhone 5 tab 一致、iPad 選單列 View 選單可直接列 tab。【推論】
- 版面縮放要「非破壞性」:縮小視窗時收欄，放大後回到原本狀態，不要因為一次縮小就永久改掉版面。【26】

### 2. 視窗與多視窗
- **視窗控制鈕(紅黃綠，Apple 稱 window controls)在工具列的前緣**;系統元件會自動讓開。不要把按鈕放在工具列最前緣，自訂的頂部列要用含視窗控制鈕的 layout guide 避開。沒更新的 app 系統會在工具列上方多保留一條安全區放控制鈕——那只是相容模式，會浪費內容空間。【26】→ Purrdr 一律用標準 `toolbar`,不要自畫頂部列;Pane 終端機視窗的頂部若有自訂膠囊，要避開前緣。【推論】
- **每份「文件」開一個新視窗**,不要在唯一的視窗裡原地替換;視窗要有描述性的名稱(App 選單裡會列出所有開著的視窗)。【26】→ 聊天與 Pane 終端機已是 `WindowGroup(for: PaneWindow.self)`,要確認每個視窗的 `navigationTitle` 是 Agent／Pane 名稱(不是 app 名稱),副標用 `navigationSubtitle` 放主機。【推論】
- 不要預設就開新視窗;提供「在新視窗打開」讓使用者選(context menu 或 File 選單),也可支援捏合手勢開新視窗。【26】
- 視窗用詞一律叫「視窗」,不要叫 scene。【26】
- **最小視窗尺寸**:HIG 與 API 文件都**沒有公布 iPad 視窗的系統最小寬高**。【未證實】可用 `UISceneSizeRestrictions`(UIKit,iOS 13+)或 SwiftUI 內容的 `frame(minWidth:minHeight:)` 配合預設的 `windowResizability(.contentMinSize)` 自訂下限;WWDC25 範例是最小寬度 500 pt,但同時提醒「不要要求會限制欄數的寬度」。【26】→ Purrdr 不要設大的最小寬度，讓各畫面在 iPhone 寬度也能用(三欄會自動收成一疊)。【推論】
- **`UIRequiresFullScreen`**:iPadOS 26 標為 deprecated,「未來版本會忽略」;設了它在視窗化模式下系統會**縮放**畫面而不是改 scene 大小。iOS 27 SDK 起它改為「離散縮放」(每次調整大小換一個新的 `UIScreen` 設定),並在 iPhone 上被尊重(給遊戲用)。【26】【27】Purrdr 沒有設這個 key(已查 `project.pbxproj`),也不該加。
- iOS 27 SDK 起「支援的方向不含全部四個」**不再**讓 iPad app 失去連續縮放;方向在可調整大小的環境下被忽略。【27】
- iPadOS 27 視窗不在最前面時，系統自動把圖示與文字調暗;自訂元件用 `appearsActive` 環境值跟著調暗。【27】(`appearsActive` 本身 iOS 18 就有【26】)
- iOS 27 新增 `UISceneClosureConfirmation`／`UIWindowScene.closureConfirmation`:關閉視窗會銷毀 scene 前先跳確認。【27】Pane 終端機視窗關掉不會結束電腦上的 Pane,**不需要**確認。【推論】

### 3. 選單列(menu bar)
- iPadOS 26 起**每個 app 都有選單列**:指標移到螢幕頂端或手指往下滑叫出;全螢幕時視窗控制鈕在選單列裡;選單置中、沒有 Apple 選單與 menu bar extras。【26】
- SwiftUI 的 `commands`／`CommandMenu` 在 iPad 產生與 macOS 相同的選單列。【26】Purrdr 已有 `PurrdrCommands`(新視窗 ⌥⌘N、`CommandMenu("Agents")`、Esc)。
- 建議內容(**事實**來自 HIG／WWDC25 208,**對應到 Purrdr** 的部分是【推論】):
  - **App 選單**:系統的「設定…」保留給 iPadOS 設定 app 裡的 Purrdr 頁;app 自己的設定頁另開一項放在它正下方。【26】
  - **File**:新增聊天(⌘N)、新視窗、在新視窗打開、關閉(⌘W 預設關閉 window scene)。
  - **Edit**:系統標準項目 + `TextEditingCommands`。
  - **View**:**每個 tab 一項並給快捷鍵**(HIG 與 WWDC25 208 都點名);「顯示／隱藏 sidebar」(`SidebarCommands`)、「顯示／隱藏 Inspector」(`InspectorCommands`);Pane 終端機的大小模式切換。
  - **App 專屬選單**(放在 View 與 Window 之間，依層級排):「主機」→「Agent」(送出、停止、回答…)。選單項目依使用頻率排、不照字母;相關的分段;太長就收子選單(iPad 選單列的列高比 Mac 高，HIG 建議比 Mac 更常用子選單)。
  - **Window**:系統自動補上 tiling 指令與所有開著的視窗清單。
- **不要隱藏選單或項目**,不能用時 disable;整個選單都不能用也不要藏。【26】
- 選單列常是隱藏的，**所有功能都要能從畫面上做到**,不要把選單列當雜物間;只在接硬體鍵盤時才有的動態選單項目，一定要有其他做法。【26】
- iPadOS 27 選單列預設**大多不顯示圖示**(SwiftUI 隱藏 symbol image;代表物件或概念的項目用 `labelStyle(.titleAndIcon)` 強制顯示，UIKit 用 `preferredImageVisibility`);Settings、Share、Print 這類系統項目仍自動有圖示。【27】→ Purrdr 的選單列只給「主機」這類代表物件的項目留圖示。【推論】

### 4. 鍵盤
- iPad 使用者常接實體鍵盤。自訂快捷鍵只給**最常用**的 app 專屬指令;**以 Command 為主修飾鍵**,Shift 為輔、Option 少用、**避免 Control**(系統大量使用);多個修飾鍵依 Control、Option、Shift、Command 順序列出。【26】
- **Purrdr 的 Pane 終端機與登入 Shell 需要把 Control 組合鍵原封送到電腦**——app 的快捷鍵只用 ⌘,不要用 ⌃,避免搶走 ⌃C／⌃D。【推論】
- context menu 裡不顯示快捷鍵，快捷鍵顯示在選單列。【26】
- iPadOS 鍵盤焦點：Tab 在 focus group(sidebar、列表、格狀)之間移動，方向鍵在同一組內移動;**不要**為按鈕、segmented control、開關做鍵盤導覽(交給「完整鍵盤控制」)。【26】→ Agent 列表(`List`)與 sidebar 自動支援;自訂的 Agent 卡片網格才需要 `focusable`／focus group。【推論】

### 5. 指標、Apple Pencil、拖放、多選、context menu
- iPadOS 26 新指標是精確的箭頭、1:1 追蹤、**不再吸附**;懸停在 Liquid Glass 控制上出現玻璃 highlight。標準元件自動套用;玻璃群組用 highlight、單獨玻璃控制或小的不透明元素用 lift、大元素用 hover(可調 scale／tint／shadow;列表列不要 scale)。【26】
- 點擊區：有外框的元素周圍約 12 pt、無外框約 24 pt;同一列的自訂按鈕點擊區要相連。【26】→ 自訂膠囊(模型、權限)與 Agent 卡片要照這個留邊。【推論】
- 自訂 view 要支援指標框選多選才要自己做(`UIBandSelectionInteraction`);標準非列表 collection view 預設支援。【26】
- Apple Pencil:hover 用來預覽筆尖落下的效果、不要用 hover 觸發動作;squeeze／barrel roll 用在繪圖。Purrdr 沒有繪圖，**不需要專門支援**;文字欄位的 Scribble 由系統提供。【推論】
- 拖放:iPad 可同時拖多個項目、可邊拖邊加;要提供拖放以外的替代做法(選單指令);split view 各欄之間可考慮拖放。【26】iOS 27 SwiftUI 新增可重排(reorderable)與多項目拖曳(drag container)API。【27】→ 從「檔案」或其他 app 拖圖片／檔案進聊天輸入卡片當附件(上傳已有);Agent 列拖出成新視窗是常見的 iPad 手法，但 SwiftUI 以拖放開新視窗的做法**這次沒有查到一手文件**。【未證實】
- context menu:長按或副鍵點擊;項目少、最多約三組、子選單只一層;**不能用的項目要隱藏**(與選單列相反);破壞性項目放最後並標 destructive;context menu 的項目在主畫面也要做得到。iPad 可以用 context menu 在空白處「新增物件」。【26】→ Agent 列:在新視窗打開、複製 session、停止(最後、紅色);主機列：編輯、測試連線、刪除(最後)。Agent 列表空白處的 context menu 可放「新增聊天」。【推論】

### 6. Sheet 與 popover
- HIG:iPad app **優先用 page 或 form sheet**,置中、背景調暗。【26】UIKit 文件：regular×regular 時 form sheet 比 page sheet 小，背後一部分內容一直看得到;page sheet 約一張紙大小、高大於寬;compact 寬度時兩者都變成 iPhone 的底部 sheet。SwiftUI 對應 `presentationSizing(.form)`／`.page`／`.fitted`(iOS 18)。【26】→ 新增主機引導、主機編輯頁用 `.form`;Changes 這類閱讀內容用 `.page`;加入附件那種短選單在 iPad 改用 popover。【推論】
- popover 只放少量資訊或功能;箭頭直指來源、不要蓋住來源;一次一個、不要連環 popover;不要用 popover 顯示警告;**compact 寬度不要用 popover**——SwiftUI 的 popover 在 compact 會自動變 sheet。【26】→ 標題膠囊面板(用量百分比、context、權限模式)在 iPad regular 寬度用 popover,iPhone 與窄視窗自動變 sheet,同一份程式碼。【推論】
- UIKit:action sheet 在 iPad 錨定在來源 view。【26】
- iOS 27 SDK 起 sheet／popover 內的控制類環境值重設為預設(同 iPhone 研究)。【27】

### 7. 工具列、標題與搜尋(iPad 差異)
- iPad 的 tab bar 在**頂部**,可與工具列共用同一條水平空間。【26】
- 工具列三區：**前緣**(返回、顯示／隱藏 sidebar、標題，標題旁可放「文件選單」——放作用於整份文件的指令，前緣項目不可自訂);**中間**(常用控制，視窗縮小時自動收進系統的溢出選單，不要自己手動加溢出選單);**尾端**(一直要在的項目、開 inspector 的按鈕、搜尋、More 選單、Done 這類主要動作;所有視窗大小都可見)。iPad 與 Mac 可讓使用者自訂工具列。【26】
- 每個視窗要有有用的標題，**不要用 app 名稱當標題**;單一視窗時標題重複可留空。【26】
- iPadOS 26:sidebar 與 inspector 的標題在 regular 預設 inline;`NavigationSplitView` 內容欄的導覽箭頭(chevron)在 regular 預設不顯示。【26】
- 搜尋在 iPad 放在工具列右上(top-trailing);專門的搜尋畫面可做成 sidebar／tab bar 的一節。【26】
- → 聊天 detail 的標題 = Agent 名稱、副標 = 主機 · workspace;`toolbarTitleMenu` 放作用於整個聊天的指令(在新視窗打開、複製 session…)。開 inspector 的按鈕放尾端。【推論】iPadOS 27 的 `visibilityPriority`／`ToolbarOverflowMenu`／`topBarPinnedTrailing`(見 iPhone 研究)在可縮放的 iPad 視窗更重要。【27】

### 8. Sidebar 外觀(Liquid Glass)
- sidebar 是浮在內容上的 Liquid Glass;內容可延伸到 sidebar 底下——橫向捲動內容自然穿過，靜態圖用 `backgroundExtensionEffect()`(UIKit `UIBackgroundExtensionView`)鏡像模糊延伸。【26】`NavigationSplitView` 與 `sidebarAdaptable` TabView 中，sidebar 右邊的 view 只在 safe area 內縮 sidebar 寬度、可在 safe area 外畫到 sidebar 底下。【26】
- iPadOS 27:sidebar **延伸到視窗邊緣**、sidebar 圖示**恢復顏色**(用 app accent color)。【27】HIG Sidebars 2026-06-08 同步更新：圖示預設用 accent color,固定的其他顏色只在少量、有意義時用(例：Mail 的 VIP 黃色)。【27】→ sidebar 的主機圖示若要表達連線狀態，用少量固定色;其他保持 accent。【推論】
- 可讓使用者自訂 sidebar 內容與順序;不要預設隱藏 sidebar;iPad 以邊緣滑動顯示／隱藏。【26】
- `.sidebarAdaptable` 若可自訂 tab,預設 5 個以內，維持 compact 與 regular 的一致。【26】

### Purrdr 各畫面一句話建議(全部【推論】)
| 畫面 | iPad 建議 |
|---|---|
| Agent 列表 | 三欄的內容欄;選取狀態在每一欄持續標示;列支援 context menu 與拖到新視窗(後者待驗證);空白處 context menu「新增聊天」 |
| 聊天 | detail 欄;標題 = Agent、副標 = 主機;詳細資訊改 `.inspector`;膠囊面板 regular 用 popover;接鍵盤時 ⌘↩／⌘. 之類只用 ⌘ 組合 |
| Pane 終端機 | 獨立視窗(已有),標題用 Pane 名稱;頂部自訂元素避開視窗控制鈕;app 快捷鍵不用 ⌃;保留電腦版面模式在任意視窗寬度下以縮放呈現(已有 `TerminalViewportZoom`) |
| 主機管理 | sidebar 列主機(最多兩層：主機 → workspace);新增／編輯用 form sheet;選單列「主機」選單 |
| 設定 | App 選單的系統「設定…」開 iPadOS 設定;另一項「Purrdr 設定…」開 app 內設定(form／page sheet 或 tab) |

---

## 逐主題事實與出處

### A. 視窗系統與多工
| 事實 | 標記 | 出處 |
|---|---|---|
| iPad 視窗兩種呈現：全螢幕(app switcher 切換)／視窗化(自由調整大小、多個並存、可移到前面;系統記得大小與位置)。依「多工與手勢」設定 | 【26】 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows)(2025-06-09) |
| 「Apps don't control multitasking configurations or receive any indication of the ones that people choose」;前景視窗以著色的視窗控制鈕與投影辨識 | 【26】 | [HIG Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking)(2025-06-09) |
| 視窗化時視窗控制鈕在工具列前緣;前緣按鈕會被蓋住，要往內移 | 【26】 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows) |
| 右下角把手調整大小;控制鈕點一下變大、長按顯示排列捷徑;未更新的 app 會在工具列上方多一條安全區放控制鈕(「only exists for compatibility … suboptimal」);要讓工具列包住控制鈕 | 【26】 | [WWDC25 Elevate the design of your iPad app](https://developer.apple.com/videos/play/wwdc2025/208/) |
| 「Open in Place … no longer recommended」,每份文件開自己的視窗;App 選單列出所有開著的視窗，要給描述性名稱 | 【26】 | 同上 |
| 不要預設開新視窗;以 context menu 或 File 選單提供在新視窗打開;不要自製視窗外框或控制;對使用者說「window」不說 scene;可用捏合開新視窗 | 【26】 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows) |
| `preferredWindowingControlStyle(for:)`、`UIWindowScene.WindowingControlStyle`(iOS 26.0);用含水平角落調整的 layout margins guide 避開控制鈕;`UIView.layoutGuide(for:)`、`LayoutRegion`(iOS 26.0) | 【26】 | [WWDC25 Make your UIKit app more flexible](https://developer.apple.com/videos/play/wwdc2025/282/);[preferredWindowingControlStyle(for:)](https://developer.apple.com/documentation/uikit/uiwindowscenedelegate/preferredwindowingcontrolstyle(for:));[layoutGuide(for:)](https://developer.apple.com/documentation/uikit/uiview/layoutguide(for:)) |
| `UISceneSizeRestrictions` 設偏好最小尺寸(範例 500 pt 寬);「Be careful not to require a width that limits the number of columns」;只在支援可變視窗時提供 | 【26】 | [WWDC25 282](https://developer.apple.com/videos/play/wwdc2025/282/);[UISceneSizeRestrictions](https://developer.apple.com/documentation/uikit/uiscenesizerestrictions) |
| SwiftUI `windowResizability` 預設 `.automatic` = 一般視窗用 `contentMinSize`(內容的最小 frame 就是視窗下限) | 【26】 | [windowResizability(_:)](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)) |
| `UISplitViewController` 欄位可拖曳調整寬度、有預設最小／最大／偏好寬度;收合時 inspector 變 sheet | 【26】 | [WWDC25 282](https://developer.apple.com/videos/play/wwdc2025/282/);[WWDC25 What's new in UIKit](https://developer.apple.com/videos/play/wwdc2025/243/) |
| SwiftUI split view 依可用空間自動顯示／隱藏欄位;`UIRequiresFullScreen` 在 iPadOS 26 deprecated | 【26】 | [WWDC25 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/) |
| `UIRequiresFullScreen`:iOS 9.0 起、**deprecated 26.0**;iPadOS 26 視窗化或 Stage Manager 下「Scales your app's presentation when the user resizes it」;「will be ignored in a future release」 | 【26】 | [UIRequiresFullScreen](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequiresfullscreen);[WWDC25 282](https://developer.apple.com/videos/play/wwdc2025/282/) |
| 用 iOS 26 SDK 建置後，新硬體螢幕尺寸不再縮放或 letterbox | 【26】 | [WWDC25 282](https://developer.apple.com/videos/play/wwdc2025/282/) |
| iOS 27:`UIRequiresFullScreen` 改為離散縮放、在 iPhone 可縮放環境也被尊重;idiom 與 interface orientation 不再用於版面;方向在可縮放環境下被忽略 | 【27】 | [WWDC26 Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/) |
| iOS 27 SDK:支援方向不含四個時不再失去連續縮放;設 `UIRequiresFullScreen` 時每次縮放以新 `UIScreen` 離散送達 | 【27】 | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)(UIKit Resolved Issues) |
| iOS 27 SDK 起必須採用 scene-based life cycle,否則無法啟動;必須有 launch screen | 【27】 | 同上 |
| `UISceneClosureConfirmation`、`UIWindowScene.closureConfirmation`(iOS 27.0) | 【27】 | [UISceneClosureConfirmation](https://developer.apple.com/documentation/uikit/uisceneclosureconfirmation) |
| iPad app 不在前景時自動調暗圖示與文字;自訂元件用 `appearsActive` | 【27】(環境值 iOS 18) | [WWDC26 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/);[appearsActive](https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive) |
| HIG Layout(2026-09-09 更新):依 size class 不依裝置或方向;考慮所有 size class 組合;空間變大時可從 tab bar 換成 sidebar,但不要依空間改變功能;可用 Device Hub 測 iPad 調整大小 | 【26】【27】 | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout) |
| iPadOS 26 已知問題：外接螢幕上啟動的 app 預設同樣大小與位置 | 【26】 | [iOS & iPadOS 26 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)(iPad Multitasking) |

### B. 選單列與鍵盤
| 事實 | 標記 | 出處 |
|---|---|---|
| iPad 選單列：指標到頂端或往下滑叫出;選單順序同 Mac(App、File、Edit、Format、View、app 專屬、Window、Help);置中;沒有 Apple 選單與 extras;全螢幕時視窗控制鈕在選單列 | 【26】 | [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)(2025-06-09) |
| 「ensure that people can access all of your app's functions through its UI」;動態項目只在接硬體鍵盤時可用，要有替代;App 選單「設定」保留給 iPadOS 設定，app 內偏好另列在下方;tab 加進 View 選單並給快捷鍵;多用子選單 | 【26】 | 同上 |
| 選單項目永遠同一組，不能用時 disable;一字的選單標題;支援標準項目的標準快捷鍵 | 【26】 | 同上 |
| 依頻率排序、分段、太長收子選單、項目配符號、常用項目給快捷鍵;View 選單放 tab 與 sidebar 開關;不要隱藏選單或項目 | 【26】 | [WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/) |
| SwiftUI 的 commands API 在 iPad 產生相同的選單列 | 【26】 | [WWDC25 256](https://developer.apple.com/videos/play/wwdc2025/256/);[commands(content:)](https://developer.apple.com/documentation/swiftui/scene/commands(content:));[CommandMenu](https://developer.apple.com/documentation/swiftui/commandmenu) |
| UIKit:選單列要列出所有指令(含沒快捷鍵的);`UIMainMenuSystem` 設定;⌘W 預設關閉 window scene;sidebar／inspector 開關的標準動作;系統補 Window 選單的 tiling 與視窗清單，要填 scene 標題;storyboard 定義的選單列不再支援 | 【26】 | [WWDC25 243](https://developer.apple.com/videos/play/wwdc2025/243/) |
| `SidebarCommands`(iOS 14)、`InspectorCommands`(iOS 17)、`ToolbarCommands`、`TextEditingCommands`(iOS 14) | 【26】 | [SidebarCommands](https://developer.apple.com/documentation/swiftui/sidebarcommands);[InspectorCommands](https://developer.apple.com/documentation/swiftui/inspectorcommands) |
| iPadOS 27 選單列預設精簡圖示;`labelStyle(.titleAndIcon)` 強制顯示;Settings／Share／Print 自動保留;UIKit `preferredImageVisibility` | 【27】 | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)(SwiftUI、UIKit);[WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/);[WWDC26 278](https://developer.apple.com/videos/play/wwdc2026/278/) |
| HIG Menus(2026-06-08):圖示少用、有目的;用在常用動作、關鍵功能、位置、裝置、使用者內容;同組全有或全無 | 【27】 | [HIG Menus](https://developer.apple.com/design/human-interface-guidelines/menus) |
| 修飾鍵：Command 為主、Shift 為輔、Option 少用、避免 Control;列出順序 Control、Option、Shift、Command;自訂快捷鍵只給最常用指令 | 【26】 | [HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)(2025-06-09) |
| iPadOS 支援文字欄位、sidebar 的鍵盤導覽;按鈕等控制不要做鍵盤導覽，交給 Full Keyboard Access | 【26】 | 同上 |
| Tab 在 focus group 之間、方向鍵在組內;halo 焦點效果;`focusGroupIdentifier`、`UIFocusGroupPriority` | 【26】 | [HIG Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection) |
| `keyboardShortcut(_:modifiers:)`(iOS 14)、`focusable(_:)`(iOS 17)、`onKeyPress`(iOS 17)、`focusedSceneValue`(iOS 15) | 【26】 | [keyboardShortcut](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:));[focusable](https://developer.apple.com/documentation/swiftui/view/focusable(_:));[onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)) |

### C. Sidebar、split view、tab bar、inspector
| 事實 | 標記 | 出處 |
|---|---|---|
| sidebar 浮在 Liquid Glass 層;內容延伸到底下(橫向捲動或 background extension effect);可自訂內容;不要預設隱藏;最多兩層，更深用三欄;iPad 以邊緣滑動開關 | 【26】 | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)(2026-06-08) |
| `sidebarAdaptable`:開啟時選 sidebar 或 tab bar,兩者都有切換鈕，自動因旋轉與視窗大小調整;只要 sidebar 就用 `NavigationSplitView`;「Consider using a tab bar first」 | 【26】 | 同上;[sidebarAdaptable](https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable)(iOS 18) |
| sidebar 圖示預設 accent color;固定色少量、有目的 | 【27】 | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)(2026-06-08 更新) |
| 「Sidebars expand to the edges on Mac and iPad … icons in the sidebar regain their color using your app's accent color」 | 【27】 | [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) |
| iPad split view 兩欄(Mail)或三欄(Keynote);要考慮窄、compact、中間寬度，各欄之間能合理導覽;每欄持續標示選取;可在欄之間拖放 | 【26】 | [HIG Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)(2025-06-09) |
| tab bar 在 iPad 頂部，可固定或可轉 sidebar;偏好 tab bar;可自訂時預設 5 個以內;tab bar 與工具列可共用頂部同一條空間 | 【26】 | [HIG Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars);[HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| 不確定就先用 tab bar;直向時 sidebar 可 morph 回 tab bar;沒有 tab bar 的 app 收欄適應;縮放後盡量回到原狀態;內容延伸到工具列與 sidebar 底下 | 【26】 | [WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/) |
| tab bar 偏好填滿的符號、sidebar 偏好外框符號;`TabSection` 在 sidebar 排在單獨 tab 之後 | 【26】 | [WWDC24 Elevate your tab and sidebar experience in iPadOS](https://developer.apple.com/videos/play/wwdc2024/10147/) |
| `NavigationSplitView`／sidebarAdaptable 中，sidebar 右側 view 的 safe area 內縮 sidebar 寬，可畫到 sidebar 底下;iPadOS 的 sidebar 與 inspector 標題在 regular 預設 inline;內容欄 chevron 預設隱藏 | 【26】 | [iOS & iPadOS 26 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)(SwiftUI) |
| iOS 26 已知問題:inspector 不理 `inspectorColumnWidth`;階層沒有 `NavigationSplitView` 時 inspector 欄不出現;inspector 內要有 `NavigationStack` 才顯示工具列項目 | 【26】 | 同上 |
| `backgroundExtensionEffect()`、`UIBackgroundExtensionView`(iOS 26.0) | 【26】 | [backgroundExtensionEffect()](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect());[UIBackgroundExtensionView](https://developer.apple.com/documentation/uikit/uibackgroundextensionview);[WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/);[WWDC25 284](https://developer.apple.com/videos/play/wwdc2025/284/) |
| inspector:regular 寬度是尾端欄、compact 變 sheet,開關狀態由框架還原(`inspector(isPresented:content:)` iOS 17) | 【26】 | [inspector(isPresented:content:)](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)) |
| split view 各欄可各自有 scroll edge effect,高度要一致 | 【26】 | [WWDC25 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) |
| iOS 27 SDK 起 `TabView` selection 必須是可見 tab(否則可能 crash)——iPad 收合 sidebar 時隱藏的 tab 要注意 | 【27】 | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |

### D. 工具列與標題
| 事實 | 標記 | 出處 |
|---|---|---|
| 三區配置(前緣：返回、sidebar 開關、標題、文件選單，不可自訂;中間：可自訂、縮小時收進溢出;尾端：重要項目、inspector 按鈕、搜尋、More、Done,所有大小都可見) | 【26】 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)(2025-12-16) |
| iPadOS／macOS 系統自動加溢出選單，不要手動加;iPad／Mac 可讓使用者自訂工具列;群組最多三組;每個視窗有用的標題、不用 app 名稱 | 【26】 | 同上 |
| iPad 搜尋在工具列 top-trailing;`searchToolbarBehavior` 可收成按鈕 | 【26】 | [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/);[searchToolbarBehavior(_:)](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:)) |
| `toolbarTitleMenu`、`navigationDocument`、`ToolbarRole.editor`(iOS 16);`navigationSubtitle`(iOS 26) | 【26】 | [toolbarTitleMenu(content:)](https://developer.apple.com/documentation/swiftui/view/toolbartitlemenu(content:));[navigationDocument(_:)](https://developer.apple.com/documentation/swiftui/view/navigationdocument(_:));[navigationSubtitle(_:)](https://developer.apple.com/documentation/swiftui/view/navigationsubtitle(_:)) |
| 縮放視窗時系統自動調整工具列項目;iOS 27 `visibilityPriority`、`ToolbarOverflowMenu`、`topBarPinnedTrailing` | 【27】 | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |

### E. 指標、Pencil、拖放、context menu
| 事實 | 標記 | 出處 |
|---|---|---|
| 新指標形狀、1:1 追蹤、不再吸附;highlight 是玻璃 platter;要用新指標實測 | 【26】 | [WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/) |
| highlight(玻璃群組，預設用於 bar button、tab bar、segmented、edit menu)、lift(獨立玻璃控制)、hover(大元素;列表列不要 scale);點擊區約 12／24 pt;自訂多選用 `UIBandSelectionInteraction`;指標不顯示說明文字 | 【26】 | [HIG Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)(2026-10-28 更新 iPadOS 指引與插圖) |
| `hoverEffect(_:isEnabled:)`(iOS 17) | 【26】 | [hoverEffect](https://developer.apple.com/documentation/swiftui/view/hovereffect(_:isenabled:)) |
| Pencil hover 只做預覽、不觸發動作;squeeze 單次、非破壞性;barrel roll 只改筆跡 | 【26】 | [HIG Apple Pencil and Scribble](https://developer.apple.com/design/human-interface-guidelines/apple-pencil-and-scribble)(2024-05-07) |
| 拖放：提供替代做法、多項目、iPad 可陸續加入拖曳中的項目、單一動作選取並拖、目的地是否接受要回饋 | 【26】 | [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop) |
| SwiftUI 27:可重排 API、drag container 多項目、資料傳輸設定;`dragContainer` 只在 iOS／iPadOS／visionOS 27 | 【27】 | [WWDC26 Code-along: Build powerful drag and drop in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/271/) |
| iOS 27:Siri／Apple Intelligence 可從 app 的 drag interaction 取資源(context menu 叫出時)——drag 可能沒有使用者手勢就開始，不要在那時跑動畫或開 modal | 【27】 | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)(UIKit) |
| context menu:相關性優先、項目少、約三組、子選單一層、**隱藏**不能用的項目、破壞性放最後、主畫面也要做得到、不顯示快捷鍵;iPad 可在空白處新增物件;預覽要能清楚標示目標;同一項目不要同時有 context menu 與 edit menu | 【26】 | [HIG Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)(2023-12-05) |

### F. Sheet 與 popover
| 事實 | 標記 | 出處 |
|---|---|---|
| 「Prefer using the page or form sheet presentation styles in an iPadOS app」(2024-03-29 加入) | 【26】 | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)(2026-03-24) |
| form sheet:regular×regular 置中、加 Liquid Glass 層、比 page 小、背景永遠露一部分;page sheet:約一頁紙、高大於寬、尺寸依螢幕與方向;compact 寬度兩者都變底部 sheet | 【26】 | [UIModalPresentationStyle.formSheet](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/formsheet);[.pageSheet](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/pagesheet) |
| SwiftUI `presentationSizing(.form／.page／.fitted／.automatic)`(iOS 18);`.form`「slightly less wide than .page」 | 【26】 | [presentationSizing(_:)](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:));[PresentationSizing.form](https://developer.apple.com/documentation/swiftui/presentationsizing/form) |
| popover:少量內容、箭頭指向來源、一次一個、不疊其他 view(alert 除外)、不用於警告、自動關閉時要保存;compact 不用 popover | 【26】 | [HIG Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) |
| SwiftUI popover 在 iPhone 變 sheet、垂直 compact 變全螢幕;`presentationCompactAdaptation` 可改(iOS 16.4) | 【26】 | [popover(isPresented:…)](https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:));[presentationCompactAdaptation(_:)](https://developer.apple.com/documentation/swiftui/view/presentationcompactadaptation(_:)) |
| UIKit action sheet 在 iPad 錨定來源 view | 【26】 | [WWDC25 284](https://developer.apple.com/videos/play/wwdc2025/284/) |
| iPad 的設計原則：利用大螢幕、**減少 modal 與全螢幕轉場**、控制好按又不擋路 | 【26】 | [HIG Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) |

---

## iPadOS 27 的變化(只列一手來源證實的)
1. sidebar 延伸到視窗邊緣、sidebar 圖示恢復 accent color(WWDC26 SOTU、HIG Sidebars 2026-06-08)。
2. 非前景視窗自動調暗;`appearsActive` 調暗自訂元件(WWDC26 269)。
3. 選單列預設精簡圖示(Release Notes、HIG Menus 2026-06-08)。
4. `UIRequiresFullScreen` 改為離散縮放;方向與 idiom 不再參與版面;支援方向不影響連續縮放(WWDC26 278、Release Notes)。
5. 必須用 scene life cycle、必須有 launch screen(Release Notes)。
6. `UISceneClosureConfirmation`(API 文件)。
7. 工具列 `visibilityPriority`／`ToolbarOverflowMenu`／`topBarPinnedTrailing`(WWDC26 269;詳見 iPhone 研究)。
8. SwiftUI 拖放：可重排、drag container(WWDC26 271)。
9. HIG Layout(2026-09-09)與 Pointing devices(2026-10-28)有更新;Layout 新提 Device Hub 測 iPad 縮放;Pointing devices 為 iPadOS 更新了指引與插圖(內容與 iPadOS 26 的 highlight／lift／hover 一致)。
10. iPhone app 在 iPad 上可完全縮放(與 Purrdr 無關，Purrdr 是 Universal)。

WWDC26 沒有找到 iPad 視窗控制鈕、選單列結構、sheet／popover 在 iPad 呈現方式的新變化(檢查過 [101](https://developer.apple.com/videos/play/wwdc2026/101/)、[102](https://developer.apple.com/videos/play/wwdc2026/102/)、[269](https://developer.apple.com/videos/play/wwdc2026/269/)、[278](https://developer.apple.com/videos/play/wwdc2026/278/)、[271](https://developer.apple.com/videos/play/wwdc2026/271/)、[272](https://developer.apple.com/videos/play/wwdc2026/272/)、[260](https://developer.apple.com/videos/play/wwdc2026/260/)、[8006](https://developer.apple.com/videos/play/wwdc2026/8006/)、[8120](https://developer.apple.com/videos/play/wwdc2026/8120/));HIG Windows、Multitasking、The menu bar、Split views 的最後更新都還是 2025-06-09。

---

## 查不到的清單(未證實)
- **iPad 視窗的系統最小寬高**:HIG、`UISceneSizeRestrictions`、`windowResizability` 文件都沒寫數字;只有 WWDC25 範例的 500 pt(那是 app 自設的值)。
- **Stage Manager 在 iPadOS 26／27 的現況**:一手來源只剩 `UIRequiresFullScreen` 文件提到「iPadOS 16 以後支援 Stage Manager 的 iPad」;HIG 與 release notes 只講「全螢幕／視窗化」兩種模式。Slide Over 只在 HIG Layout 的 size class 例句出現，現況沒查到。
- **`sidebarAdaptable` TabView 的某個 tab 內再放 `NavigationSplitView`**:HIG 的 iPad 段落沒有明文(tvOS／visionOS 段落有「tab 內用 sidebar」)。
- **把列表項目拖出去開新視窗的 SwiftUI 做法**:HIG 提到捏合開新視窗(UIKit `collectionView(_:sceneActivationConfigurationForItemAt:point:)`、`ActivationInteraction`),SwiftUI 對應做法這次沒查到。
- **page／form sheet 在各 iPad 機型的精確點數**:文件只說「約一頁紙」「比 page 小」,依螢幕與方向而定。
- **視窗控制鈕本身的尺寸／需避開的寬度**:沒有公布數字，只能用 layout guide／系統元件自動避開。
- **iPadOS 27 對 iPad sheet、popover、context menu 外觀的變化**:WWDC26 與 HIG 都沒有。
- **iPadOS 27.1 Release Notes**:JSON 端點不存在(27.2 有，但沒有相關項目)。
