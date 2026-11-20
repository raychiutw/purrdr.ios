# 選擇控制盤點：tab 式與上下箭頭選單(截至 2026-11-20)

> **範圍**:branch `ticket/313-expanded-options` 的工作目錄(含尚未 commit 的修改),掃 `src/PurrdrFeatures/`、`src/App/`、`src/PurrdrAgentFeatures/`。行號都指這份工作目錄。
> **依據**:Apple Human Interface Guidelines 與 SwiftUI 文件的一手資料(developer.apple.com 的 JSON 資料取原文，2026-11-20 擷取;HTML 頁面要 JavaScript 才有內容，所以改讀 `tutorials/data/…json`)。引用寫成「原文短句」+ 連結。
> **已決定、不再評估**(#313):選項盡量用勾選列上下攤開(`.pickerStyle(.inline)`);例外是數量沒有上限的主機選擇(`HostFilterMenu`、`HostPickerButton`、方案用量的主機)維持選單，頁面層級的 Agents／Spaces 切換(`AgentListModeControl`)維持分段。只有**動作**的選單不在範圍內。規則在 `DESIGN.md:42`,守門測試是 `tests/PurrdrFeaturesTests/SelectionControlUsageTests.swift`。
> **先講 HIG 的立場**:HIG 本身**沒有**要求選項一律攤開——它把 pop-up button 描述成「a space-efficient way to present a wide array of choices」。「一律攤開」是 #313 的專案決定;HIG 支持的是攤開後的樣子：iOS 列表選項以列尾勾號表示選取，以及「iOS Settings uses a hierarchy of lists to help people choose options」。下面的「HIG 依據」只引用這些有出處的部分。

## 結論摘要

**還沒轉換、用 `Picker` 寫的選擇：沒有了。** 剩下的 `Picker` 都是 #313 接受的例外。還沒改的只有兩處**自己畫的單選列**(守門測試看不到):主機編輯器的連線方式、Purrdr Plus 的方案卡片。兩處都已經是上下排列，但用的是「列首圓圈」(macOS radio button 的樣子),不是 iOS 列表的「列尾勾號」。

| 位置 file:line | 使用者在選什麼 | 目前控制 | 建議 | HIG 依據 |
|---|---|---|---|---|
| `src/PurrdrFeatures/HostEditorView.swift:194-234`(`connectionMethodSection`、`methodCard`) | 連線方式:Tailscale SSH／OpenSSH／HTTPS(固定 3 個，每個附一句說明;一開始可以都沒選) | 自己畫的 `Button` 列，列首 `checkmark.circle.fill`／`circle`,選中的列有 `.isSelected` | **建議轉換**:改成 `Picker(selection: $model.connectionMethod)` + `.pickerStyle(.inline)`,選項 label 是兩行(標題 + 說明),tag 用 `Optional`,讓「沒選」可以存在;或保留自繪，但改成列尾 `checkmark`。`DESIGN.md:69` 明寫「選中是主色 `checkmark.circle.fill`」,要一起改 | iOS 列表選項以列尾勾號表示選取:「a table that lists options often highlights a row only briefly before adding an image — such as a checkmark」([lists-and-tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables));填滿／空心圓是 macOS 的 radio button:「A radio button’s state is either selected (a filled circle) or deselected (an empty circle)」,出現在 macOS 那一節([toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)) |
| `src/PurrdrFeatures/PlusView.swift:123-127`、`:256-294`(`PlanRow`) | 訂閱方案(由 StoreKit 決定，目前 2～3 個) | 自己畫的圓角卡片，列首圓圈，選中時有主色外框 | **保留**(待確認):付費牆的方案卡片是刻意設計(`DESIGN.md:62`),要讓價格醒目，不是設定列。如果要完全一致，可以改成列尾勾號，卡片樣式不變 | 同上，iOS 列表選項用勾號表示([lists-and-tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables));HIG 沒有付費牆方案卡片的專門指引【未查得】 |
| `src/PurrdrFeatures/SpacesListView.swift:133-138`(`AgentListModeControl`) | Agents／Spaces 檢視(固定 2 個) | `Picker` + `.pickerStyle(.segmented)` | **保留**(#313 例外) | 「Consider a segmented control to switch between closely related subviews」([segmented-controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls));iPhone 上「no more than about five segments」 |
| `src/PurrdrFeatures/PlanUsageView.swift:20-25` | 方案用量的主機(主機數量沒有上限) | List 裡預設樣式的 `Picker`(iOS 畫成帶 ↕ 的選單列) | **保留**(#313 例外) | 「Pop-up buttons are a space-efficient way to present a wide array of choices」([pop-up-buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons));使用者自己加進來的內容，選單長也可以:「a menu contains user-defined or dynamically generated content … a long menu is fine」([menus](https://developer.apple.com/design/human-interface-guidelines/menus)) |
| `src/PurrdrFeatures/TopNavigationView.swift:396-436`(`HostFilterMenu`) | 主機篩選：所有主機或某一台(沒有上限) | `Menu` 裡放 `Picker`,label 是自己排的 `chevron.down`(▾) | **保留**(#313 例外) | 同上([pop-up-buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons)、[menus](https://developer.apple.com/design/human-interface-guidelines/menus)) |
| `src/PurrdrFeatures/HostPickerViews.swift:9-41`(`HostPickerButton`;用在 `PaneTerminalView.swift:98`、`NewChatView.swift:133`、`FolderBrowserView.swift:31`) | 這個畫面用的主機(沒有上限) | `Menu` 裡放 `.inline` 的 `Picker`,label 有 `chevron.down` | **保留**(#313 例外) | 同上 |
| `src/PurrdrFeatures/HostIconBadge.swift:58-96`(`HostIconGrid`,用在 `HostEditorView.swift:61`) | 主機圖示(固定 12 格) | 直接攤開的格子，選中的格子有主色外框與 `.isSelected` | **保留**:已經攤開、看得到所有選項;圖示用格子比一列一個好比較 | HIG 沒有圖示格子的專門指引【未查得】;專案決定見 `DESIGN.md:69`「12 格直接展開」 |
| `src/PurrdrFeatures/SlashPanelCard.swift:56-100`(`/model` 等面板選項) | agent 面板列出的選項(由 agent 決定) | 直排的列，目前使用中的列尾 `checkmark`,游標列有填色 | **保留**:已符合。點列只移動 agent 的游標，由面板的確認鈕送出 | 列尾勾號([lists-and-tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)) |
| `src/PurrdrFeatures/SlashPanelCard.swift:142-164`(`adjuster`) | agent 面板裡左右調整的值(只拿得到 agent 的一行文字，不知道有哪些值) | ‹ › 兩顆鈕送 ←／→ | **保留**:列舉不出選項，沒辦法攤開 | 不適用 |
| `src/PurrdrFeatures/PaneTerminalView.swift:175-189`(`FontSizeMenu`) | 終端機字級(放大／縮小／預設) | 工具列 `Menu`,裡面 3 個動作 | **保留**:是調整的動作，不是在一組選項裡選一個 | pull-down button 放「commands or items that are directly related to the button’s action」,而且「listing a minimum of three items can help the interaction feel worthwhile」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/ComposerImageViews.swift:215-240`、`:258-267` | 圖片從哪裡來(相簿、拍照、貼上、選檔案) | 有 `primaryAction` 的 `Menu` + `confirmationDialog` | **保留**:選了之後馬上打開那個來源，是動作 | 「An Add button could present a menu that lets people specify the item they want to add」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/TopNavigationView.swift:238-257`(「⋯」) | 新增聊天、主機、方案用量、登入 Shell、檔案、設定 | `Menu` | **保留**:動作與工具入口 | 「Consider using a More pull-down button to present items that don’t need prominent positions」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/StopBar.swift:81-107` | 停止／強制結束 | 有 `primaryAction` 的 `Menu`(長按) | **保留**:動作 | 長按開選單:「Safari responds to a touch and hold gesture on the Tabs button by displaying a menu」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/PlanUsageView.swift:181-189`(「⋯」) | 關閉 Claude 方案用量 | `Menu`,只有 1 個動作 | **保留**(不是選項);順帶一提：只有 1 項，可以考慮改成一般按鈕 | 「If you need to list only one or two items, consider using alternative components」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/PushDevicesSection.swift:150-164` | 通知裝置的重新命名／關閉通知 | `ellipsis.circle` 的 `Menu`,1～2 個動作 | **保留**(不是選項);同上，項目少 | 同上 |
| `src/PurrdrFeatures/YouShouldKnowViews.swift:55-60` | 放不下時收起來的次要動作 | `ViewThatFits` 退回「More」`Menu` | **保留**:動作 | 「More」pull-down([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/WorkspaceActionsViews.swift:81-88`、`:171-190`、`:197-209` | workspace 操作;釘選／取消釘選、靜音／取消靜音 | `contextMenu` | **保留**:動作與 on/off 的切換項目，不是多選一 | 「it can be efficient to create a single, toggled menu item that communicates the current state」([menus](https://developer.apple.com/design/human-interface-guidelines/menus)) |
| `src/PurrdrFeatures/HostListView.swift:146-161` | 主機的編輯、重新命名、分享、更新主機服務、刪除 | `.contextMenu` | **保留**:動作。圖示選擇已經移走(`:157` 的註解) | context menu 是「a small number of frequently used actions」([menus](https://developer.apple.com/design/human-interface-guidelines/menus)) |
| `AgentFileCardView.swift:213`、`AgentImageCardView.swift:93`、`ShellRunView.swift:125`、`BlockedPromptView.swift:221`、`PairedDevicesSection.swift:69`(都在 `src/PurrdrFeatures/`) | 拷貝、分享、撤銷、移除 | `.contextMenu` | **保留**:動作 | 同上 |
| `StopBar.swift:229`、`HostEditorView.swift:130`、`HostListView.swift:98`、`PairedDevicesSection.swift:105`、`PushDevicesSection.swift:96`、`MemberView.swift:347`、`WorkspaceActionsViews.swift:227` | 確認破壞性操作或捨棄修改 | `confirmationDialog` | **保留**:確認，不是選項 | 「When people choose a destructive action, the system displays an action sheet」([pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)) |
| `src/PurrdrFeatures/BlockedPromptView.swift:118-145`(`optionButton`) | 回答 agent 的問題 | 直排的按鈕，點了直接送出;多選題照 agent 畫方框勾選 | **保留**:每列是一個「送出回答」的動作，已經攤開 | 不適用(動作) |
| `src/PurrdrFeatures/WindowViews.swift:21-83` | iPad 側欄的主機與 workspace | `List(selection:)`,主機列尾 `checkmark` | **保留**:已經是上下排列、列尾勾號 | 列尾勾號([lists-and-tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)) |
| `src/PurrdrFeatures/WindowViews.swift:312` | 硬體鍵盤指令 | `CommandMenu` | **保留**:選單列指令 | menu bar 收「all the commands people can perform」([menus](https://developer.apple.com/design/human-interface-guidelines/menus)) |
| `SettingsView.swift:56,58`、`HostThemeViews.swift:76`、`HostServiceSection.swift:60`、`HostSyncSection.swift:11`、`CodexLauncherSection.swift:11`、`AppLockViews.swift:155`、`HostPushSection.swift:56`;`HostPushSection.swift:145`(通知種類，可以多選) | 開／關;通知種類是多選 | List 列裡的 `Toggle` | **保留**:兩種狀態或多選，不是多選一 | 「Use the switch toggle style only in a list row」([toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)) |
| `src/PurrdrFeatures/PaneTerminalView.swift:~300-342`(按鍵列的 ctrl／alt) | 修飾鍵鎖定 | 會切換外觀的按鈕 | **保留** | 「Outside of a list, use a button that behaves like a toggle, not a switch」([toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)) |
| `src/PurrdrFeatures/NewChatView.swift:60-66` | 主機上的資料夾 | 推入 `FolderPickerView` 的 `NavigationLink` | **保留**:選項很多又有階層，本來就應該推入 | 「Consider the navigation link style when you have a large number of options」([NavigationLinkPickerStyle](https://developer.apple.com/documentation/swiftui/navigationlinkpickerstyle)) |
| `src/PurrdrFeatures/FolderBrowserView.swift:186-220`(麵包屑)、`DelegationViews.swift:490-502`(展開／收合的 `chevron`) | 導覽、展開 | 橫捲的麵包屑按鈕、揭露鈕 | **保留**:不是下拉選單，`chevron` 只表示展開方向 | 不適用 |
| `TabView`／`.tabItem` | — | 三個資料夾都沒有(`SpacesLayoutView.swift:75` 的 `LayoutTabView` 是 herdr Tab 的版面圖，不是 `TabView`) | 不適用;`DESIGN.md:54`「不採 tab bar」 | 「A tab bar lets people navigate between top-level sections of your app」([tab-bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)) |

`src/App/` 與 `src/PurrdrAgentFeatures/` 沒有任何選擇控制(`src/App/Purrdr/PurrdrApp.swift:104` 只是 `UserDefaultsHostPickerStore` 的注入)。

**依建議分類**(以上表一列算一筆):

- 建議轉換：1 筆(連線方式)
- 待確認、傾向保留：1 筆(付費牆方案卡片)
- 轉換成 `.navigationLink` 推入：0 筆(唯一適合推入的資料夾已經是推入)
- 保留：25 筆。其中 #313 例外 4 筆(Agents／Spaces、方案用量主機、主機篩選、主機挑選鈕),其他是動作選單、確認、開關、已經攤開的列與導覽
- 不適用：1 筆(`TabView`／`.tabItem`,程式碼裡沒有)

**順帶發現：過時的註解**(只要改文字):

- `src/PurrdrFeatures/SlashPanelCard.swift:10`:「effort 滑桿以分段控制呈現」,但 `:103` 已經改成直排勾選列。
- `src/PurrdrFeatures/NewChatView.swift:6`、`:19`:寫 Agent 是「分段控制」,但 `:36-42` 已經是 `.inline`。

## 已轉換確認

| 位置 | 確認結果 |
|---|---|
| 設定的外觀 `src/PurrdrFeatures/SettingsView.swift:38-44` | `Picker("Appearance")` + `.pickerStyle(.inline)` + `.labelsHidden()`,區段標題「Appearance」 ✔ |
| 主機編輯器的登入方式 `src/PurrdrFeatures/HostEditorView.swift:328-334` | `Picker("Sign In With")` + `.inline` ✔。同一個 Section 在選項後面接著放那種方式的欄位(`:338-`),選項列和欄位在同一個區段 |
| 新增聊天的 Agent `src/PurrdrFeatures/NewChatView.swift:36-42` | `.inline` ✔(註解過時，見上) |
| 方案用量的 Agent `src/PurrdrFeatures/PlanUsageView.swift:31-36`、剩餘／已用 `:44-48` | 兩個都是 `.inline`,各自一個 Section ✔;「顯示」已經不在「⋯」裡(`:179` 的註解,`:181-189` 只剩動作) |
| `/effort` 層級 `src/PurrdrFeatures/SlashPanelCard.swift:103-138` | 直排 `levelRow`,目前那層列尾 `checkmark` 加 `.isSelected` ✔(是自己畫的列，不是 `Picker`,因為要送方向鍵) |
| 主機清單長按選單的圖示選擇 `src/PurrdrFeatures/HostListView.swift:146-161` | 已經移除，`:157` 註解說明改到編輯器的圖示格子 ✔ |

## 守門測試的漏洞

`SelectionControlUsageTests`(`tests/PurrdrFeaturesTests/SelectionControlUsageTests.swift:24-51`)做兩件事：每個檔案「`Picker(` 的數量 − `.pickerStyle(.inline)` 的數量」不能超過允許值;`Menu {`／`.contextMenu {` 後面 15 行內不能有 `Picker(`。它會漏掉：

1. **自己畫的單選列**:以 `Button` + `checkmark`／`circle` 圖示 + `.isSelected` 做的選擇完全看不到。這次找到的兩筆待改(`HostEditorView.swift:211-234`、`PlusView.swift:256-294`)都屬於這種。
2. **不帶點的 `contextMenu {`**:`WorkspaceActionsViews.swift:81` 是在 `View` extension 裡寫 `contextMenu {`,測試只比對 `".contextMenu {"`(`:43`),所以那個選單裡就算放 `Picker` 也抓不到。
3. **其他寫法的 `Menu`**:`Menu("標題") {`、`Menu(content:label:)`,以及 `} label:` 在前的寫法都不含 `Menu {`。
4. **選單裡用按鈕模擬選項**:在 `Menu` 裡放一排 `Button`,選中的帶 `checkmark`(不用 `Picker`),或在選單裡放 `Toggle`,都不算違規。
5. **超過 15 行，或藏在 helper 裡的 `Picker`**:例如 `Menu { appearanceOptions }`,`Picker` 寫在另一個 computed property。
6. **以檔案為單位計數**:只比數量，不比對是哪一個。`PlanUsageView.swift` 允許 1 個不是 `.inline`,所以主機那個改成 `.inline`、Agent 改回預設也會通過。另外註解裡出現 `.pickerStyle(.inline)` 也會算進去;把 `.pickerStyle(.inline)` 套在包了好幾個 `Picker` 的容器上，反而會被誤判。
7. **其他 tab 式與上下箭頭控制**:`TabView`、`.tabItem`、自己排的分段 `HStack`、label 裡的 `chevron.up.chevron.down`,以及用 `confirmationDialog` 在選項裡選一個，都沒檢查。
8. **掃描範圍**:只掃 `src/PurrdrFeatures`(`:28`)。`src/App/`、`src/PurrdrAgentFeatures/` 目前沒有選擇控制，但以後加了也不會被擋。

**建議的補強**(都還是掃原始碼、用檔案列出例外):

- 改成「每個 `Picker(` 往後找到對應的 `.pickerStyle(`」,沒有 `.inline` 的才算，例外以「檔名 + accessibilityIdentifier」列出(例如 `planUsage.host`、`agentList.mode`、`hostFilter.picker`),不用數量。
- 選單偵測用 regex `(^|[^A-Za-z])(Menu\s*[({]|\.?contextMenu\s*[({])`,範圍改成到配對的右大括號，裡面出現 `Picker(`、`Toggle(` 或 `systemImage: "checkmark"` 就算違規(`hostMenuFiles` 照舊豁免)。
- 自繪單選列：檔案裡同時有 `.accessibilityAddTraits(… .isSelected …)` 與 `"checkmark.circle.fill"` 或 `"circle"` 就列出來，例外清單列已知的(`PlusView.swift` 的方案卡片;`HostIconBadge.swift`、`SlashPanelCard.swift`、`WindowViews.swift` 用列尾 `checkmark` 或格子，不算)。這樣連線方式改完後，就不會有新的列首圓圈單選。
- 禁止清單：`TabView`、`.tabItem`、`chevron.up.chevron.down`、`.pickerStyle(.segmented|.menu|.wheel|.palette)` 除了例外檔案都不行。
- 掃描範圍加上 `src/App` 與 `src/PurrdrAgentFeatures`。
- 先做 mutation 驗證：把 `WorkspaceActionsViews.swift:81` 的選單放一個 `Picker`,確認新測試會變紅、舊測試不會。

## 來源

- HIG Pickers:https://developer.apple.com/design/human-interface-guidelines/pickers(資料:`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/pickers.json`)
- HIG Segmented controls:https://developer.apple.com/design/human-interface-guidelines/segmented-controls
- HIG Pop-up buttons:https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
- HIG Pull-down buttons:https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons
- HIG Menus:https://developer.apple.com/design/human-interface-guidelines/menus
- HIG Lists and tables:https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- HIG Tab bars:https://developer.apple.com/design/human-interface-guidelines/tab-bars
- HIG Toggles:https://developer.apple.com/design/human-interface-guidelines/toggles
- SwiftUI `InlinePickerStyle`:https://developer.apple.com/documentation/swiftui/inlinepickerstyle(「each option is displayed inline with other views in the current container」)
- SwiftUI `MenuPickerStyle`:https://developer.apple.com/documentation/swiftui/menupickerstyle
- SwiftUI `NavigationLinkPickerStyle`:https://developer.apple.com/documentation/swiftui/navigationlinkpickerstyle(「In navigation stacks, prefer the default menu style. Consider the navigation link style when you have a large number of options」)
- SwiftUI `SegmentedPickerStyle`:https://developer.apple.com/documentation/swiftui/segmentedpickerstyle
- SwiftUI `PickerStyle`:https://developer.apple.com/documentation/swiftui/pickerstyle
- SwiftUI `Picker`:https://developer.apple.com/documentation/swiftui/picker(「If you use a picker in a List in iOS, it appears in a row with the label and selected value」)

各頁的 HTML 版要 JavaScript 才有內容，抓不到;引用的原文都取自同一路徑的 `tutorials/data/….json`。
