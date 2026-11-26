# iPad 上帳號／頭像按鈕的位置(iPadOS 26)

> 研究日期:2026-11-24。所有出處的取得日期都是 **2026-11-24**,以下不逐條重複。
> 問題:Purrdr iPad 寬視窗打算用「頂部 tab bar + 兩欄(列表 + 對話)」,頭像圓鈕(開帳號與設定 sheet)要放在 (a) 列表欄頂列右側、(b) 視窗最右上角(與頂部 tab bar 同一列)、還是 (c) 其他位置(sidebar 底部、tab bar 裡…)?
> 前提:HIG〈Managing accounts〉與〈Toolbars〉都沒有直接寫帳號鈕的位置(先前已查過，這裡不重複)。
> 只採一手來源:HIG(`developer.apple.com/tutorials/data/design/human-interface-guidelines/<頁>.json`)、WWDC session 逐字稿與附帶程式碼、Apple 範例程式原始碼、SwiftUI／UIKit API 文件(`/tutorials/data/documentation/<路徑>.json`)、support.apple.com 的《iPad 使用手冊》。
> 標記:**【一手】** Apple 原文或原始碼;**【推論】** 由一手事實推出、不是 Apple 原文;**【未證實】** 查不到一手依據。

---

## 結論

1. **沒有任何一手來源明文規定 iPad 帳號鈕的位置。** 查過的 HIG 頁面(Tab bars、Sidebars、Layout、Designing for iPadOS、Settings、Split views、Windows、The menu bar)都沒有提到 account／profile／avatar 的位置。【一手：查無】
2. **(b) 視窗右上角(與頂部 tab bar 同一列的 toolbar trailing)有一手依據**,而且是 Apple 自家 app 在 tab bar 狀態下的做法:
   - App Store(iPad):tab 在頂部中央，帳號鈕「at the top right」。【一手】
   - HIG Toolbars(iPadOS):toolbar 與 tab bar 可以共用頂部同一列;trailing edge 放「需要一直可用的重要項目」,且「在所有視窗大小都保持可見」。【一手】
   - WWDC25〈Build a SwiftUI app with the new design〉以 Books 的頭像當 toolbar item 的例子(`sharedBackgroundVisibility` 拿掉玻璃底)。【一手】
3. **(c) sidebar 底部也有一手依據，而且是 API 文件裡唯一「點名帳號鈕」的位置**:`tabViewSidebarBottomBar` 的官方範例就是 `AccountButton()`;WWDC26〈What's new in SwiftUI〉的範例 app 把 `MyAccountView` 放在 sidebar footer;Music 的 iPad 手冊寫「點你的名字(在 sidebar 底部)」。【一手】**但 sidebar 底部只在 sidebar 顯示時看得到**——tab bar 狀態(Purrdr 打算的「頂部 tab bar」)與窄視窗都看不到，必須另外有入口。【一手：API 文件】
4. **(a) 列表欄頂列右側沒有找到任何一手依據**;寬視窗時會落在畫面中間偏左，與 App Store 的「右上角」不符。【推論】
5. **建議 (b)**:頭像放在與頂部 tab bar 同一列的最右側(對話欄／detail 欄 toolbar 的 trailing)。iPadOS 26 用 `.topBarTrailing`,iPadOS 27 起用 `.topBarPinnedTrailing`(只有搜尋啟用且空間不夠時才收進 overflow)。若之後改成 `sidebarAdaptable` 且使用者切成 sidebar,可**另外**用 `tabViewSidebarBottomBar` 放帳號鈕(Music／Podcasts 的做法),但不要只放在 sidebar。【推論】
6. **窄視窗(compact)收成一疊時**:`NavigationSplitView` 在窄的 size class 收成單一 stack,`TabView` 回到 tab bar。頭像應回到**列表畫面(stack 的根)頂列右側**,與 iPhone 相同;若只掛在 detail 欄的 toolbar,收成一疊後頭像會跑到對話畫面、列表畫面沒有。所以要依 `horizontalSizeClass` 決定掛在哪一欄(regular → detail 欄 trailing;compact → 列表欄 trailing)。【推論】實際行為要在模擬器上縮放視窗確認。【未證實】

---

## 1. HIG

| 頁面 | 與帳號鈕位置相關的內容 | 標記 |
|---|---|---|
| Tab bars(iPadOS 段) | 「The system displays a tab bar near the top of the screen. You can choose to have the tab bar appear as a fixed element, or with a button that converts it to a sidebar.」「Prefer a tab bar for navigation.」沒有提到帳號鈕。 | 【一手】 |
| Toolbars(iPadOS 段) | 「Consider combining a toolbar with a tab bar. In iPadOS, a toolbar and a tab bar can coexist in the same horizontal space at the top of the view.」 | 【一手】 |
| Toolbars(Item groupings) | 「Trailing edge. The trailing edge contains important items that need to remain available, buttons that open nearby inspectors, an optional search field, and the More menu … Items on the trailing edge remain visible at all window sizes.」;leading edge 放返回、顯示／隱藏 sidebar 與標題。 | 【一手】 |
| Layout | 只有通則:「place the most important items near the top and leading side of the window」。沒有提帳號。 | 【一手】 |
| Sidebars、Designing for iPadOS、Split views、Windows、The menu bar | 沒有 account／profile／avatar 的位置說明。 | 【一手：查無】 |
| Settings | 只說系統設定 app 管「account details」,與 app 內帳號鈕位置無關。 | 【一手】 |

出處:
- https://developer.apple.com/design/human-interface-guidelines/tab-bars
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/layout
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados
- https://developer.apple.com/design/human-interface-guidelines/settings

→ HIG 沒有規定帳號鈕位置，但 Toolbars 的「trailing edge = 需要一直可用、所有視窗大小都可見」最符合帳號鈕的性質;且 iPad 的 toolbar 與 tab bar 共用頂部同一列，trailing edge 就是視窗右上角。【推論】

## 2. WWDC 逐字稿與附帶程式碼

- **WWDC24〈Elevate your tab and sidebar experience in iPadOS〉**(https://developer.apple.com/videos/play/wwdc2024/10147/)
  - 「the tab bar shares a safe area with the navigation bar for a more integrated appearance. Toolbar items from the navigation bar will automatically move to overflow if there is not enough room to show alongside the tab bar.」【一手】→ iPadOS 26 上用 `.topBarTrailing` 的頭像在窄一點的視窗可能被收進 overflow。
  - 「You can customize the sidebar's header and footer」。【一手】沒有提帳號鈕。
- **WWDC25〈Build a SwiftUI app with the new design〉**(https://developer.apple.com/videos/play/wwdc2025/323/)
  - 「Some toolbar items can do without this visual grouping, like this item from Books showing my avatar. Apply the sharedBackgroundVisibility modifier to separate an item into its own group without a background.」【一手】→ 頭像是 toolbar item、自成一組、不加玻璃底，正是 Purrdr 頭像圓鈕「獨立於膠囊」的做法。該段沒說是 iPhone 或 iPad 畫面。
- **WWDC26〈What's new in SwiftUI〉**(https://developer.apple.com/videos/play/wwdc2026/269/)
  - 「Our custom account button in the sidebar dims along with the rest of the tab labels, using the appearsActive environment value …」【一手】,附帶程式碼是 `struct SidebarFooterView { … MyAccountView() .opacity(appearsActive ? 1 : 0.5) }`。→ Apple 自己的 iPad 範例把帳號鈕放在 **sidebar footer**。
  - 同一場的 toolbar 範例:`ToolbarItem(placement: .topBarPinnedTrailing) { ShareButton() }`,用途是「我要 Share 鈕永遠不被藏起來」。【一手】範例放的是 Share,不是帳號鈕。
- **WWDC26 SwiftUI Group Lab**(https://developer.apple.com/videos/play/wwdc2026/8120/)
  - 談 `sharedBackgroundVisibility(.hidden)` 的主要用途:「You can see this in the books app. It shows a profile photo of the current person who's logged in and putting glass around and behind a photo of a person actually doesn't look great.」並提到 2026 年新增可以只移除 toolbar 按鈕的內容邊距、保留玻璃邊緣的 API。【一手】(Group Lab 是口述問答;那個新 API 的名稱逐字稿沒講，**未查到 API 文件**【未證實】)
- WWDC25〈Elevate the design of your iPad app〉(208)、〈What's new in SwiftUI〉(256)、〈Get to know the new design system〉(356)、〈Build a UIKit app with the new design〉(284)、〈Make your UIKit app more flexible〉(282)、WWDC24〈What's new in UIKit〉:逐字稿沒有提到 account／profile／avatar 的位置。【一手：查無】

## 3. Apple 範例程式

| 範例 | iPad 上帳號／profile 的放法 | 標記 |
|---|---|---|
| Destination Video(「Enhancing your app's content with tab navigation」同一份 zip)<br>https://developer.apple.com/documentation/swiftui/enhancing-your-app-content-with-tab-navigation | `TabView` + `.tabViewStyle(.sidebarAdaptable)`。`ProfileButtonView` 在 `Views/visionOS/`,只在 `#if os(visionOS)` 以 `.overlay(alignment: .topLeading)` 加上;**iPad 沒有 profile 鈕**。 | 【一手】 |
| Backyard Birds<br>https://developer.apple.com/documentation/swiftui/backyard-birds-sample | Account 是導覽的一項(`AppScreen.account`,`person.crop.circle`):iPhone 是一個 tab;iPad(`userInterfaceIdiom != .phone`)是 `NavigationSplitView` sidebar 清單的最後一列。屬於 iPadOS 18 之前的寫法。 | 【一手】 |
| Landmarks: Building an app with Liquid Glass<br>https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass | 沒有帳號鈕;`.topBarTrailing` 只用在 collection 詳細頁的編輯鈕。 | 【一手】 |

→ 官方範例沒有「iPad 頂部 tab bar + 右上角頭像」的程式碼;有帳號的範例都把它放在 sidebar(Backyard Birds 是清單列、WWDC26 是 footer)。【推論】

## 4. Apple 自家 app(《iPad 使用手冊》,support.apple.com)

- **App Store**(https://support.apple.com/guide/ipad/see-your-purchases-and-subscriptions-ipada1990048/ipados):「Tap the My Account button or your picture at the top right, tap Apps & Purchase History, then tap Purchase History.」【一手】同一手冊的「Get apps in the App Store on iPad」(https://support.apple.com/guide/ipad/get-apps-ipad9b4cea76/ipados)圖說:「At the top center, from left to right, are the following buttons: Today, Games, Apps, Arcade, and Search.」【一手】→ **頂部中央 tab bar + 右上角帳號鈕**,正是選項 (b)。
- **Music**(https://support.apple.com/guide/ipad/create-an-apple-music-profile-ipad8aa0bd6f/ipados):「Tap [Show Sidebar], then tap your name at the bottom of the sidebar.」【一手】→ 選項 (c),而且使用者要先打開 sidebar。
- **Podcasts**(https://support.apple.com/en-ca/guide/ipad/ipad502750ah/ipados):「Tap [My Account] or your profile picture (you may need to open the sidebar), tap your name …」【一手】;另一頁(https://support.apple.com/guide/ipad/follow-your-favorite-podcasts-ipadd449e789/ipados)寫「Choose Account > Account Settings in the menu bar.」【一手】→ 帳號鈕在 sidebar 裡;iPadOS 26 起還有選單列的 Account 選單。
- 版本注意：這些頁面的網址沒帶版本，頁面的版本選單列出 iPadOS 27／26／18／17,**無法確認顯示的是哪一版的文字**(研判是最新版 iPadOS 27)。【未證實】直接指定 `/26/ipados/26` 的網址時 support.apple.com 回 429,沒能取到 26 專屬的版本。
- Apple TV app 的 iPad 手冊沒有找到描述帳號鈕位置的句子。【未證實】

→ Apple 自家 app 有兩派:**tab bar 為主的 App Store 放右上角**;**sidebar 為主的 Music／Podcasts 放 sidebar(底部)**。Purrdr 打算的是「頂部 tab bar」,所以對應 App Store 的做法。【推論】

## 5. API 文件

| API | 可用版本 | 文件原文重點 | 標記 |
|---|---|---|---|
| `ToolbarItemPlacement.topBarTrailing` | iOS／iPadOS 14.0 | 「A placement for items in the trailing edge of the top bar. On watchOS, iOS, and tvOS, the top bar is the navigation bar.」 | 【一手】 |
| `ToolbarItemPlacement.topBarPinnedTrailing` | **iOS／iPadOS 27.0** | 「A placement that pins the item to the trailing edge of the toolbar. Pinned items only move to the overflow menu when search is active and there isn't enough room.」 | 【一手】 |
| `TabViewStyle.sidebarAdaptable` | iOS／iPadOS 18.0 | 「iPadOS displays a top tab bar that can adapt into a sidebar. iOS displays a bottom tab bar.」 | 【一手】 |
| `View.tabViewSidebarBottomBar(content:)` | iOS／iPadOS 18.0 | 「The content is pinned at the bottom of the sidebar, so it's always visible when the sidebar is visible and doesn't scroll with the content. **The following example adds an account button to the bottom of the sidebar**」,範例 `.tabViewSidebarBottomBar { AccountButton() }`。 | 【一手】 |
| `View.tabViewSidebarFooter(content:)` | iOS／iPadOS 18.0 | 在 sidebar 的 tab 之後、會跟著捲動;「only visible when the TabView is displaying the sidebar」。範例是 `ContactSupportLink()`。 | 【一手】 |
| `View.tabViewSidebarHeader(content:)` | iOS／iPadOS 18.0 | 同上，在 tab 之前;範例是歡迎訊息。 | 【一手】 |
| `UITabBarController.Sidebar.bottomBarView`(UIKit) | iOS／iPadOS 18.0 | 「A view to display at the bottom of the sidebar, like a UIToolbar.」 | 【一手】 |
| `View.tabViewBottomAccessory(content:)` | iOS／iPadOS 26.0 | 文件只描述 iPhone 的位置(tab bar 上方或收合時 inline);範例是狀態列(`HomeStatusView`)。不適合放帳號鈕。 | 【一手】 |
| `ToolbarContent.sharedBackgroundVisibility(_:)` | iOS／iPadOS 26.0 | 「Hiding the effect will cause the item to be placed in its own grouping.」 | 【一手】 |
| `NavigationSplitView` | — | 「At narrow size classes, such as on iPhone or Apple Watch, a navigation split view collapses into a single stack.」 | 【一手】 |

出處:
- https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbartrailing
- https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing
- https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable
- https://developer.apple.com/documentation/swiftui/view/tabviewsidebarbottombar(content:)
- https://developer.apple.com/documentation/swiftui/view/tabviewsidebarfooter(content:)
- https://developer.apple.com/documentation/swiftui/view/tabviewsidebarheader(content:)
- https://developer.apple.com/documentation/uikit/uitabbarcontroller/sidebar-swift.class/bottombarview
- https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)
- https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:)
- https://developer.apple.com/documentation/swiftui/navigationsplitview

**API 文件沒寫清楚的部分**【未證實】:
- `NavigationSplitView` 放在 tab 裡、頂部 tab bar 與各欄 navigation bar 共列時，哪一欄的 `.topBarTrailing` 會出現在視窗最右上角。依「各欄有自己的 navigation bar」研判是最右邊那欄(detail)的 trailing。【推論】
- `TabView` 本身的 toolbar 在 `sidebarAdaptable` 時的位置規則，文件沒有描述。

## 6. 給 Purrdr 的做法(全部是【推論】)

- **寬視窗(regular)**:頭像以 `ToolbarItem` 掛在**對話欄(detail)**的 toolbar,`.sharedBackgroundVisibility(.hidden)` 讓它獨立成一組(Books 的做法);placement 用 `.topBarTrailing`,`if #available(iOS 27, *)` 改 `.topBarPinnedTrailing`,避免視窗變窄時被收進 overflow。對話欄沒選聊天時的空白狀態也要掛同一顆，否則頭像會時有時無。
- **窄視窗(compact,含 iPhone)**:分欄收成一疊，頭像掛在**列表欄**頂列右側(與 iPhone 現行一致)。以 `@Environment(\.horizontalSizeClass)` 決定掛在哪一欄，同一時間只出現一顆。
- **若改用 `sidebarAdaptable` 並允許切成 sidebar**:sidebar 展開時可額外用 `tabViewSidebarBottomBar` 放帳號鈕(API 文件範例、Music／Podcasts 的做法);toolbar 上那顆仍保留，因為 tab bar 狀態看不到 sidebar 底部。
- 選單列：可比照 Podcasts 在 app 選單或 App 專屬選單加「帳號與設定…」項目(iPad 選單列)。
- 實作前在模擬器縮放視窗，確認 regular ↔ compact 切換時頭像的位置與只出現一顆。

## 查不到的項目

- HIG 任何頁面對 iPad 帳號鈕位置的明文規範。
- WWDC 中「iPad 頂部 tab bar + 右上角頭像」的程式碼範例(只有 Books 頭像的口述,沒有平台說明)。
- `.topBarPinnedTrailing` 用於帳號鈕的官方範例(WWDC26 範例放的是 Share)。
- support.apple.com 指定 iPadOS 26 版的手冊文字(回 429);Apple TV app 在 iPad 上的帳號鈕位置。
- WWDC26 Group Lab 提到的「移除 toolbar 按鈕內容邊距」API 名稱。
