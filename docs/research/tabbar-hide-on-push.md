# 第二層隱藏 tab bar:返回時 tab bar 晚約 0.4–0.5 秒才出現

調查日期:2026-11-27。環境:Xcode 27(iPhoneOS27.0.sdk)、最低 iOS 26。
問題:窄視窗從對話(或 Pane 終端機、登入 Shell)返回列表時,列表跟著 pop 轉場出現,底部 tab bar 卻晚約 0.4–0.5 秒才回來。UIKit 的 `hidesBottomBarWhenPushed` 是跟轉場一起動。

標示方式:**【事實】** 是一手來源原文或 SDK／程式碼裡看得到的；**【推論】** 是依事實推出、尚未實測驗證的。

---

## 1. 目前的實作(事實)

- `src/PurrdrFeatures/TopLevelTabs.swift` 的 `HidesTabBarWhenCompact`:在**被推入的目的地畫面**上掛 `.toolbarVisibility(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)`。
- 掛在 4 處,全部在目的地內部:
  - `AgentListView.swift:454`:`ConversationScreen` 裡的 `ConversationView`
  - `AgentListView.swift:518`:對話裡再以 `navigationDestination(isPresented:)` 推入的 `PaneTerminalView`
  - `SpacesListView.swift:210`:`PaneTerminalScreen`
  - `HostsTab.swift:235`:`LoginShellTool`(主機 tab 路徑上的 `HostRoute.loginShell`)
- 聊天 tab 窄視窗是 `NavigationStack(path: $navigation.chatsPath)`,路徑元素是 `ChatsDestination`(`.chat(ChatRoute)`／`.layout(...)`)(`TopNavigationView.swift:193`、`TopNavigationModel.swift:11`、`:78`)。寬視窗是 `NavigationSplitView`(`TopNavigationView.swift:222`)。主機 tab 是 `NavigationStack(path: $flow.path)`,路徑元素是 `HostRoute`(`HostsTab.swift:38`、`HostListFlow.swift:6`)。
- 頂層是 iOS 18 起的 `TabView(selection:)` + `Tab(...)`,每個 tab 自己有一個 `NavigationStack`(`TopNavigationView.swift:307`)。
- DESIGN.md「tab bar 顯示規則」:第二層只有對話與 Pane 終端機／登入 Shell 隱藏 tab bar,其他第二層保留(`DESIGN.md:150`)。

## 2. 為什麼 tab bar 在轉場結束後才回來

### 一手來源寫了什麼(事實)

1. `toolbarVisibility(_:for:)` 的文件說:「The preferred visibility **flows up to the nearest container that renders a bar**. This could be a NavigationView or TabView in iOS…」「Depending on the specified bars, the requested visibility may not be able to be fulfilled.」
   來源:https://developer.apple.com/documentation/swiftui/view/toolbarvisibility(_:for:)(內容取自 `https://developer.apple.com/tutorials/data/documentation/swiftui/view/toolbarvisibility(_:for:).json`)
   也就是說，它是一個**往上傳的偏好值**(preference),由最近能畫 bar 的容器(這裡是 `TabView`)讀取後決定;文件沒有說它會跟導覽轉場同步，也沒有任何時序保證。
2. `toolbar(_:for:)` 在 iOS 27 SDK 標成 deprecated、`renamed: "toolbarVisibility(_:for:)"`,兩者文件內容相同，是同一個機制。
   來源:`iPhoneOS27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface` 第 12356–12363 行;https://developer.apple.com/documentation/swiftui/view/toolbar(_:for:)
3. UIKit 的 `hidesBottomBarWhenPushed` 由導覽控制器在 push 時處理:「If YES, then when this view controller is pushed into a controller hierarchy with a bottom bar (like a tab bar), the bottom bar will slide out.」
   來源:`iPhoneOS27.0.sdk/.../UIKit.framework/Headers/UINavigationController.h:152`。線上文件:「The value of this property on the **topmost view controller** determines whether the toolbar is visible.」 https://developer.apple.com/documentation/uikit/uiviewcontroller/hidesbottombarwhenpushed
   也就是說，判斷依據是「堆疊頂端的 view controller 是誰」,由 `UINavigationController` 在轉場當下決定，不是等某個子畫面的狀態傳上來。
4. Apple Developer Forums 843894(iOS 26.3.1,`TabView` → `NavigationStack(path:)`,非 Apple 人員發文):「Moving Tab Bar visibility ownership to each destination view; this also produced **a noticeable delay before the Tab Bar returned**」;「Keep Tab Bar visibility synchronized with whether the tab-owned NavigationStack path is empty. This **preserves the normal system animation timing**.」Apple DTS(Richard Yeh,2026-09)只要求提供測試專案，沒有說明機制，也沒有給官方建議。
   來源:https://developer.apple.com/forums/thread/843894
5. Apple Developer Forums 763144(iOS 18,`Tab` API):發文者說 `.toolbar(.hidden, for: .tabBar)`「has issues」,想要 tab bar 跟著頁面滑動一起隱藏;DTS 只要求測試專案，之後沒有結論。
   來源:https://developer.apple.com/forums/thread/763144
6. 查過 iOS 26 release notes,沒有找到 tab bar visibility 跟導覽轉場時序相關的 known issue 或 resolved issue(只有 watchOS 的 `toolbarVisibility` 不隱藏導覽列)。來源:https://developer.apple.com/go/?id=ios-26-rn
7. WWDC24〈Elevate your tab and sidebar experience in iPadOS〉、WWDC25〈Build a SwiftUI app with the new design〉(323)、WWDC26〈What's new in SwiftUI〉(269)的逐字稿都沒有提到在 push／pop 時隱藏 tab bar。WWDC25 只講 `tabBarMinimizeBehavior` 與 `tabViewBottomAccessory`;WWDC26 講的是 `toolbarMinimizeBehavior(_:for:)`(縮小，不是隱藏)。
   來源:https://developer.apple.com/videos/play/wwdc2024/10147/ 、https://developer.apple.com/videos/play/wwdc2025/323/ 、https://developer.apple.com/videos/play/wwdc2026/269/

### 機制(推論)

- 偏好值掛在被推入的畫面上，那個畫面在 pop 轉場**整段期間仍在 view 樹裡**(返回動畫要畫它滑出去),所以它回報的 `.hidden` 一直有效。要等轉場結束、目的地從樹上移除，往上傳的值才變回 `.automatic`,`TabView` 這時才開始把 tab bar 動畫顯示。延遲大約等於「pop 轉場時間 + tab bar 自己的顯示動畫」,跟觀察到的 0.4–0.5 秒吻合。
- `hidesBottomBarWhenPushed` 則是 `UINavigationController` 在轉場**開始**時看「新的頂端是誰」,把 tab bar 的動畫排進同一個轉場，所以兩者同步(事實 3)。SwiftUI 的 `toolbarVisibility` 沒有公開「跟導覽轉場協調」的保證(事實 1),論壇 843894 觀察到的現象也一樣(事實 4)。
- 結論:**問題不在掛的位置是哪個 modifier,而在「誰擁有這個決定」**。只要決定權在目的地畫面裡，值就要等目的地消失才會改變。

## 3. 有沒有 Apple 認可、跟轉場同步的 SwiftUI 做法

**沒有找到 Apple 明文認可、保證與 push／pop 同步的 SwiftUI API**(事實:文件、WWDC 與 release notes 都沒有;Apple 人員在兩個相關論壇串都只要求提供測試專案)。以下逐一比對候選做法。

| 做法 | 一手來源怎麼說 | 判斷 |
|---|---|---|
| A. 改掛在別的 view 上:由**堆疊根(或 `NavigationStack` 本身)依路徑**決定 `.toolbarVisibility(..., for: .tabBar)` | 文件只說偏好值往上傳(事實 1)。論壇 843894 的非 Apple 開發者說「依路徑是否為空」可以「preserve the normal system animation timing」(事實 4),但同一篇也說互動式返回(手指滑回)時根層的 ScrollView 會因 tab bar 佔的高度(49pt)改變而跳一下 | 【推論】最有希望：決定權移到路徑擁有者，路徑一改就改，不必等目的地消失。**沒有 Apple 保證**,而且返回鈕 pop 時 `path` binding 是在轉場開始還是結束時寫回，文件沒寫，要用正在做的時序測試實測 |
| B. 只是把 modifier 換到 `navigationDestination` 的閉包裡 | 同上，仍在目的地子樹內 | 【推論】跟現在一樣，目的地還在樹上就還是 `.hidden`,不會改善 |
| C. `.toolbar(.hidden, for: .tabBar)` 取代 `toolbarVisibility` | SDK 標示為 deprecated、renamed(事實 2) | 同一個機制，沒有差別 |
| D. `tabBarMinimizeBehavior` | 文件與 WWDC25:捲動時**縮小** tab bar(`.onScrollDown`/`.onScrollUp`/`.never`) https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:) | 不是隱藏，不解決這個問題 |
| E. `toolbarMinimizationBehavior(_:for:)`(iOS 27) | SDK `@available(anyAppleOS 27.0, *)`(swiftinterface 第 13763 行);WWDC26 示範的是導覽列捲動時讓開 | iOS 27 才有，而且是縮小;最低版本是 iOS 26,不適用 |
| F. `tabViewBottomAccessory` | WWDC25:在 tab bar 上方放附加控制 | 不相關 |
| G. `.sidebarAdaptable` | WWDC24 與「Enhancing your app's content with tab navigation」:iPad 上 tab bar 與側邊欄互換 https://developer.apple.com/documentation/swiftui/enhancing-your-app-content-with-tab-navigation | 跟 iPhone 第二層隱藏無關;DESIGN.md 也已決定不採用(`DESIGN.md:153`) |
| H. 根層 `NavigationStack` 包住 `TabView`,聊天推在整個 `TabView` 上面 | 沒有找到 Apple 文件或 WWDC 示範這個結構;HIG〈Tab bars〉:「Make sure the tab bar is visible when people navigate to different sections of your app…The exception is when a modal view covers the tab bar」 https://developer.apple.com/design/human-interface-guidelines/tab-bars | 【推論】tab bar 會跟著列表一起被推走，視覺上等同 `hidesBottomBarWhenPushed`;但每個 tab 的頂列、搜尋、大標題要改由外層導覽列管理，等於重做頂層導覽結構 |
| I. 橋接 UIKit `hidesBottomBarWhenPushed` | 判斷的是導覽控制器的**頂端 view controller**(事實 3)。iOS 26 起這個屬性本身有回歸：論壇 789148(Frameworks Engineer:「It is not going away」,beta 4 修了 iPhone,但 iPadOS 26 與 2026-10 的 iOS 27 仍有回報)、805740(iOS 26 滑動返回時 tab bar 提早出現，直到 26.2 RC 仍在)。Apple 工程師建議改用 `UITabBarController.isTabBarHidden`／`setTabBarHidden(_:animated:)`(iOS 18,`UITabBarController.h:137–140`) https://developer.apple.com/forums/thread/789148 、https://developer.apple.com/forums/thread/805740 | 【推論】`UIViewControllerRepresentable` 只是 SwiftUI 目的地裡的子 view controller,不是導覽堆疊的頂端，設了沒有作用。要有效就得把聊天 tab 的窄視窗堆疊整個換成 UIKit `UINavigationController` + `UIHostingController`,SwiftUI 的 `navigationDestination`／`NavigationLink(value:)` 不能用;而且要靠 SwiftUI `TabView` 底層是 `UITabBarController`,這點沒有公開文件保證。iOS 26 的 `hidesBottomBarWhenPushed` 自己也有時序問題 |

## 4. Codebase design:seam 放哪裡

用 `/mattpocock-skills:codebase-design` 的詞彙。

- **現況(事實)**:「第二層沒有 tab bar」這條規則沒有自己的 module,而是散在 4 個目的地畫面的 modifier 呼叫裡(第 1 節)。每加一種要隱藏的第二層就要記得再掛一次;而且決定權在目的地，正是第 2 節的時序根因。這是**淺的**介面：呼叫端得知道「我是需要隱藏的那種頁面」。
- **建議的 seam(推論)**:放在**每個 tab 的導覽堆疊擁有者**,也就是持有路徑的地方(聊天 tab 的 `compactStack`,主機 tab 的 `HostsTab` 的 `NavigationStack(path:)`)。
  - **Interface**:路徑元素型別自己回答「推到這裡要不要隱藏 tab bar」,例如 `ChatsDestination.hidesTabBar`(`.chat` 為真、`.layout` 為假)、`HostRoute.hidesTabBar`(只有 `.loginShell` 為真)。堆疊擁有者只掛一次 modifier,輸入是「路徑」與「size class」,輸出是 `Visibility`。
  - **Depth**:規則(哪些路由隱藏、只在 compact、iPad 寬視窗保留)全部收在一個純函式裡，呼叫端只給路徑;可以在 `swift test` 驗證(跟 `TopBarModel` 一樣放在可測的邏輯層)。4 個目的地的呼叫全部刪掉。
  - **Adapter**:目前唯一的 adapter 是 SwiftUI `toolbarVisibility(_:for: .tabBar)`。以後 Apple 給出跟轉場同步的 API,或真的要換 UIKit 橋接，只換 adapter,路由規則不動。
  - 要注意的細節(事實，來自程式碼):Pane 終端機有兩條進入路徑——路徑上的 `.chat(route)` 對到終端機 pane(`AgentListView.swift:183`、`WindowViews.swift:53`),以及從對話裡以 `navigationDestination(isPresented:)` 推入(`AgentListView.swift:510–518`),後者**不在路徑上**。因為它只能從對話進入，而對話已讓路徑含 `.chat`,所以「路徑含 `.chat`」就涵蓋了;但這是隱含前提，要寫進測試。寬視窗的 `WindowDetail`(對話欄)不受影響，因為規則只在 compact 生效。
- **要不要改導覽結構**:
  - 第 3 節 A 的做法**不改結構**(每個 tab 一個堆疊照舊),只搬決定權。
  - H(根堆疊包住 TabView)才會改結構。代價【推論】:(1) iPad 寬視窗要保留 tab bar 與兩欄，所以 compact 與 regular 會是兩種頂層結構，縮放視窗跨 size class 時 `TabView` 會被重建，各 tab 內的 `@State`(例如 `FilesTab.folderPath`)會丟失，除非全部搬進 model;(2) `TopNavigationModel` 的 `chatsPath`、`selectedChat` 雙向對齊(`TopNavigationView.swift:198–211`)、推播與深層連結開聊天(`AppLock.whenUnlocked` 後設 `selectedChat`)都要改成推到外層堆疊;(3) `topBarPage` 系統頂列(大標題、搜尋、`ToolbarItemGroup`)目前是每個 tab 堆疊各自的導覽列，外層堆疊之下內層 tab 的導覽列行為沒有一手文件可查;(4) 專案沒有用 `SceneStorage`／`NSUserActivity` 做狀態還原(grep 結果為空),所以還原不是額外成本，但 `chatsPath` 的語意會變。
  - I(UIKit 堆疊)也會改結構：聊天 tab 的窄視窗堆疊從 SwiftUI 換成 UIKit,`ChatsDestination` 要自己對到 `UIHostingController`,`ChevronPushUsageTests` 守的「系統 `NavigationLink(value:)`」規則要重寫。

## 5. 建議(依優先順序)

1. **把決定權移到路徑擁有者(第 3 節 A + 第 4 節的 seam)**
   - 做法：在 `compactStack` 與主機 tab 的堆疊根掛一次 `.toolbarVisibility(路徑.contains(where: \.hidesTabBar) && compact ? .hidden : .automatic, for: .tabBar)`,刪掉 4 處 `hidesTabBarWhenCompact()`;路由規則寫成純函式並加單元測試。
   - 代價：低(幾十行，結構不變)。
   - 風險:**沒有 Apple 保證**,目前依據只有一篇非 Apple 開發者的論壇觀察(843894)。返回鈕 pop 時 `path` binding 何時寫回沒有文件，可能仍是轉場結束才寫;同一篇回報互動式返回時根層捲動位置會跳(tab bar 高度改變),聊天列表的捲動由 `ChatListViewController` 自己管(`AGENTS.md`「主執行緒更新規則」),要特別測。**先用正在做的時序測試實測，紅燈→改→綠燈**;互動式返回(左緣滑動、中途取消)也要測。
2. **A 實測仍延遲時：做最小重現專案，向 Apple 回報(Feedback Assistant + 在 843894 串回覆)**
   - 代價：低。風險：不會馬上修好;兩個相關串 DTS 都在等測試專案(763144、843894),有重現專案才可能有官方答覆。可以和 1 同時做。
3. **聊天 tab 窄視窗堆疊改成 UIKit `UINavigationController`,用 `hidesBottomBarWhenPushed`**
   - 代價：高(重寫聊天 tab 的窄視窗導覽、路徑對齊、`ChevronPushUsageTests`;主機 tab 的登入 Shell 也要一樣做才一致)。
   - 風險：高。依賴 SwiftUI `TabView` 底層是 `UITabBarController`(沒有公開文件);iOS 26 的 `hidesBottomBarWhenPushed` 本身有回報中的時序與 iPad 回歸(789148、805740);違反「系統 SwiftUI 元件優先」的專案方向。只有在 1、2 都不行、而且使用者願意接受時才考慮。
4. **根層 `NavigationStack` 包住 `TabView`**
   - 代價：最高(頂層導覽、頂列、深層連結、推播開聊天、iPad 寬窄切換都要重做)。
   - 風險：高。Apple 沒有示範這種結構;跨 size class 會重建 `TabView`、丟 tab 內狀態;會推翻 DESIGN.md「iPhone 頂層導覽」與「tab bar 顯示規則」的現有設計。不建議。

**不建議**:`tabBarMinimizeBehavior`、`toolbarMinimizationBehavior`、`tabViewBottomAccessory`、`.sidebarAdaptable`、把 `toolbarVisibility` 換成 `toolbar(_:for:)`——一手來源顯示它們不是「隱藏並與轉場同步」的機制(第 3 節表格 C–G)。
