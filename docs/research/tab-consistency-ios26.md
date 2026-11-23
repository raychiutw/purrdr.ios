# 頂層 5 個 tab 的樣式一致性(對照 iOS 26 HIG)

日期:2026-11-23。程式碼基準:`origin/master` `cf2cad06`(0.50.0,已含 `integration/next-0-49-1`)。

範圍:聊天(Agents／Spaces 兩種檢視)、檔案、主機、流量、設定五個 tab 的**頂端工具列、標題、頁面底色與區塊、列表列**。不含第二層畫面(對話、終端機、子頁)。

## 研究方法與證據等級

- **HIG**:以 developer.apple.com 的 HIG JSON 原文(與網頁同一份內容)逐頁讀取,引用都是原文。讀到的版本(各頁 Change log 最新一筆):Toolbars 2025-12-16、Tab bars 2026-06-08、Search fields 2026-06-08、Color 2025-12-16、Branding 2026-09-09、Typography 2025-12-16、Lists and tables 2023-06-21、Segmented controls 2023-06-21、Icons 2025-06-09、Materials、Dark Mode、Accessibility(2025-03-07)。
- **SwiftUI 文件**:同樣讀 developer.apple.com 的文件 JSON(abstract、說明段落與 `introducedAt`)。
- **WWDC25**:323〈Build a SwiftUI app with the new design〉、356〈Get to know the new design system〉逐字稿;219〈Meet Liquid Glass〉沿用 `docs/research/apple-hig-drover-chat.md` 已引的原文。
- **系統 App 實際版面**:在模擬器「iPhone 17」(**iOS 27.0**,Xcode 27 的模擬器;本機沒有 iOS 26 runtime)開訊息、檔案、設定、健康截圖,深色與淺色各一次。iOS 27 沿用 iOS 26 的 Liquid Glass 設計語言(見主 worktree 未追蹤的 `docs/research/ios27-design-language.md`),以下只引用兩版都相同的版面事實。模擬器沒有「郵件」App,郵件只引用 HIG 原文提到的做法。
- **SwiftUI 行為實測**(本報告新增):寫了一個單檔 SwiftUI 探針 App(TabView + NavigationStack + toolbar,以 `swiftc` 編成模擬器 App),驗證三件程式碼看不出來的事:環境 `tint` 會不會傳到工具列項目、`.tint(nil)` 的效果、工具列文字與大標題隨 Dynamic Type 的變化。結果在 §2.1、§3。探針程式不進 repo。
- 證據標示:**【HIG】**原文、**【文件】**SwiftUI 文件、**【WWDC】**逐字稿、**【實測】**模擬器截圖、**【程式】**讀程式碼、**【截圖】**使用者回報的兩張 TestFlight 截圖、**【推論】**我的推論。

---

## 結論摘要

1. 五個 tab 的頂列由**三份各自實作的主機選單**(`HostFilterMenu`、`HostPickerButton(inToolbar:)`、`HostCapsule`)和**各自手排的工具列**組成,字級(15pt semibold／17pt semibold)、圖示大小(24／22pt)、內距、「所有主機」有沒有圖示都不同;一致性目前只靠人工對齊。
2. 「白色」與「綠色」並存不是設計決定,是**副作用**:聊天 tab 的主機主題 modifier 在沒有主題時做了 `.tint(nil)`,工具列因此變單色(白);其他 tab 吃 `ProminentFillStyle` 變綠。另有三顆元件明確寫 `.tint(Color.appAccent)`。【實測】【程式】
3. HIG 對工具列的預設就是**單色**(深色模式白、淺色模式黑),顏色只留給主要動作或狀態,且主要動作要上色在**底**而不是字。把頂列統一成單色**符合** HIG;「白色」要解讀成「系統單色」,不能寫死白色(淺色模式會看不見)。
4. 「大小固定」與系統行為**大致相符**:實測系統工具列的符號、tab bar 在 AX5 都不放大,工具列裡的自訂文字只小幅放大;HIG／文件允許「因設計限制必須維持小」的元件用 large content viewer 補位。建議:頂列控制固定(上限鎖在一個字級)並加 large content viewer;**大標題與列表內容仍要隨字級放大**。
5. 標題:四個 tab 拿掉標題(`toolbar(removing: .title)`)、設定是大標題、檔案與主機在特定狀態會露出內嵌標題,三種呈現並存。HIG(iOS)與系統 App(訊息、檔案、設定、健康)都用**大標題**;建議五個 tab 一律大標題=tab 名稱。
6. Agents 與 Spaces 的列是兩個完全不同的 view(`AgentRowView`、`SpacesTabLabel`),**連第一行顯示的是什麼都不同**(Agents 是「workspace Tab 名」、Spaces 是「Agent 標題/Tab 名」)。建議共用一個列骨架,兩種檢視只差在分組。
7. 「離開期間」膠囊放在標題同一行、沒有 `fixedSize`/`lineLimit`,會把 workspace 名擠成「purrdr…」並自己折成兩行【截圖】【程式】;應移出第一行。
8. 檢視切換鈕「顯示目前檢視」的符號語意不明(HIG:不要讓人猜);而 Spaces 的符號 `square.grid.2x2` 同時是主機選單裡「所有主機」的符號,兩者衝突。
9. DESIGN.md 的「共用框架」與實作已脫節(寫左上是檢視切換、中間是主機選單、新增聊天是 `square.and.pencil`;實作是左上主機選單、右上切換與 `plus`)。
10. 架構上建議抽兩個 deep module:**頂列 module**(五個 tab 只宣告「主機範圍 + 動作」)與**聊天列 module**(純值的列內容 + 一個列 view),讓一致性由型別與一處實作保證。

---

## 1. 現況盤點

### 1.1 比較表(iPhone、窄視窗)

| | 聊天(Agents／Spaces) | 檔案 | 主機 | 流量 | 設定 |
|---|---|---|---|---|---|
| 左上 | 主機選單 `HostFilterMenu`(含所有主機)<br>`TopNavigationView.swift:224-226` | 主機選單 `HostPickerButton(inToolbar: true)`<br>`FolderBrowserView.swift:40-44` | 主機選單 `HostPickerButton(inToolbar: true)`(有主機時)<br>`HostsTab.swift:47-51` | 主機選單 `HostCapsule`(含所有主機)<br>`DataUsageView.swift:77` | 無 |
| 中間 | 無(標題被移除) | 無(標題被移除) | 無主機時顯示內嵌標題「Host」 | 無(標題被移除) | 無(大標題在列下方) |
| 右上 | 檢視切換 + `plus`(同一顆膠囊)、帳號<br>`TopNavigationView.swift:228-234` | `plus`(上傳)、帳號<br>`FolderBrowserView.swift:46-56` | `plus`(新增主機)、帳號<br>`HostsTab.swift:52-58` | 帳號<br>`DataUsageView.swift:75` | 帳號<br>`SettingsView.swift:134-136` |
| 帳號鈕的組法 | `AccountToolbarItem`(自帶 spacer) | 手寫 `ToolbarSpacer` + `ToolbarItem` | 手寫 `ToolbarSpacer` + `ToolbarItem` | 手寫 `ToolbarItem` | 手寫 `ToolbarItem` |
| 主機選單字級 | `.subheadline.weight(.semibold)`(15pt)<br>`TopNavigationView.swift:397` | `.headline`(17pt semibold)<br>`HostPickerViews.swift:32` | 同檔案 | `.headline`<br>`DataUsageView.swift:247` | — |
| 主機選單圖示 | `HostIconBadge` 24pt,所有主機也畫(桌機) | 24pt | 24pt | 22pt,**選所有主機時不畫** `DataUsageView.swift:243-245` | — |
| 主機選單內距 | trailing 4 `TopNavigationView.swift:405` | leading 6、trailing 10 `HostPickerViews.swift:40-41` | 同檔案 | 水平 12 `DataUsageView.swift:251` | — |
| 主機選單顏色 | `Color.appAccent`(綠) | `Color.appAccent` | `Color.appAccent` | `Color.appAccent` | — |
| `plus` 顏色 | 明確 `.tint(Color.appAccent)` `TopNavigationView.swift:231` | 沒寫 → 繼承 tab 的 `ProminentFillStyle` → 主色綠【實測+程式】 | 明確 `.tint(Color.appAccent)` `HostsTab.swift:54` | — | — |
| 其他按鈕顏色 | 檢視切換沒寫 → 繼承**主機主題 tint**;沒有主題時是 `.tint(nil)` → 單色白【實測+程式】 | — | — | — | — |
| 帳號頭像(已登入) | `prominentFill` 圓底:**聊天 tab 是主機主題填色**,其他 tab 是主色 `MemberView.swift:801` | 主色 | 主色 | 主色 | 主色 |
| 標題呈現 | `navigationTitle(Agents/Spaces)` + `toolbar(removing: .title)` + inline `AgentListView.swift:81-85` | 標題=資料夾名,移除;無主機時大標題「Files」;不支援時移除 `TopLevelTabs.swift:80-97` | 「Host」(單數,與 tab「Hosts」不同),有主機才移除 `HostsTab.swift:40-45` | 「Data Usage」移除(DESIGN 說大標題是「網路流量」) `DataUsageView.swift:68-72` | **大標題**「Settings」 `SettingsView.swift:133` |
| 頂列下方第二列 | 系統搜尋欄(`navigationBarDrawer`,`.always`) `SpacesListView.swift:238-246` | 路徑麵包屑(自訂 `safeAreaInset`) `FolderBrowserView.swift:70` | 無 | 無 | 無 |
| 頁面容器 | `List` `.insetGrouped` + `appGroupedList()` `AgentListView.swift:276-277` | `List`(沒指定 style)+ `appGroupedList()` `FolderBrowserView.swift:112` | `List` + `appGroupedList()` + `appPageContentWidth()`(720pt) `HostOverviewView.swift:60`、`HostsTab.swift:101` | **`ScrollView` + 自畫卡片**,寬度上限 **640pt**,上方多 16pt `DataUsageView.swift:51-67` | `List` + `appGroupedList()` + `appPageContentWidth()` `SettingsView.swift:130-131` |
| tab 內容的 tint | `selectedHostTheme` 內層 + `ProminentFillStyle` 外層 `TopNavigationView.swift:242-244` | `ProminentFillStyle` | `ProminentFillStyle` | `ProminentFillStyle` | `ProminentFillStyle` |

【截圖】使用者的兩張截圖(深色)與上表一致:主機膠囊與 `plus` 綠、檢視切換與帳號鈕白;搜尋欄在頂列下方整寬;Agents 每列「workspace Tab 名」+ 右側時間與 context 環 + 第二行「主機 · 預覽」;Spaces 依「主機 · workspace」分段,列只有標題與 Tab 名。

### 1.2 不一致清單

**頂列**

- **I-1 三份主機選單實作**:`HostFilterMenu`(`TopNavigationView.swift:362-413`)、`HostPickerButton`(`HostPickerViews.swift:5-60`)、`HostCapsule`(`DataUsageView.swift:227-268`)。字級、圖示尺寸、內距、「所有主機」圖示都不同(見表)。三者的差別其實只有「選項是否含所有主機」與「選了之後改哪個值」。
- **I-2 顏色來源有四種**:明確 `appAccent`(主機選單、聊天與主機的 `plus`)、繼承 `ProminentFillStyle`(檔案的 `plus`)、繼承主機主題 tint 或 `.tint(nil)` 的單色(聊天的檢視切換)、`secondaryText`(未登入的帳號圖示 `MemberView.swift:814-818`)。【實測】探針證實:環境 `tint`(含自訂 `ShapeStyle`)會傳到工具列項目;內層 `.tint(nil)` 會讓工具列項目回到系統單色。`HostThemeModifier` 在沒有主題時正好做 `.tint(nil)`(`HostThemeViews.swift:47`),所以使用者截圖裡檢視切換是白色;**若那台主機有 herdr 主題,這顆會變成主題的 tint 色**。
- **I-3 帳號鈕三種組法**:只有聊天 tab 與檔案的特殊狀態用 `AccountToolbarItem`(`TopLevelTabs.swift:42-56`),其他各自手寫 `ToolbarSpacer`/`ToolbarItem`,而且檔案、流量、設定把帳號鈕當 `AnyView` 傳進畫面(`TopLevelTabs.swift:101`、`:115`、`TopNavigationView.swift:266`)。
- **I-4 已登入頭像的填色**:聊天 tab 在 `selectedHostTheme` 底下,頭像的 `prominentFill` 解析成主機主題填色;其他 tab 是主色。同一顆帳號鈕在不同 tab 顏色可能不同。【程式】
- **I-5 檢視切換的符號衝突**:Spaces 的符號 `square.grid.2x2`(`SpacesListView.swift:186`)也是主機選單「所有主機」的符號(`TopNavigationView.swift:371`)。
- **I-6 檢視切換的語意**:符號顯示「目前檢視」(`SpacesListView.swift:183-189`),點一下切到另一個。只有符號的切換鈕無法分辨「現在是」還是「按了會變成」。
- **I-7 工具列擠壓**:【實測】在約 iPhone 寬的視窗,左側放一顆「圖示＋文字＋▾」的主機選單時,右側超過兩顆的項目會被系統收進「⋯」溢出選單。聊天 tab 右側目前是「切換＋新增」一組加帳號,剛好放得下;主機名稱一長或字級一大就可能溢出。

**標題**

- **I-8 三種標題呈現**:移除(聊天、檔案、主機、流量)、大標題(設定)、內嵌(主機無主機時「Host」);檔案無主機時又是大標題「Files」(`TopLevelTabs.swift:84`,沒設 display mode)。
- **I-9 標題文字與 tab 名稱不同**:tab「Hosts」vs 標題「Host」(`HostsTab.swift:40`);tab「Traffic」vs 標題「Data Usage」(`DataUsageView.swift:68`);聊天 tab「Chats」vs 標題「Agents／Spaces」(`AgentListView.swift:81`)。標題雖被移除,但仍是返回鈕、App 切換器與 VoiceOver 會念到的文字。
- **I-10 DESIGN.md 與實作脫節**:`DESIGN.md:120` 寫「左上是檢視控制、中間是主機選單、流量與設定中間是頁面大標題」;`DESIGN.md:119` 寫新增聊天是 `square.and.pencil`;`DESIGN.md:168` 寫中間是主機選單(`principal`)。實作是主機選單在左上(#475)、新增聊天用 `plus`、流量沒有大標題。

**頁面**

- **I-11 流量 tab 不是 List**:`ScrollView` + 自畫卡片(`DataUsageView.swift:51-67`),頂端多 16pt、寬度上限 640pt;其他頁是 inset grouped `List`,上限 720pt(`AppSurface.pageContentWidth`)。
- **I-12 頂列下方的第二列各自不同**:聊天是系統搜尋欄、檔案是自訂麵包屑、其他沒有。
- **I-13 檔案的 `List` 沒有指定 style**:目前靠 `.automatic`(在 iOS 是 inset grouped),與聊天明確寫 `.insetGrouped` 不同;結果相同,但不是由同一處決定。

**聊天列表的兩種檢視**

- **I-14 列是兩個 view**:Agents 是 `AgentRowView`(`AgentListView.swift:497-645`),Spaces 是 `SpacesTabLabel`(`SpacesListView.swift:71-104`)。
- **I-15 第一行的內容不同**:Agents 第一行是 workspace 名稱 + Tab 名稱(`AgentListView.swift:556-566`);Spaces 第一行是 `tab.title`——Tab 沒有人取的名稱時是 **Agent 標題**,第二行才是「Tab N」(`SpacesListView.swift:84-91`)。同一個 Agent 在 Agents 檢視叫「purrdr Tab 2」,在 Spaces 檢視叫「Mattpocock-skills 全部票券單一 PR / Tab 2」【截圖】。Agents 檢視完全看不到 Agent 標題。
- **I-16 資訊有無不同**:Spaces 沒有時間、context 環、預覽、釘選／靜音／離開期間、待辦數(`DESIGN.md:146` 也寫「Spaces 檢視的 Tab 列尚未顯示」)。資料面 `SpacesTab` 只有 host、key、title、target、avatar、tabName(`SpacesProjection.swift:89-96`),沒有帶 `AgentRow`。
- **I-17 對齊不同**:Agents 列 `HStack(alignment: .top)`(頭像對第一行),Spaces 列預設置中(頭像對整列中線)。【程式】【截圖】
- **I-18 「離開期間」膠囊擠壓標題**:膠囊放在第一行的 `HStack`(`AgentListView.swift:581-589`),沒有 `lineLimit(1)`/`fixedSize`,而 workspace 名稱 `lineLimit(1)`、Tab 名稱 `layoutPriority(-1)`;右欄時間與 context 環也在同一行。結果:workspace 被截成「purrdr…」、Tab 名稱只剩「r」、膠囊自己折成兩行【截圖】。
- **I-19 主機標示位置不同**:Agents 在第二行開頭(18pt 圖示 +「主機 ·」),Spaces 在段落標題(20pt 圖示 +「主機 · workspace」,`SpacesListView.swift:111-118`)。DESIGN 寫 Spaces 主機分組標題圖示 28pt(`DESIGN.md:147`),實作是 20pt。

---

## 2. HIG 對 iOS 26 的規範與建議

每條:規範原文 → 建議做法 → 為何。

### 2.1 工具列項目與 Liquid Glass 的顏色

規範:

- 「By default, symbols and text on these elements follow a monochromatic color scheme, becoming darker when the underlying content is light, and lighter when it's dark.」【HIG】[Color › Liquid Glass color](https://developer.apple.com/design/human-interface-guidelines/color#Liquid-Glass-color)
- 「Apply color sparingly … reserve it for elements that truly benefit from emphasis, such as status indicators or primary actions. To emphasize primary actions, apply color to the background rather than to symbols or text. … Refrain from adding color to the background of multiple controls.」【HIG】同上
- 「Reduce the use of toolbar backgrounds and tinted controls.」【HIG】[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- 「Use the `.prominent` style for key actions such as Done or Submit. … Only specify one primary action, and put it on the trailing side of the toolbar.」【HIG】同上
- 「You can still tint icons with a tint modifier, but use this to convey meaning, like a call to action or next step, but not just for visual effect.」【WWDC】[WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/)
- 「Apply your app's accent color judiciously. … Minimize its use on controls and instead use it intentionally for primary actions or status indicators, like badges for unread content or an icon for the selected tab in a tab bar.」【HIG】[Branding](https://developer.apple.com/design/human-interface-guidelines/branding)(2026-09-09)
- 「in apps with primarily monochromatic content or backgrounds, choosing your brand color as the app accent color can be an effective way…」【HIG】Color —— 這句是「把品牌色設成 accent」,不是「把工具列字上色」。

系統 App:【實測】訊息、檔案、設定、健康的頂列符號都是單色——深色模式白、淺色模式黑;健康 tab 的帳號圓鈕也是單色。唯一有顏色的是 tab bar 選取中的 tab。

探針:【實測】直接 `.tint(.green)` 的工具列符號是綠字;`.glassProminent` + `.tint(.green)` 是綠底白勾(HIG 說的「上色在底」);沒寫 tint 時跟著環境 tint;環境 `.tint(nil)` 時回到單色。

**建議 C-1:頂列一律單色**——主機選單(文字、chevron)、檢視切換、`plus`、帳號鈕都不寫 tint,並在頂列 module 內以 `.tint(nil)` 明確隔離 tab 內容的 tint(不要靠繼承)。為何:HIG 預設就是單色;顏色只留給主要動作或狀態;目前四種顏色來源(I-2)正是繼承造成的。

**建議 C-2:頂列沒有「主要動作」**,不用 `.prominent`。為何:HIG 的 `.prominent` 是 Done、Submit 這類完成動作;新增聊天、上傳、新增主機屬於一般動作(郵件的撰寫鈕在 HIG 的 Search fields 頁與系統 App 都是單色)。若使用者仍要讓「新增聊天」突出,唯一合規的做法是那一顆用 `.glassProminent`(主色底),而不是綠色字,且全 app 同一時間只有一顆。

**建議 C-3:主機選單裡的綠色圓形主機圖示(`HostIconBadge`)在頂列改成單色符號**(與 `HostMenuLabel` 一樣的線條符號)。為何:它在玻璃上是一塊上色的底,等於「多個控制項上色」;列表內容層的徽章維持綠色不受影響。

**建議 C-4:tab bar 選取色維持 accent**。為何:Branding 明文舉例「an icon for the selected tab」。

**建議 C-5:已登入頭像的圓底固定用主色,不吃主機主題**(修 I-4)。為何:帳號鈕跨 tab 出現,顏色應一致;頭像底色是身分標識,不是動作強調,保留一個色塊可以接受,但不應隨 tab 變。【推論】

### 2.2 標題與大標題

規範:

- 「Use a large title to help people stay oriented as they navigate and scroll. By default, a large title transitions to a standard title as people begin scrolling the content, and transitions back to large when people scroll to the top…」【HIG】[Toolbars › iOS](https://developer.apple.com/design/human-interface-guidelines/toolbars#iOS)
- 「Provide a useful title for each window. … If titling a toolbar seems redundant, you can leave the title area empty.」「Write a concise title … keep the title under 15 characters」【HIG】Toolbars › Titles
- 「Make sure the tab bar is visible …」「Include tab labels … Use single words whenever possible.」【HIG】[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)

系統 App:【實測】訊息「訊息」、檔案「最近項目」、設定「設定」、健康「摘要」都是大標題,位置在頂列控制的下一列、靠左;健康與檔案是有 tab bar 的 App,大標題文字等於選取中 tab 的名稱。

SwiftUI:`toolbarTitleDisplayMode(.inlineLarge)`(iOS 17)把大標題放進工具列同一列,但「moves any leading or centered toolbar items into the overflow menu」【文件】[inlineLarge](https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge)——會把左上主機選單收進溢出選單,不適用。iOS 26 有 `ToolbarItemPlacement.largeTitle`(「A placement for items in the navigation bar's title area」)與 `.largeSubtitle`【文件】[largeTitle](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/largetitle)、[largeSubtitle](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/largesubtitle),可把自訂 view 放在大標題位置。

**建議 T-1:五個 tab 一律大標題,文字=tab 名稱**(聊天、檔案、主機、流量、設定;英文 Chats、Files、Hosts、Traffic、Settings)。捲動後系統自動收成內嵌標題。為何:HIG iOS 明文;系統 App 一致;一次解掉 I-8、I-9。代價:列表頂端多一列約 52pt(捲動即收起)。

**建議 T-2(替代):五個 tab 一律不顯示標題**,設定也拿掉大標題。為何可行:HIG 允許「titling seems redundant」時留空,tab bar 的選取標籤已告訴使用者在哪。代價:與系統 App 不同、偏離 HIG iOS 的建議;返回鈕與 VoiceOver 仍要靠 `navigationTitle`。

**建議 T-3(進階,需原型驗證):有主機範圍的 tab 把主機選單放在 `.largeTitle` 位置**(大標題就是「所有主機 ▾」),沒有主機範圍的 tab 是文字大標題。為何:標題列「一定是那一頁看什麼」;左上空出來。風險:我只讀到文件說明,沒有實測捲動收合時這個自訂 view 的行為(**未確認**),要先做原型。

不論選哪一個:標題文字與 tab 名稱一致(修 I-9),並在共用 module 決定(見 §5)。

### 2.3 Tab bar 與搜尋的位置

規範:

- iOS 搜尋入口三處:tab、頂或底的工具列、內嵌在內容。「Place search at the bottom if there's room. … Examples … include Settings, where it's the only item, and Mail and Notes」「Place search at the top when it's important to defer to content at the bottom of the screen, or there's no bottom toolbar.」「When at the top, position an inline search field above the list it searches, and consider pinning it to the top toolbar when scrolling.」【HIG】[Search fields › iOS](https://developer.apple.com/design/human-interface-guidelines/search-fields#iOS)
- 「A tab bar can include a dedicated search tab at the trailing end.」【HIG】Tab bars › iOS;「Choose the button appearance to help people quickly find what they need … brings people directly back to their previous tab」【HIG】Search fields
- `searchToolbarBehavior(.minimize)`(iOS 26)把底部搜尋縮成按鈕【文件】[searchToolbarBehavior](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:));`Tab(role: .search)` 搜尋 tab【WWDC】323

系統 App:【實測】沒有 tab bar 的訊息與設定把搜尋放在底部;**有 tab bar 的檔案把搜尋放在大標題下方、清單上方**(內嵌、頂端)——正是「there's no bottom toolbar(底部已被 tab bar 佔用)→ 放頂端」的情況。

**建議 S-1:聊天 tab 維持「清單上方的頂端搜尋欄」**,配合 T-1 放在大標題下方,與檔案 App 相同。為何:底部已有 tab bar;搜尋只搜聊天列表(範圍跟內容綁在一起,HIG 的 inline 情境)。目前 `.always` 的取捨(捲動不收起,`SpacesListView.swift:234-236`)可保留。
**不建議**做搜尋 tab:搜尋範圍只有聊天列表,不是跨 tab 的探索區。

**建議 S-2:其他 tab 不加搜尋**(主機、流量、設定內容少)。檔案 tab 若未來要搜尋,同 S-1 放清單上方,麵包屑放在搜尋下方或改成標題選單(另議)。

### 2.4 列表列的資訊層級與字級

規範:

- 「Adjust font weight, size, and color as needed to emphasize important information and help people visualize hierarchy. Be sure to maintain the relative hierarchy … when people adjust text sizes.」「Consider using the built-in text styles.」【HIG】[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- 「Keep text truncation to a minimum as font size increases.」「Consider adjusting your layout at large font sizes. … inline items (like glyphs and timestamps) … can crowd text and cause truncation … consider using a stacked layout where text appears above secondary items.」【HIG】Typography › Supporting Dynamic Type
- 「Keep item text succinct so row content is comfortable to read.」「an ellipsis in the middle of text can make an item easier to distinguish」【HIG】[Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- 「Choose a row style that fits the information you need to display.」【HIG】同上
- iOS 預設字級(Large):Large Title 34、Headline 17 semibold、Body 17、Subhead 15、Footnote 13、Caption 1 12、Caption 2 11【HIG】Typography › Specifications

系統 App:【實測】訊息列:頭像、第一行名稱(粗)與右上時間+`›`、第二行起預覽(次要色)。郵件(HIG 原文提到的系統例,模擬器沒有):寄件者/時間、主旨、預覽三層——**未在本機截圖確認**。

**建議 L-1:列的層級固定三階**:主要文字 `.body`(或 `.headline`,只用一種)主要色;次要文字 `.subheadline` `secondaryText`;中繼資料(時間、百分比)`.footnote` `secondaryText`。所有列(Agents、Spaces、檔案、主機)共用。
**建議 L-2:狀態類小標籤(離開期間、釘選、靜音)不放在主要文字同一行的中間**,改放第二行開頭或右欄(修 I-18)。為何:HIG 指出行內符號與時間會擠壓文字;主要文字應最後被截斷。
**建議 L-3:AX 字級時改堆疊**(主要文字在上、時間與環在下)——`AgentRowView` 已做(`AgentListView.swift:513`),共用列要保留這個行為。

### 2.5 色彩與對比

規範:「At a minimum, make sure the contrast ratio between colors is no lower than 4.5:1」(`apple-hig-drover-chat.md` §3.5 引 Dark Mode／Accessibility);「Avoid redefining the semantic meanings of dynamic system colors.」【HIG】Color;「Ensure that your app looks good in both appearance modes.」【HIG】[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)

**建議 K-1**:頂列用系統單色(會依底下內容自動深淺),不另驗對比;內容層繼續用 `AccessibleColors.secondaryText`。
**建議 K-2**:聊天 tab 內容在沒有主機主題時,tint 目前會落到 TabView 的 tab 選取色(探針:`.tint(nil)` 讓內容取到外層 TabView 的 tint)而不是 `AccentColor`;淺色模式兩者不同(`#075C45` vs `#0B7A5C`)。統一 tint 來源時一併修正。【實測+程式】

### 2.6 列的一致性(跨畫面)

規範:「Components should always support the same set of core interactions.」「When content is intentionally grouped, it should stay together, even as the layout adapts.」【WWDC】[WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/);「Keep consistent groupings and placement across platforms.」【HIG】Toolbars;「Make sure the meaning of each control is clear. Don't make people guess or experiment…」【HIG】Toolbars › Actions

**建議 R-1**:同一個 Agent 在兩種檢視用同一個主要名稱(見 §4)。
**建議 R-2**:檢視切換改成看得出語意的控制(見 §6 待決定 D-6)。

---

## 3. 「header 文字統一白色、大小固定」與 HIG

### 3.1 白色

| 事實 | 來源 |
|---|---|
| 工具列與 tab bar 的符號、文字預設單色,底下內容亮時變暗、暗時變亮 | 【HIG】Color › Liquid Glass color |
| 深色模式頂列符號是白、淺色模式是黑(訊息、檔案、設定、探針) | 【實測】 |
| 使用者截圖是深色模式;白色的那幾顆正是「沒上色」的系統單色 | 【截圖】【實測】 |
| App 有「外觀:淺色／深色／自動」設定(`SettingsView.swift:35-43`),淺色一定會出現 | 【程式】 |

結論:**「白色」與 HIG 不衝突,前提是解讀成「系統單色」**——深色模式自然是白色。若寫死 `.white`,淺色模式頂列會白字疊在淺色玻璃上,看不見,違反對比要求。

選項:
- **W-1(建議)系統單色**:不寫顏色,深色白、淺色黑。符合 HIG、與系統 App 一致。
- **W-2 只在深色寫白、淺色寫黑**:結果與 W-1 相同,但多一份要維護的顏色,而且失去「底下內容很亮時自動轉暗」的適應。不建議。
- **W-3 全 app 強制深色**:HIG 只在「immersive media viewing」這類情況建議只用深色【HIG】Dark Mode;Purrdr 不屬於,且已有外觀設定。不建議。

### 3.2 大小固定

| 事實 | 來源 |
|---|---|
| 在 AX5(accessibility-xxxl)時,系統工具列的符號、膠囊與 tab bar 尺寸不變;大標題與列表內容明顯放大 | 【實測】探針,iPad 窄視窗與 iPhone |
| 工具列裡自訂的 `Text(.headline)`(模擬主機選單)在 AX5 只小幅放大,系統有上限 | 【實測】 |
| 「Rely on the large content viewer only in situations where items must remain small due to unavoidable design constraints. For example, buttons in a tab bar remain small…」「Don't use the large content viewer as a replacement for proper Dynamic Type support」 | 【文件】[accessibilityShowsLargeContentViewer](https://developer.apple.com/documentation/swiftui/view/accessibilityshowslargecontentviewer()) |
| 「Ideally, give people the option to enlarge text by at least 200 percent」 | 【HIG】[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| 「Keep text truncation to a minimum as font size increases.」 | 【HIG】Typography |
| 目前三份主機選單用 `.subheadline`/`.headline` text style,會隨字級(在系統上限內)變動,且彼此大小不同 | 【程式】 |

結論:**頂列控制「大小固定」與系統行為一致,不衝突**——系統本身就讓工具列與 tab bar 維持小尺寸,用 large content viewer(長按放大顯示)補足。**衝突的是把「固定」延伸到大標題或列表內容**:那兩者 HIG 要求隨 Dynamic Type 放大,系統 App 也是。

選項:
- **F-1(建議)頂列控制固定在一個字級、加 large content viewer**:頂列所有文字用同一個 text style(建議 `.subheadline.weight(.semibold)` 15pt,或 `.headline` 17pt,擇一),並 `.dynamicTypeSize(...DynamicTypeSize.large)` 鎖上限;每顆加 `accessibilityShowsLargeContentViewer`。大標題、列表照常放大。為何:視覺上「大小固定」,又有官方的無障礙補位,稽核也看得到 large content viewer。
- **F-2 頂列跟系統預設(在系統上限內小幅放大)**:只統一 text style。最省事,但「固定」做不到。
- **F-3 連大標題也固定**:不建議,違反 Typography 的 Dynamic Type 指引,也會被無障礙稽核(`AccessibilityAuditUITests`)判為 Dynamic Type 不支援(專案已有前例:`SpacesListView.swift:133` 的註解)。

另:主機名稱很長時,固定字級的膠囊要用中段省略(HIG Lists:「an ellipsis in the middle of text」)並設最大寬度,避免右側項目被擠進溢出選單(I-7)。

---

## 4. Agents 與 Spaces 的統一方案

### 4.1 共同骨架(三個方案共用)

```
┌──────┬───────────────────────────────────────┬──────────┐
│ 頭像  │ ① 主要名稱(1 行,最後才截斷)           │ ④ 時間    │
│ +狀態 │ ② 次要行(subheadline、secondaryText)  │ ⑤ 環/數字 │
│      │ ③ 預覽(可選,1–2 行)                  │          │
└──────┴───────────────────────────────────────┴──────────┘
```

固定規則:
- 頭像(`AgentStatusAvatar`)一律對齊**第一行**(`alignment: .top`,修 I-17)。
- ① 只放名稱,**不放任何膠囊**;釘選/靜音/離開期間放 ② 開頭或 ④ 下方(修 I-18)。
- ④ 永遠是時間(沒有就空白,不讓位給別的東西);⑤ 永遠是 context 環(沒有就空白)。
- 終端機列(沒有 Agent)用同一骨架:頭像是終端機符號,② 寫「終端機」,沒有 ④⑤。
- 多個 Pane 的 Tab:① 用 Tab 名稱,② 寫「N 個 Pane」或其中最需要處理的 Agent。
- AX 字級時 ④⑤ 移到文字下方(既有行為)。
- VoiceOver 句子由同一處組成(既有 `AgentRowView.accessibilityText` 搬過去)。

兩種檢視**只差在分組**:Agents 是單一清單(順序:釘選、需要你、工作中、閒置);Spaces 依「主機 · workspace」分段。主機與 workspace 在 Spaces 已寫在段落標題,所以列裡省略。

### 4.2 方案

**方案 A:郵件式三層(建議)**

| 槽位 | Agents 檢視 | Spaces 檢視 |
|---|---|---|
| ① | workspace · Tab 名稱 | Tab 名稱 |
| ② | Agent 標題(對話主題) | Agent 標題 |
| ③ | 主機圖示 + 主機 · 最後一句(1 行) | 最後一句(1 行) |
| ④⑤ | 時間、context 環 | 時間、context 環 |

- 優點:兩種檢視**同一列一模一樣**,只是 Spaces 把段落標題已說的字省掉;Agents 終於看得到 Agent 標題(I-15);高度與現在的 Agents 列相同(1 行標題 + 2 行預覽 → 1+1+1)。
- 缺點:預覽從 2 行變 1 行;Spaces 列變高(現在 1–2 行 → 3 行),一屏看到的 Tab 變少。
- 資料:`SpacesTab` 要帶該 Tab 的 `AgentRow`(單一 Agent 的 Tab)或摘要(多 Pane),在 `SpacesProjection` 組。

**方案 B:訊息式兩層(精簡)**

| 槽位 | Agents 檢視 | Spaces 檢視 |
|---|---|---|
| ① | Tab 名稱(人取的),沒有就 Agent 標題,再沒有「Tab N」 | 同左 |
| ② | 主機 · workspace · 最後一句 | 最後一句 |
| ④⑤ | 時間、context 環 | 時間、context 環 |

- 優點:最密;兩種檢視的 ① 規則完全相同。
- 缺點:Agents 的 ② 很擠(主機、workspace、預覽三段),預覽常被截掉;人取的 Tab 名稱與 Agent 標題只能顯示一個。

**方案 C:只對齊槽位(最小改動)**

保留各自的內容,只統一:頭像對齊第一行、① 規則(兩邊都用「workspace · Tab」或都用「Agent 標題」擇一)、④⑤ 位置、膠囊移出 ①;Spaces 仍沒有時間與預覽。
- 優點:改動最小,不動資料投影。
- 缺點:使用者抱怨的「Spaces 沒有時間、用量、預覽」不會解決;兩個 view 仍分開,之後還會漂移。

建議 A。若覺得列太高,選 B。

### 4.3 「聊天」tab 與 Agents／Spaces 的名稱與圖示

- tab 叫「聊天/Chats」(符號 `bubble.left.and.bubble.right.fill`),裡面的檢視叫「Agents/Spaces」,而 GLOSSARY 把「Chats 檢視」列為避免用語(`GLOSSARY.md:141`)。使用者在 tab bar 看到「聊天」,點進來看不到「聊天」這個詞。
- 檢視切換的符號:Agents `person.2`(人群)、Spaces `square.grid.2x2`(方格,與「所有主機」相同,I-5)。
- HIG:「Make sure the meaning of each control is clear. Don't make people guess or experiment」;「Prefer simple, recognizable symbols … except for actions … that aren't well-represented by symbols」【HIG】Toolbars;分段控制「Consider a segmented control to switch between closely related subviews」「Prefer using either text or images — not a mix」「Use nouns or noun phrases for segment labels」【HIG】[Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)。標題選單 `toolbarTitleMenu`(iOS 16)【文件】[toolbarTitleMenu](https://developer.apple.com/documentation/swiftui/view/toolbartitlemenu(content:))。

選項見 §6 D-6、D-7。

---

## 5. 架構:讓一致性不靠人工維持

用 codebase-design 的詞彙:module、interface、seam、depth、adapter、deletion test。

### 5.1 頂列 module(`TabTopBar`)

**現況**:每個 tab 自己排 `ToolbarItem`、自己決定 placement、spacer、tint、字級;`TopBarMetrics` 只收了幾個尺寸常數,是 shallow module(介面幾乎等於實作)。主機選單有三個 adapter 但沒有共同 interface。

**建議 interface**(只有兩個輸入):

```swift
// 示意,不是要直接貼的程式碼
.tabTopBar(
    scope: HostScope?,            // nil = 這個 tab 沒有主機範圍
    actions: [TopBarAction]       // 例:.add(label:, action:);最多一顆
)
```

- `HostScope` 是 seam,三個 adapter:目前主機(`MergedAgentListModel.currentHost`,含所有主機)、選取中主機(`HostPickerModel`,不含所有主機)、流量(`DataUsageModel.host`,含所有主機)。三個 adapter → 是真的 seam(skill:「Two adapters means a real one」)。interface 只要「選項、目前值、選擇、是否含所有主機、新增主機」。
- module 內部決定(呼叫端碰不到):placement(左上主機、右上動作、最右帳號)、`ToolbarSpacer`、`.tint(nil)` 隔離、單色、字級與 `dynamicTypeSize` 上限、large content viewer、主機名中段省略與最大寬度、標題策略(T-1/T-2/T-3 擇一後寫死在這裡)、帳號鈕。
- 帳號鈕不再以 `AnyView` 傳進各畫面(I-3);`MemberModel` 與開帳號的 closure 由 module 從 environment 取得或由 `TopNavigationView` 一次注入。

**Deletion test**:刪掉這個 module,placement、spacer、tint、字級、帳號鈕這些決定會**回到五個 tab 各寫一次**——那正是今天的狀態,而三種字級(I-1)、四種顏色來源(I-2)、三種帳號組法(I-3)就是證據。所以它在賺回複雜度。反過來,`TopBarMetrics` 刪掉只會讓 4 個常數散回原處,不會多出決策,所以它是 pass-through,可以收進新 module。

**測試面**:
- interface 就是測試面:對 `HostScope` 的三個 adapter 做單元測試(選項、所有主機、選擇後寫回哪個值)——這些規則目前散在三個 view 裡,沒有單元測試。
- 防漂移:比照既有的 `GlassLevelUsageTests`(掃原始碼),加一個測試擋「頂列 module 以外出現 `ToolbarItem(placement: .primaryAction)`／`topBarLeading`／`Color.appAccent` 用在工具列」,或讓 `HostPickerButton(inToolbar:)` 的工具列版本變成 module 私有,呼叫端在型別上就排不出另一種。
- UI 測試:日常組串一步「切 5 個 tab,主機選單與帳號鈕的 frame 高度、x 位置相同」(identifier 已有:`toolbar.currentHost`、`files.host`、`hosts.host`、`dataUsage.host`、`toolbar.account`)。

### 5.2 頁面 module(`TabPage`)

把 `appGroupedList()`、`appPageContentWidth()`、`listStyle(.insetGrouped)`、頂端邊距收成一個 `.tabPage()`。流量 tab 也改用它(卡片內容可以放在 `List` 的 section 裡,或 module 提供 ScrollView 版但寬度與邊距相同)。解 I-11、I-13。Deletion test:刪掉後寬度上限(720 vs 640)與 list style 會回到各頁——今天已經漂移,所以值得。

### 5.3 聊天列 module(`ChatRow`)

**建議 interface**:

```swift
// 示意
struct ChatRowContent: Equatable, Sendable {   // 放 PurrdrAgentFeatures,純值
    var avatar: Avatar
    var primary: String          // ①
    var secondary: String?       // ②
    var preview: Preview?        // ③
    var badges: [Badge]          // 釘選、靜音、離開期間 —— 位置由 view 決定
    var time: AgentRow.Time?     // ④
    var contextPercent: Int?     // ⑤
    var todos: (done: Int, total: Int)?
    var accessibilityText: String
}
extension ChatRowContent {
    init(agent: AgentRow, host: HostLabel?, grouping: Grouping)   // Agents
    init(tab: SpacesTab, grouping: Grouping)                       // Spaces
}
struct ChatRowView: View { let content: ChatRowContent }          // PurrdrFeatures,唯一的列 view
```

- 深度:呼叫端只交「一個 Agent 或一個 Tab + 分組方式」,得到整列;名稱的備援規則(人取的 Tab 名 > Agent 標題 > Tab N)、哪些字因分組省略、膠囊放哪、AX 堆疊、VoiceOver 句子都在 module 內。
- seam 放在 `ChatRowContent`(純值,在 `PurrdrAgentFeatures`,只依賴 Core,符合依賴方向)。規則用 Swift Testing 測值,不必 UI 測試;`ChatRowView` 只負責排版,一個 view 兩種檢視共用。
- `SpacesProjection` 要讓單一 Agent 的 Tab 帶出 `AgentRow`(或它的時間、預覽、進度),這是資料面唯一的改動。
- **Deletion test**:刪掉 `ChatRowContent`,名稱規則、省略規則、VoiceOver 句子會在 `AgentRowView` 與 `SpacesTabLabel` 各寫一份——今天就是這樣,I-15、I-16 就是兩份漂移的結果。刪掉 `ChatRowView`,兩種檢視的版面會分開演化(I-17)。兩者都在賺回複雜度。

### 5.4 主機範圍的單一來源

GLOSSARY 已定義「目前主機」與「選取中主機」兩個值(`GLOSSARY.md:28-34`)。`HostScope` 的 adapter 只是把這兩個值(加上流量自己的)包成同一個 interface,不新增第三種主機值;流量 tab 的主機選擇在 DESIGN 寫「改它就是改全 app 的目前主機」(`DESIGN.md:193`),可以直接用「目前主機」adapter,從三個降成兩個。

---

## 6. 待使用者決定

| # | 問題 | 選項 | 建議 |
|---|---|---|---|
| D-1 | 頂列顏色 | ① 全部系統單色 ② 主機選單與 `plus` 綠、其他單色(現況的意圖,#477) ③ 只有新增聊天用 `.glassProminent` 綠底 | **①**。符合 HIG「預設單色、顏色留給主要動作與狀態」,也就是使用者說的「統一白色」(深色白、淺色黑) |
| D-2 | 「白色」的實作 | ① 系統單色 ② 寫死白 ③ 強制深色 | **①**(②淺色看不見,③不符 HIG) |
| D-3 | 頂列字級 | ① 固定一個 text style + 上限 `.large` + large content viewer ② 跟系統預設小幅放大 | **①**;text style 二選一:`.subheadline.semibold`(15pt,較不擠)或 `.headline`(17pt,與導覽列標題同級)——建議 15pt |
| D-4 | 頂列的主機圖示 | ① 單色線條符號 ② 維持綠色圓形徽章 | **①**(玻璃上不再有色塊) |
| D-5 | 標題呈現 | ① 五個 tab 都大標題=tab 名(T-1) ② 都不顯示(T-2) ③ 主機選單當大標題(T-3,先做原型) | **①**;捲動自動收起 |
| D-6 | Agents／Spaces 切換控制 | ① 維持只有符號的切換鈕,改符號 ② 文字選單膠囊「Agents ▾」 ③ 標題選單(大標題「聊天 ▾」,`toolbarTitleMenu`) ④ 列表頂端分段控制「Agents｜Spaces」 | **④**(HIG 分段控制正是「切換密切相關的子畫面」,一眼看得出目前是哪個;#313 曾用兩列勾選後改掉,這次是分段控制不是勾選列)。若不想佔一列,選 **③**,配合 D-5 ① 很自然 |
| D-7 | 「聊天」tab 名稱 | ① 維持「聊天」 ② 改「Agents」 | **①** 維持,但檢視名稱不變(GLOSSARY 已定);若選 D-6 ③,標題就是「聊天 ▾」,切換的語意清楚。Spaces 的符號若保留,改成不與「所有主機」重複的符號(例 `rectangle.split.2x1`)——符號選擇**未逐一驗證 SF Symbols 名稱可用性** |
| D-8 | 列的統一方案 | A 郵件式三層 / B 訊息式兩層 / C 只對齊槽位 | **A** |
| D-9 | 「離開期間」放哪 | ① 第二行開頭的小標籤 ② 右欄時間下方 ③ 只用列尾圓點+VoiceOver | **①**(不擠主要名稱;文字說明不只靠顏色) |
| D-10 | 新增聊天的符號 | ① `plus`(現況) ② `square.and.pencil`(HIG 標準符號表的 Compose,DESIGN.md 原定) | **②**:HIG Icons 標準符號「Compose: square.and.pencil」「Add: plus」【HIG】[Icons](https://developer.apple.com/design/human-interface-guidelines/icons#Standard-icons);新增聊天是「撰寫」,上傳與新增主機才是「Add」 |
| D-11 | 流量 tab 版面 | ① 改成 inset grouped `List`(卡片放進 section) ② 保留 ScrollView 卡片,但寬度、邊距與其他頁一致 | **②**(圖表卡片放進 List 會受列高與分隔線限制;先統一寬度 720pt 與頂端邊距) |
| D-12 | 是否抽頂列與聊天列 module | 抽 / 不抽,逐頁修 | **抽**(§5);先抽頂列(影響 5 個 tab),再抽聊天列 |
| D-13 | DESIGN.md 同步 | 決定後一次改寫「共用框架」「聊天列表頂部」 | 必做;目前三處與實作矛盾(I-10) |

---

## 附錄 A:已查證但沒有定論、或查不到的項目

- **iOS 26 實機的 tint 行為**:探針跑在 iOS 27.0 模擬器(本機沒有 iOS 26 runtime)。使用者截圖(TestFlight,版本號看不出 iOS 版本)中檢視切換為白色,與探針「`.tint(nil)` → 單色」一致,所以判斷 iOS 26 行為相同;但**沒有在 iOS 26 runtime 上實測**。
- **郵件 App 的列版面**:模擬器沒有郵件;只引用 HIG 原文提到郵件的搜尋位置。郵件列「寄件者/主旨/預覽」三層的描述是一般認知,**未截圖確認**。
- **`ToolbarItemPlacement.largeTitle` 捲動收合時的行為**:只讀到文件一句說明,**未實測**(T-3 要先做原型)。
- **大標題在 AX5 的放大幅度**:iPad 窄視窗探針確認大標題會放大;iPhone 截圖被健康 App 的系統通知 alert 遮住(模擬器無法以命令列關閉),iPhone 的 AX5 大標題**未截到**,只有 iPad 窄視窗的證據。
- **HIG 是否直接規定「頂列文字固定大小」**:Toolbars、Typography、Accessibility 三頁都沒有針對工具列文字字級的明文;結論來自系統行為實測與 large content viewer 文件。

## 附錄 B:實測截圖(本機 scratchpad,不進 repo)

- 系統 App:訊息、檔案、設定、健康,深色／淺色(iOS 27.0 模擬器)。
- 探針:環境 tint 傳遞、自訂 `ShapeStyle` tint、`.tint(nil)`、AX5 對大標題／工具列／tab bar 的影響、左側寬膠囊造成右側項目溢出。

## 附錄 C:來源

- HIG:[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)、[Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)、[Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Branding](https://developer.apple.com/design/human-interface-guidelines/branding)、[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)、[Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)、[Icons](https://developer.apple.com/design/human-interface-guidelines/icons)、[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- SwiftUI:[toolbarTitleDisplayMode .inlineLarge](https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge)、[ToolbarItemPlacement.largeTitle](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/largetitle)、[.largeSubtitle](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/largesubtitle)、[toolbarTitleMenu](https://developer.apple.com/documentation/swiftui/view/toolbartitlemenu(content:))、[searchToolbarBehavior](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:))、[sharedBackgroundVisibility](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))、[accessibilityShowsLargeContentViewer](https://developer.apple.com/documentation/swiftui/view/accessibilityshowslargecontentviewer())、[navigationSubtitle](https://developer.apple.com/documentation/swiftui/view/navigationsubtitle(_:))
- WWDC25:[323 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)、[356 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)、[219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- repo 內:`docs/research/apple-hig-drover-chat.md`(§1.4、§3.4–3.6、§4、§6、§7)、`DESIGN.md`、`GLOSSARY.md`;主 worktree 未追蹤的 `docs/research/ios27-design-language.md`
