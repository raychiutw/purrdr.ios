# iPadOS 27 的 iPad 版面:官方做法與設計規範(給 Purrdr iPad 實作用)

> 研究日期與所有出處的抓取日期:**2026-11-26**(以下不逐條重複)。
> 取法:HIG 用 `developer.apple.com/tutorials/data/design/human-interface-guidelines/<頁>.json`;API 文件用 `/tutorials/data/documentation/<路徑>.json`(可用版本取自 `platforms`);WWDC 逐字稿取自 session 頁的 transcript 區塊;Release Notes 取 iOS & iPadOS 26、26.1、26.2、26.4、27、27.1、27.2。
> 標記:**【一手】** Apple 原文;**【推論】** 由一手事實推出;**【未確認】** 查不到一手依據或只剩二手資料。
> 對照的既有研究:`docs/research/ipad-account-button-placement.md`(下稱「帳號鈕研究」)、`ipados26-design-language.md`(下稱「iPadOS 26 研究」)、`ios27-design-language.md`(下稱「iOS 27 研究」)。這份只補缺的與矛盾處，重疊的結論不再重抄。
> 對照的程式碼:`/tmp/rel053`(`integration/release-0.53`,HEAD `fbc12c27`)。

---

## 摘要(先看這段)

1. **官方明文允許、也示範在 split view 的欄內放 `NavigationStack`。** `NavigationSplitView` 文件:「You can also embed a NavigationStack in a column」;遷移文章:「If you need navigation within a column, embed a navigation stack in that column」;WWDC22〈SwiftUI cookbook for navigation〉的兩欄範例就是 detail 欄內放 `NavigationStack`。另一個官方機制:**前一欄的 `NavigationLink(value:)` 會設定後一欄堆疊的內容**,同一欄的則推入同一欄的堆疊。【一手】
2. **`List(selection:)` + `NavigationLink(value:)`**:value 型別與 selection 型別相同時，點連結就是改 selection,split view 依 selection 換後一欄內容;收成一疊時 selection 的改變自動變成 push／pop。【一手】
3. **horizontalSizeClass 在欄內的值是「欄的」還是「視窗的」,文件沒寫**——只說「available to the view that reads it」。【未確認】
4. **popover 與 Menu**:HIG 只說「一次一個 popover」「popover 上面除了 alert 不要再蓋任何 view」「讓人一下就能關掉一個 popover 開另一個」。UIKit 文件寫明：從 bar button item 開的 popover,**同一列的其他 bar button item 會被加進 passthrough(點了不會關 popover)**,要它們關 popover 得自己在 action 裡寫;iOS 26 起 popover 會「從來源項目長出並取代它」。iOS／iPadOS 26.x、27.x Release Notes **沒有** popover 與 Menu 互動的已知問題。【一手】→ Purrdr 的「用量環 popover 與『⋯』同一個 `ToolbarItemGroup`」正好落在這個 passthrough 規則上。【推論】
5. iPadOS 27 的 iPad 版面 **沒有新的 split view／popover／sheet 規則**;新的是工具列 API(`topBarPinnedTrailing`、`visibilityPriority`、`ToolbarOverflowMenu`、`contentMarginsRemoved`)、sheet／popover 內控制類環境值重設、選單列精簡圖示、非前景視窗調暗、sidebar 延伸到邊緣與恢復 accent 色(後三項在 iPadOS 26 研究已記)。【一手】

---

## 1. NavigationSplitView:列選取、欄內 push、欄數、收合、size class

| 事實 | 標記 | 出處 |
|---|---|---|
| 「selections in leading columns control presentations in subsequent columns」;split view 與第一欄的 `List(selection:)` 協同，選了就更新 detail;程式改 selection 也同時改列表外觀與 detail | 【一手】 | [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) |
| 「You can also embed a NavigationStack in a column. Tapping or clicking a NavigationLink that appears in an earlier column sets the view that the stack displays over its root view. Activating a link in the same column adds a view to the stack. Either way, the link must present a data type for which the stack has a corresponding navigationDestination(for:destination:) modifier.」 | 【一手】 | 同上 |
| 「with narrow sizes like on iPhone or on iPad in Slide Over, the navigation split view collapses all of its columns into a stack, and shows the last column that displays useful information」;收合時有 `NavigationLink` 的列會畫 disclosure chevron | 【一手】 | 同上 |
| 收合後「The split view ignores the visibility control」;`preferredCompactColumn` 可指定收合時頂端顯示哪一欄 | 【一手】 | 同上 |
| `NavigationSplitViewVisibility`:`detailOnly`、`doubleColumn`(三欄時藏第一欄)、`all`、`automatic`;「Some platforms don’t respect every option」 | 【一手】 | [NavigationSplitViewVisibility](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility) |
| `navigationSplitViewStyle`:`balanced`(顯示前導欄時縮小 detail)、`prominentDetail`(盡量維持 detail 大小)、`automatic`(依情境)。`automatic` 在 iPad 實際解析成哪一種，文件沒寫 | 【一手】／【未確認】 | [balanced](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/balanced)、[prominentDetail](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/prominentdetail)、[automatic](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/automatic) |
| 「On some platforms, NavigationSplitView adds a sidebarToggle toolbar item. Use the toolbar(removing:) modifier to remove the default item.」 | 【一手】 | [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)、[sidebarToggle](https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind/sidebartoggle) |
| 欄寬:`navigationSplitViewColumnWidth(_:)`／`(min:ideal:max:)`,「Only some platforms enable resizing columns」 | 【一手】 | [navigationSplitViewColumnWidth(_:)](https://developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(_:)) |
| 遷移文章:「If you need navigation within a column, embed a navigation stack in that column. This arrangement provides finer control over what each column displays.」;`List(colors, selection: $selection) { NavigationLink(…, value: color) }`:「if someone chooses the navigation link … the list updates the selection value」 | 【一手】 | [Migrating to new navigation types](https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types) |
| WWDC22:「When you put a value-presenting link inside a list with a matching selection type … the link will automatically update the selection when tapped or clicked」;「Changes to selection automatically translate into the appropriate pushes and pops on iPhone」;兩欄範例「Just like I can put a list inside a column of a NavigationSplitView, I can also put a NavigationStack inside a column」(detail 欄的 RecipeGrid 推入 recipe) | 【一手】 | [WWDC22 The SwiftUI cookbook for navigation](https://developer.apple.com/videos/play/wwdc2022/10054/) |
| `List` 單選在 iOS 16 起不用進編輯模式;iPad 接鍵盤／觸控板可不進編輯模式多選 | 【一手】 | [List](https://developer.apple.com/documentation/swiftui/list)、[WWDC22 SwiftUI on iPad: Organize your interface](https://developer.apple.com/videos/play/wwdc2022/10058/) |
| iPadOS 26:regular 時 sidebar 與 inspector 標題預設 inline;內容欄的 `NavigationLink` chevron 預設不顯示(`navigationLinkIndicatorVisibility` 可改) | 【一手】 | [iOS & iPadOS 26 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)(150891824、151646790) |
| iOS 26 修正:`navigationSplitViewColumnWidth()` 不遵守最小／最大值 | 【一手】 | 同上(143529326) |
| HIG Split views:每一欄持續標示選取;iPad 要考慮窄、compact、中間寬度，各欄之間能合理導覽;iOS「Prefer using a split view in a regular — not a compact — environment」 | 【一手】 | [HIG Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)(最後更新 2025-06-09) |
| `horizontalSizeClass`:「The value tells you about the amount of horizontal space available to the view that reads it」;設定因素列裝置、方向、iPad 的 Slide Over 與 Split View。**欄內是欄自己的還是視窗的，文件沒寫** | 【一手】／【未確認】 | [horizontalSizeClass](https://developer.apple.com/documentation/swiftui/environmentvalues/horizontalsizeclass) |
| WWDC26:版面要看「view controller 的 view 或 superview」的可用空間,「It will adjust better when your view controller appears in other contexts, for example inside of a split view controller」;idiom 與方向不再用於版面，改用 size class | 【一手】 | [WWDC26 Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/) |
| `presentationSizing`:「If the presentation’s root container is a NavigationSplitView, the proposed width only applies to the detail column」 | 【一手】 | [presentationSizing(_:)](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:)) |

**沒找到的**:`List(selection:)` 裡同時有 selection 型別的連結與「其他型別、推入同欄堆疊」的連結時的行為規則;Purrdr #641 記錄的「有 selection 的 List 裡 push 後第一下返回被吃掉」——沒有 Apple 文件或 Release Notes 提到。【未確認】

## 2. iPad 工具列與頂列

| 事實 | 標記 | 出處 |
|---|---|---|
| `toolbarTitleDisplayMode`:`automatic` = stack 根有標題時 `large`、沒標題時 `inline`,推入的頁沿用;`large` 捲動時移到中間;`inline` 小字置中;`inlineLarge` 大字放在工具列裡，並把 leading／centered 項目移進 overflow | 【一手】 | [ToolbarTitleDisplayMode](https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode) 與各成員頁 |
| `topBarPinnedTrailing`(iOS／iPadOS 27):「Pinned items only move to the overflow menu when search is active and there isn’t enough room」 | 【一手】 | [topBarPinnedTrailing](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing) |
| `ToolbarSpacer`(26):固定或彈性間隔，可在可自訂工具列中由使用者加減 | 【一手】 | [ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer) |
| `DefaultToolbarItem`(26):「Place this item in your toolbar to control where the system-provided item, like search, will be positioned」 | 【一手】 | [DefaultToolbarItem](https://developer.apple.com/documentation/swiftui/defaulttoolbaritem) |
| `searchToolbarBehavior`(26):文件只舉 iPhone 底部工具列的 `.minimized`(未啟用時像按鈕);iPad 上的效果文件沒寫 | 【一手】／【未確認】 | [searchToolbarBehavior(_:)](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:)) |
| `searchable` 放在 split view 上:iPad 兩欄放第一欄、三欄放第二欄頂端;要指定欄就把 modifier 加在那欄的 view;`placement` 只是建議，做不到時退回自動規則 | 【一手】 | [Adding a search interface to your app](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app) |
| WWDC25:搜尋「on iPad and Mac, it appears in the top-trailing position of the toolbar」——Landmarks 的做法是把 `searchable` 放在 `NavigationSplitView` 上 | 【一手】 | [WWDC25 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) |
| HIG Search fields(iPadOS／macOS):跨多欄搜尋、結果在 detail 時放**工具列尾端**(Mail、Notes);**篩選 sidebar 的內容或導覽時放在 sidebar 頂端**(Settings);專屬探索區則做成 sidebar／tab 的一項;compact 時「Notes and Mail place search above the column for the content list」;只有虛擬鍵盤的 iPad 不要自動聚焦 | 【一手】 | [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)(2026-06-08) |
| HIG Toolbars:前緣 = 返回、**顯示／隱藏 sidebar**、標題、文件選單;尾端 = 重要且一直可用的項目、inspector 鈕、搜尋、More、Done,「remain visible at all window sizes」;標題 15 字元內、不用 app 名稱;iPad 的 toolbar 與 tab bar 共用頂部同一列 | 【一手】 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)(2025-12-16) |
| HIG Windows:視窗化時視窗控制鈕在工具列前緣，前緣按鈕要往內移 | 【一手】 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows)(2025-06-09) |
| 觸控目標:「a button needs a hit region of at least 44x44 pt — in visionOS, 60x60 pt」 | 【一手】 | [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)(2025-12-16) |
| 系統工具列按鈕在 iPadOS 26／27 的實際點數 | 【未確認】(HIG、API 文件都沒寫;只可能在 Apple Design Resources 的 Figma kit,本次未下載) | — |
| WWDC26 Tech Talk:「make sure you're using the bars provided by navigation containers … In SwiftUI, pair the toolbar modifier with containers like NavigationStack or NavigationSplitView」;split view 裡只有 detail 欄的工具列會變直式(iPhone Duo) | 【一手】 | [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/) |

## 3. popover／sheet／fullScreenCover(regular 寬度)

| 事實 | 標記 | 出處 |
|---|---|---|
| HIG Popovers:少量資訊或功能;箭頭指向來源、不蓋住來源;**「Show one popover at a time … Never show a cascade or hierarchy of popovers」「Don’t show another view over a popover … except for an alert」「let people close one popover and open another with a single click or tap … especially … when several different bar buttons each open a popover」**;compact 不要用 popover | 【一手】 | [HIG Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) |
| UIKit `barButtonItem`:「Prior to presentation, the presentation controller adds all sibling bar button items of the specified item (but not the item itself) to the popover’s list of passthrough views. UIKit automatically intercepts taps in the specified item and uses them to dismiss the popover. If you want taps in the other bar button items to dismiss the popover, you must add code to the action handlers of those items.」(此屬性 iOS 27 標為 deprecated,改用 `sourceItem`) | 【一手】 | [barButtonItem](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/barbuttonitem) |
| UIKit `sourceItem`:「In iOS 26 and later, the popover animates from and replaces the specified item until someone selects an action item or dismisses the popover」 | 【一手】 | [sourceItem](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/sourceitem) |
| `passthroughViews`:popover 開著時其他 view 預設不能互動，列入的才會收到觸控 | 【一手】 | [passthroughViews](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/passthroughviews) |
| SwiftUI 工具列上的 `.popover` 是否沿用上面 UIKit 的 passthrough 規則 | 【未確認】(SwiftUI 文件沒寫內部實作) | — |
| SwiftUI `popover`:iPhone 變 sheet、垂直 compact 變 full-screen cover,`presentationCompactAdaptation` 可改 | 【一手】 | [popover(isPresented:…)](https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:))、[presentationCompactAdaptation(_:)](https://developer.apple.com/documentation/swiftui/view/presentationcompactadaptation(_:)) |
| `presentationSizing` 文件寫「a presentation like sheet」;**對 popover 是否生效沒寫** | 【一手】／【未確認】 | [presentationSizing(_:)](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:)) |
| `.form`「slightly less wide than .page」;`.page`「roughly the size of a page of paper」;UIKit form sheet 在 regular×regular 置中、加 Liquid Glass 層、背景一直露出一部分 | 【一手】 | [PresentationSizing.form](https://developer.apple.com/documentation/swiftui/presentationsizing/form)、[.page](https://developer.apple.com/documentation/swiftui/presentationsizing/page)、[UIModalPresentationStyle.formSheet](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/formsheet) |
| `presentationDetents` 在 iPad regular(form／page sheet)是否生效 | 【未確認】(SwiftUI 與 UIKit `detents` 文件都沒寫 regular 的行為) | [presentationDetents(_:)](https://developer.apple.com/documentation/swiftui/view/presentationdetents(_:))、[detents](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/detents) |
| HIG Sheets:「Prefer using the page or form sheet presentation styles in an iPadOS app」;複雜或長的流程可考慮 full-screen | 【一手】 | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)(2026-03-24) |
| HIG Designing for iPadOS:「minimizing modal interfaces and full-screen transitions」 | 【一手】 | [HIG Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) |
| HIG Modality:full-screen 適合影片、照片、相機或多步驟編輯;「avoid creating a modal experience that feels like an app within your app … presenting a hierarchy of views within a modal task can make people forget how to retrace their steps」;不要同時疊多個 modal | 【一手】 | [HIG Modality](https://developer.apple.com/design/human-interface-guidelines/modality)(2023-12-05) |
| iOS 26 修正(相關):「sheets applied to toolbar items sometimes do not display if the sheet is presented at the same time a popover is dismissed」(150764801);popover 外的環境更新傳不進 popover(147954025);popover 存取外部 environment object 可能閃退(156906038) | 【一手】 | [iOS & iPadOS 26 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes) |
| iOS 26 修正:非 edge-attached sheet 帶 zoom 轉場時誤變成 full-screen cover;要保留 compact 的滿版可用 `.presentationSizing(.page)` | 【一手】 | 同上 |
| iOS 27 SDK:`controlSize`、`buttonSizing`、`buttonRepeatBehavior`、`menuIndicatorVisibility`、`ButtonBorderShape` 在 sheet 與 popover 內重設為預設 | 【一手】 | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)(167448274) |
| 26.1、26.2、26.4、27、27.1、27.2 Release Notes 都**沒有**「popover 與 Menu」的已知問題 | 【一手：查無】 | 上列各版 Release Notes |
| Adopting Liquid Glass:「buttons fluidly morph into menus and popovers」;移除 popover 內自加的 visual effect 背景 | 【一手】 | [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) |

## 4. Liquid Glass:sidebar、toolbar、glassEffect、safeAreaBar、backgroundExtensionEffect

| 事實 | 標記 | 出處 |
|---|---|---|
| bars、sheets、popovers、controls 用標準元件就自動採用;split view、tab bar、toolbar 的自訂背景要移除;sidebar／tab bar 浮在導覽層，內容與導覽要分開 | 【一手】 | [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) |
| 「Audit toolbar customizations … fixed spacers or custom items … can appear inconsistent with system behavior」;要隱藏就隱藏整個 toolbar item,不要只藏裡面的 view | 【一手】 | 同上 |
| `NavigationSplitView` 的 sidebar 是浮在內容上的 Liquid Glass;`backgroundExtensionEffect()` 把 detail 欄的 view 鏡像模糊延伸到 sidebar／inspector 底下 | 【一手】 | [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/)、[backgroundExtensionEffect()](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()) |
| `glassEffect(_:in:)`:預設 `regular` 變體 + `Capsule`;通常配 `GlassEffectContainer` | 【一手】 | [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) |
| `.buttonStyle(.glass)`:「applies a Liquid Glass effect based on the button’s context」 | 【一手】 | [PrimitiveButtonStyle.glass](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass) |
| `safeAreaBar`(26):像 `safeAreaInset`,另外「extends the edge effect of any scroll views affected by the inset safe area」 | 【一手】 | [safeAreaBar(edge:alignment:spacing:content:)](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)) |
| 26.1 已知問題:「On iOS and iPadOS, @FocusState doesn’t work in safeAreaBar」(158720838);之後版本的 Release Notes 沒寫修正 | 【一手】／修正狀態【未確認】 | [iOS & iPadOS 26.1 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_1-release-notes) |
| iPadOS 27:sidebar 延伸到視窗邊緣、圖示恢復 accent 色;玻璃自動調校;Xcode 27 不能再選舊設計 | 【一手】 | 見 iPadOS 26 研究與 iOS 27 研究所引的 WWDC26 SOTU |

## 5. iPadOS 26 → 27 的變更(補充既有研究)

既有的 iPadOS 26 研究已涵蓋多視窗、選單列(`commands`)、`windowResizability`、鍵盤快捷鍵、`UIRequiresFullScreen`、`appearsActive`、選單列精簡圖示。本次只補:

- **Slide Over 仍出現在一手文件**:`NavigationSplitView` 文件「on iPad in Slide Over」、HIG Layout(2026-09-09)「whether an app is full screen, in Slide Over, or mirrored from an iPhone to a Mac」。HIG Multitasking 與 Windows 只講「全螢幕／視窗化」。**Stage Manager 在 iPadOS 27 的名稱與狀態沒有一手文件**。【一手】／【未確認】(iPadOS 26 研究寫「Slide Over 現況沒查到」,這裡補上這兩處仍提到它)
- `windowResizability`:最小／最大尺寸由內容的 `frame` 加 resizability 決定(文件範例 100–400 pt)。【一手】[windowResizability(_:)](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:))
- iOS 27 SDK:`TabView` 的 selection 必須是可見 tab(否則可能閃退);選單內 `LabeledContent` 變副標題;`toolbarMinimizationBehavior` 取代 `toolbarMinimizeBehavior`。【一手】[iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- 27.1、27.2 Release Notes 沒有 SwiftUI 版面、split view、popover、sheet 的項目。【一手：查無】
- WWDC26 沒有 iPad 版面或 split view 專場(搜尋與 SOTU recap 122 都沒有);相關內容只有 269(工具列 API、appearsActive)、278(size class、split view 內的 VC 尺寸)與 Tech Talk 111462。【一手】

---

## 6. 與既有研究的補充與矛盾

1. **欄內 NavigationStack**:iPadOS 26 研究只寫「HIG iPad 段落沒有明文支持 tab 裡再套 split view」。本次補上：**SwiftUI 文件明文支持「欄內放 NavigationStack」**(與 tab 內套 split view 是兩件事;後者仍【未確認】)。
2. **搜尋位置**:iPadOS 26 研究只寫「iPad 搜尋放工具列右上」。HIG Search fields(2026-06-08)其實分三種：跨欄或結果在 detail → 工具列尾端;**篩選 sidebar／列表 → 該欄頂端**;專屬探索 → sidebar／tab 的一項。Purrdr 的搜尋只篩列表欄，屬第二種。
3. **標題模式**:iPadOS 26 起 regular 的 sidebar 標題預設 inline;Purrdr 兩欄時列表欄就是 sidebar 欄，`topBarPage` 卻強制 `.large`(`TopBarViews.swift` 70 行)。不違反規則，但偏離系統預設，要有意識地決定。
4. **帳號鈕 pinned**:帳號鈕研究建議 iPadOS 27 用 `.topBarPinnedTrailing`。對話欄的 `AccountToolbarItem` 有做(`WindowViews.swift` 199–214 行);但共用頂列 `TopBarToolbar` 的註解說「iOS 27 起釘在 `topBarPinnedTrailing`」,程式碼卻一律是 `.topBarTrailing`(`TopBarViews.swift` 77–89 行)——**註解與程式不符**。
5. **聊天面板 popover**:iPadOS 26 研究建議「標題膠囊面板 regular 用 popover」,沒提到 popover 與同列 Menu 的互動。本次補上 UIKit 的 passthrough 規則與 iOS 26 的「popover 取代來源項目」。
6. **DESIGN.md 內部矛盾**:第 84 行(#619、#641)寫版面圖是「往右 push」;第 136 行(iPad 與寬視窗)寫「版面圖 … iPad 與 iPhone 一樣是 sheet」。程式碼兩處都是 push(`SpacesListView.swift` 97 行的 `NavigationLink(value: ChatsDestination.layout…)`、`AgentListView.swift` 477 行 `navigationDestination(isPresented: $showsLayout)`)。第 136 行是過期描述。
7. **帳號與設定滿版**:DESIGN 第 133 行(#623)用 `fullScreenCover`。HIG Sheets「iPadOS 優先 page／form sheet」、Designing for iPadOS「減少 modal 與全螢幕轉場」、Modality「不要做成 app 中的 app」——在 regular 寬度三者都不支持滿版;iPadOS 26 研究的設定建議也是 form／page sheet。

---

## 7. 對 Purrdr iPad 實作的具體建議

以下每項先列現況(程式碼位置)、官方依據，再給建議。建議都是【推論】,除非另外標示。

### 7.1 聊天 tab:兩欄／三欄與列選取
- **現況**:`TopNavigationView.swift` 182–237 行依 `sizeClass` 二選一：compact 是 `NavigationStack(path:)`,regular 是兩欄 `NavigationSplitView(columnVisibility: .all)`,列表欄外包 `NavigationStack(path: chatsPath)`,detail 是 `WindowDetail`(內含 `NavigationStack`,`WindowViews.swift` 14 行)。寬視窗列表是 `List(selection:)` + `NavigationLink(value: route)`(`AgentListView.swift` 307 行、`SpacesListView.swift` 89 行)。
- **依據**:欄內放 `NavigationStack`、`List(selection:)` 加同型別 `NavigationLink(value:)` 都是官方示範的寫法(§1)。官方的設計是**同一個 `NavigationSplitView` 自己收合成一疊**、selection 自動變 push／pop;Purrdr 自己在 compact 換成另一棵 `NavigationStack`,是因為 #641 的返回被吃掉問題，這不是官方寫法，但也沒有官方禁止。
- **建議**:
  1. 維持兩欄;沒有第三層需要常駐，不需要三欄(HIG:sidebar 最多兩層、超過才加內容欄)。
  2. `navigationSplitViewStyle` 明確寫 `.balanced`(列表與對話並排、不蓋住對話)。`.automatic` 在 iPad 解析成哪種沒有文件，明寫可以避免直向時列表蓋住對話。是否需要要在模擬器確認。
  3. 欄內的 size class(`AgentListView` 的 `listSizeClass`、`ConversationScreen`／`ComposerView` 的 `horizontalSizeClass`)**是欄的還是視窗的沒有文件**。現在根層已有 `isWideWindow`,建議由根層決定一次、以環境值往下傳，不在各欄各讀一次，避免列表欄與對話欄判斷不一致。
  4. 寬視窗不要 `toolbar(removing: .sidebarToggle)`:HIG 要求可以顯示／隱藏 sidebar,而且放在前緣。

### 7.2 版面圖 push 位置
- **現況**:兩個入口推到不同欄——Spaces 的多 Pane Tab 列在**列表欄**的堆疊推入(320–460pt 寬);對話「⋯」的「顯示版面」在**對話欄**推入。同一張圖在兩個寬度出現。
- **依據**:split view 文件:「前一欄的 NavigationLink 會設定後一欄堆疊的內容」(§1)。
- **建議**:regular 時把 `ChatsDestination.layout` 的 `navigationDestination` 註冊在**對話欄**的 `NavigationStack`,列表欄的 `NavigationLink(value: .layout…)` 就會換對話欄的內容(官方機制),兩個入口都在對話欄寬度顯示，選了 Pane 再換成那個聊天。注意:這條連結在 `List(selection: ChatRoute?)` 裡、型別不同，兩者並存的行為沒有文件【未確認】,要在模擬器驗 #641 那種「第一下返回被吃掉」有沒有在寬視窗重現。DESIGN.md 第 136 行「版面圖是 sheet」要改成 push。

### 7.3 新增聊天 push 位置
- **現況**:`navigationDestination(isPresented: $navigation.isNewChatOpen)` 掛在 `agentList` 上(`TopNavigationView.swift` 268 行),寬視窗時推進**列表欄**(最寬 460pt),對話欄不變。
- **依據**:HIG Designing for iPadOS「減少 modal」;split view 文件允許在任一欄的堆疊推入。官方沒有規定「建立新項目」要推在哪一欄。
- **建議**:regular 時改推進**對話欄**(與開好之後的聊天在同一欄，寬度也夠放主機與 Workspace 選擇);列表欄保持可見、選取維持。若想讓使用者明確「在做一件事」,替代方案是 `.sheet` + `presentationSizing(.form)`(HIG:iPad 優先 form sheet),但 DESIGN #621 已決定用 push,所以先選對話欄 push。

### 7.4 帳號與設定的滿版 modal
- **現況**:`fullScreenCover`(`TopNavigationView.swift` 78–83、498–504 行;DESIGN #623)。
- **依據**:HIG Sheets「iPadOS 優先 page／form sheet」;Designing for iPadOS「減少全螢幕轉場」;Modality「full-screen 給媒體或多步驟編輯，不要做成 app 中的 app」(§3)。帳號與設定是有子頁的設定階層，正是 Modality 警告的情況。
- **建議**:regular 寬度改 `.sheet` + `.presentationSizing(.page)`(設定內容多、會推子頁，page 比 form 寬);compact 仍可保留滿版。依 26 Release Notes,`.page` 在 compact 會變滿版，所以也可以兩種寬度都用 `.sheet` + `.page` 一個寫法。DESIGN #623 要補「iPad 例外」或寫 ADR。

### 7.5 聊天面板 popover 與「⋯」選單互相干擾
- **現況**:`ConversationScreen` 的 `ToolbarItemGroup(placement: .primaryAction)` 裡，用量環按鈕掛 `.popover`(`ConversationUsageViews.swift` 25 行 → `ConversationPanel.swift` 114–121 行)、旁邊是 `ConversationMoreMenu`(系統 `Menu`)。DESIGN 第 137 行記了 iPhone 上「popover 關閉後『⋯』打不開」的實測問題。
- **官方說法**(§3):
  - HIG:一次一個 popover;**popover 上面除了 alert 不要再蓋別的 view**;同列多個按鈕各開 popover 時，點另一顆要能一下關掉舊的、開新的。
  - UIKit:從 bar button item 開的 popover 會把**同列其他 bar button item 設成 passthrough**,點它們**不會**關 popover,要關得自己在 action 裡寫;iOS 26 起 popover 會從來源項目長出並**取代**它。
  - Release Notes 沒有 popover 與 Menu 互動的已知問題;最接近的是 26.0 已修的「popover 關閉同時開工具列上的 sheet 會不顯示」。
- **為什麼會干擾**【推論】:「⋯」是 popover 來源的兄弟項目，可能是 passthrough,所以 popover 開著時點「⋯」不會先關 popover,系統 Menu 就疊在 popover 上(違反 HIG);兩顆又在同一個玻璃膠囊裡，popover「取代來源項目」的 morph 動畫影響同一個群組。SwiftUI 是否完全照 UIKit 的 passthrough 規則【未確認】。iPhone 上「popover 關閉後選單打不開」的原因也沒有官方說明【未確認】。
- **建議**(擇一，依序):
  1. regular 時面板改成 **`.inspector`**(iPadOS 26 研究原本的建議;HIG 與 WWDC25 都把 inspector 列為 split view 標準做法,compact 自動變 sheet,沒有與工具列 Menu 疊在一起的問題)。DESIGN #617 是刻意取消 Inspector 的決定，要重新評估就寫 ADR。
  2. 保留 popover,但讓「⋯」在 regular 時**不出現在同一個群組**:面板已含「⋯」的大部分內容(DESIGN 第 137 行),把剩下的動作(Pane 終端機、Git 變更、顯示版面)也放進面板，或把 `ConversationMoreMenu` 以 `ToolbarSpacer` 拆成獨立群組。拆群組是否能脫離 passthrough【未確認】,要實測。
  3. 至少照 UIKit 文件的指示，在「⋯」被點時先把 `showsUsage` 設成 false 再開選單(`Menu` 沒有開啟前的 action,可能要改成 `Menu(primaryAction:)` 或以 `onTapGesture` 處理，可行性【未確認】)。
  - 另外:`presentationSizing(.form)` 對 popover 是否有效沒有文件(§3),實測沒效果就拿掉，以內容的 `frame(idealWidth:)` 控制寬度。

### 7.6 slash 面板:`safeAreaBar` 取代輸入列 vs sheet
- **現況**:compact 用 `safeAreaBar` 把輸入列換成面板(高度跟最近一次鍵盤高度，沒有就 300pt);regular 用底部 sheet(medium／large)(DESIGN 第 192 行、#624)。
- **依據**:`safeAreaBar` 會調整 safe area 與 scroll edge effect(§4);HIG Designing for iPadOS「減少 modal」;HIG Sheets「iPad 優先 page／form sheet」;**`.medium` detent 在 iPad regular 是否生效沒有文件**【未確認】;26.1 已知問題 `@FocusState` 在 `safeAreaBar` 裡無效、修正狀態未確認。
- **建議**:regular 也用 `safeAreaBar` 取代輸入列，跟 iPhone 同一個元件。理由:(a) 面板是對目前聊天的小選擇，HIG 的 iPad 原則是減少 modal,對話保持可見;(b) iPad 常接實體鍵盤，沒有虛擬鍵盤高度，regular 時高度改成「依內容、上限約半個對話欄」,不要沿用 300pt;(c) 避開 regular sheet 的 detent 行為沒有文件的問題。若面板裡要靠 `@FocusState` 接鍵盤方向鍵，先在 iPadOS 27 實測 26.1 那個已知問題修了沒有。另一個選項是錨在輸入列上的 popover(HIG:少量功能),但 Pane 的 slash 面板要用方向鍵連續操作,popover 點外面就會收，不適合。

### 7.7 頂列:帳號位置與搜尋
- **帳號**:寬視窗在對話欄 trailing(pinned + `sharedBackgroundVisibility(.hidden)` + `contentMarginsRemoved`),窄視窗回列表頂列——符合帳號鈕研究的結論，維持。**要修**:`TopBarViews.swift` 的 `TopBarToolbar` 要照註解在 iOS 27 改用 `.topBarPinnedTrailing`(或把註解改掉),不然窄視窗、檔案、主機、流量 tab 的頭像在 iPad 窄視窗會被收進 overflow(WWDC24:tab bar 與導覽列共列時，放不下的項目移到 overflow)。
- **搜尋**:`searchable(placement: .navigationBarDrawer)` 掛在列表欄(`TopBarViews.swift` 111–124 行)。HIG(2026-06-08)「篩選 sidebar 的內容時，搜尋放在 sidebar 頂端」、compact 時「放在內容列表那一欄上方」(Notes、Mail)——**現行位置符合**,不要改成 split view 層級的工具列尾端(那是跨欄搜尋或結果在 detail 時用的)。`searchToolbarBehavior` 只對 iPhone 底部工具列有文件，iPad 不需要。
- **標題**:列表欄強制 `.large` 偏離 iPadOS 26 的 sidebar 預設(inline)。建議 regular 時改用預設(`toolbarTitleDisplayMode(.automatic)` 或不設),讓列表欄頂端留給搜尋與工具列;若設計稿要維持大標題，寫進 DESIGN 當作有意偏離。
- **觸控目標**:44×44 pt 是 HIG 的下限(§2);系統工具列按鈕的實際點數沒有公開，不要以自訂 frame 撐大系統工具列項目(Adopting Liquid Glass:審視自訂的工具列項目)。

---

## 8. 查不到(未確認)清單
- `horizontalSizeClass` 在 `NavigationSplitView` 各欄內的值(欄自己的或視窗的)。
- `navigationSplitViewStyle(.automatic)` 在 iPad 解析成 balanced 或 prominentDetail。
- `List(selection:)` 裡混用「selection 型別連結」與「推入同欄堆疊的連結」的行為;Purrdr #641 的「返回被吃掉」。
- SwiftUI 工具列 `.popover` 是否沿用 UIKit 的兄弟項目 passthrough;popover 與同群組 `Menu` 的已知問題(Release Notes 查無)。
- `presentationSizing` 對 popover 是否有效;`presentationDetents(.medium)` 在 iPad regular 是否有效。
- 26.1 已知問題「`@FocusState` 在 `safeAreaBar` 無效」(158720838)是否已修。
- iPadOS 26／27 系統工具列按鈕的實際尺寸(Apple Design Resources 未下載核對)。
- iPadOS 27 的 Stage Manager 名稱與狀態;HIG 與 API 文件仍提到 Slide Over,但 Windows／Multitasking 頁只講全螢幕與視窗化。
- `searchToolbarBehavior` 在 iPad 的效果。

## 出處總表(都在 2026-11-26 抓取)
- API:[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)、[Migrating to new navigation types](https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types)、[NavigationSplitViewVisibility](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility)、[NavigationSplitViewStyle](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle)、[List](https://developer.apple.com/documentation/swiftui/list)、[horizontalSizeClass](https://developer.apple.com/documentation/swiftui/environmentvalues/horizontalsizeclass)、[navigationSplitViewColumnWidth(_:)](https://developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(_:))、[sidebarToggle](https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind/sidebartoggle)、[toolbarTitleDisplayMode(_:)](https://developer.apple.com/documentation/swiftui/view/toolbartitledisplaymode(_:))、[ToolbarTitleDisplayMode](https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode)、[topBarPinnedTrailing](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing)、[ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer)、[DefaultToolbarItem](https://developer.apple.com/documentation/swiftui/defaulttoolbaritem)、[searchToolbarBehavior(_:)](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:))、[Adding a search interface to your app](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app)、[SearchFieldPlacement](https://developer.apple.com/documentation/swiftui/searchfieldplacement)、[presentationSizing(_:)](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:))、[PresentationSizing](https://developer.apple.com/documentation/swiftui/presentationsizing)、[presentationCompactAdaptation(_:)](https://developer.apple.com/documentation/swiftui/view/presentationcompactadaptation(_:))、[popover(isPresented:…)](https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:))、[fullScreenCover](https://developer.apple.com/documentation/swiftui/view/fullscreencover(ispresented:ondismiss:content:))、[presentationDetents(_:)](https://developer.apple.com/documentation/swiftui/view/presentationdetents(_:))、[safeAreaBar](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:))、[backgroundExtensionEffect()](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect())、[glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))、[.glass](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass)、[windowResizability(_:)](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:))、UIKit [UISplitViewController](https://developer.apple.com/documentation/uikit/uisplitviewcontroller)、[UIPopoverPresentationController.barButtonItem](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/barbuttonitem)、[sourceItem](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/sourceitem)、[passthroughViews](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/passthroughviews)、[UIModalPresentationStyle.formSheet](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/formsheet)、[UISheetPresentationController.detents](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/detents)、[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- HIG:[Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers)、[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)、[Modality](https://developer.apple.com/design/human-interface-guidelines/modality)、[Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)、[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Windows](https://developer.apple.com/design/human-interface-guidelines/windows)、[Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking)、[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、[Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)、[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)、[Pull-down buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)
- WWDC:[WWDC22 10054](https://developer.apple.com/videos/play/wwdc2022/10054/)、[WWDC22 10058](https://developer.apple.com/videos/play/wwdc2022/10058/)、[WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/)、[WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/)、[WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/)、[WWDC26 278](https://developer.apple.com/videos/play/wwdc2026/278/)、[WWDC26 122](https://developer.apple.com/videos/play/wwdc2026/122/)、[Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)
- Release Notes:[26](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)、[26.1](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_1-release-notes)、[26.2](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_2-release-notes)、[26.4](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_4-release-notes)、[27](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)、[27.1](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_1-release-notes)、[27.2](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_2-release-notes)


---

## 2026-11-26 更新註記

上文「標題模式」與「列表欄強制 `.large`」的疑問已有決議(使用者決定,iPad 照系統、不退讓):`topBarPage` 的 `navigationBarTitleDisplayMode` 改為 `.automatic`,iPhone 四個 tab 仍是大標題,iPad regular 寬度的列表欄走系統預設(inline);守門在 `SystemTopBarUsageTests`,iPad UI 測試 `IPadSidebarUITests.testListColumnTitleExistsAndDoesNotOverlap`。帳號與設定快捷鍵決議為 Option-Command-,(見 DESIGN.md)。
