# iOS 27 設計語言與 Liquid Glass 更新(給 Purrdr 設計稿用)

> 研究日期:2026-11-22。所有出處取得日期皆為 **2026-11-22**,以下不逐條重複。
> 範圍:tab bar、toolbar、sheet、輸入列／鍵盤附件、選單與膠囊按鈕、折射材質。只採一手來源(HIG、WWDC26／WWDC25 session 逐字稿、iOS & iPadOS 27 Release Notes、SwiftUI／UIKit API 文件)。
> HIG 頁面以 developer.apple.com 的 JSON 資料端點(`/tutorials/data/design/human-interface-guidelines/<頁>.json`)取全文;API 可用版本取自 `/tutorials/data/documentation/<路徑>.json` 的 `platforms`。
> 標記:**【26】** iOS 26 就有;**【27】** iOS 27 SDK 才有(Purrdr 最低 iOS 26,要 `if #available(iOS 27, *)`);**【未證實】** 查不到一手依據;**【推論】** 由一手事實推出的建議，不是 Apple 原文。

---

## 結論摘要(5 個畫面的設計建議)

整體前提：iOS 27 沒有換設計語言，是**同一套 Liquid Glass 的調校**——玻璃更能擴散(diffuse)背後的複雜內容、邊緣加深色、反光更亮;使用者可在設定以滑桿把玻璃從「ultra clear」調到「fully tinted」;**已採用 Liquid Glass 的 app 不必重編就自動套用**,且 Xcode 27 編譯後**不能再選舊設計**(opt-out 移除)。【27】
→ 設計稿要在滑桿兩端(最透明、最不透明)與「減少透明度」「增加對比」下都檢查一次可讀性。【推論】

### 1. 底部 tab bar(聊天、檔案、主機、用量、設定)
- 浮在內容上、玻璃底、內容從底下透出;可設定往下捲時縮小(`tabBarMinimizeBehavior`)。【26】
- HIG 要求避免 tab 溢出成「More」(可見數量依裝置與方向而定，HIG 沒寫 iPhone 的確切上限;iPad 自訂 tab 時建議預設 5 個以內);5 個 tab 在 iPhone 是否一定不溢出屬【未證實】,要以 iPhone 最窄機型與 iPhone Duo 實測。HIG 也要求 tab 是**導覽不是動作**、每個 tab 都要有單字標籤、用填滿的 SF Symbols、不要停用或隱藏 tab(內容空了就在頁內說明原因)。【26】→「新增聊天」不能當 tab,放在聊天 tab 的工具列。【推論】
- 新的 **prominent tab role**:把某個 tab 釘在螢幕尾端、與其他 tab 分開，捲動收合時仍可見(SwiftUI `Tab(role: .prominent)`、UIKit `prominentTabIdentifier`)。【27】Apple 的例子是購物車;Purrdr 五個 tab 地位相當，不建議用 prominent。若要用，「設定」不適合(它不是需要特別強調的區段)。【推論】
- 選取中 tab 用 accent／tint 是 Apple 建議的少數用色點之一;內容很花時 tab bar 用單色。【26】
- 對話頁有輸入列，與 tab bar 同在底部會搶位置:HIG 沒有直接規範「推入的細節頁要不要隱藏 tab bar」,只說「隱藏 tab bar 會讓人忘了自己在哪一區(modal 例外)」。對話頁隱藏 tab bar 是常見做法，但 **HIG 無明文**。【未證實】

### 2. 頂部工具列(標題膠囊、⋯、帳號)
- 工具列按鈕自動拿到共享的玻璃底，**不要再自己加玻璃或背景**;需要彩色用 tint,且只用來表達意義(主要動作)。【26】
- 內容捲到浮動列底下時，iOS 27 頂端出現**更一致的「uniform toolbar」**(更不透明的 scroll edge effect),標準工具列自動套用;`.automatic` 不再在 soft／hard 間切換而是有自己的樣式，**之前改成 `.soft` 的要重新評估**。【27】→ 設計稿頂列底下畫成一條均勻的霧化帶，不要自畫實心色塊或漸層。【推論】
- 空間不夠時的新 API:`visibilityPriority(.high)` 讓重要項目較晚被收進溢出選單、`ToolbarOverflowMenu` 把次要動作固定收進「⋯」、`.topBarPinnedTrailing` 把項目釘在尾端(例如帳號鈕)。【27】→ 帳號鈕用 pinned trailing,「⋯」內容可直接改用 `ToolbarOverflowMenu`。【推論】
- 新 `contentMarginsRemoved(_:)`:移除工具列項目內容的預設內距、保留玻璃底(例：頭像圖貼滿玻璃按鈕邊緣);以前只能連背景一起拿掉(`sharedBackgroundVisibility(.hidden)`,【26】)。【27】→ 帳號頭像鈕適用。【推論】
- 標題寫短(HIG:15 字元內);同一列群組最多三組;文字按鈕與圖示按鈕之間要留固定間距。【26】
- 往下捲時讓導覽列讓開:SwiftUI `toolbarMinimizationBehavior(_:for:)`(取代 session 裡講的 `toolbarMinimizeBehavior`)。【27】

### 3. 聊天輸入區(輸入卡片＋鍵盤)
- HIG〈Virtual keyboards〉:鍵盤上方的自訂控制要與當下任務相關;其他畫面用 Liquid Glass 時，鍵盤上方那個容器也套 Liquid Glass;用標準 toolbar 會自動套用;**用 keyboard layout guide 與標準內距**讓系統放對位置。【26】
- **輸入卡片與鍵盤等寬、左右貼齊**:查不到 Apple 一手來源支持或示範;HIG 寫的是「標準內距」,WWDC25 只描述**系統搜尋欄**在點按後成為「鍵盤上方的全寬搜尋欄」。【未證實】→ 設計稿建議輸入卡片左右留標準邊距、圓角與裝置／鍵盤同心，而不是貼齊鍵盤兩側。【推論】
- 輸入框外框形狀新 API:`textInputBorderShape(_:)`(`.capsule`、`.roundedRectangle`、`.automatic`)與新的 `.bordered` text field style;`.roundedBorder`／`.squareBorder` 軟棄用。【27】
- 自訂浮動列用 `safeAreaBar(edge:…)`,讓捲動內容的 scroll edge effect 知道這條列。【26】
- 輸入卡片裡的模型、權限膠囊與送出鍵放在同一個 `GlassEffectContainer`(玻璃不能取樣玻璃);互動元件加 `.interactive()`;送出鍵用 `.glassProminent`(每畫面主要按鈕 1～2 個)。【26】

### 4. 加入 sheet(拍照／所有照片／檔案／貼上＋已選數量)
- 部分高度的 sheet 預設內縮、玻璃底，底邊貼合螢幕圓角;拉到全高時漸變為不透明、貼齊螢幕邊緣。**不要用 `presentationBackground` 蓋掉新材質**。【26】
- sheet 可從觸發它的按鈕「morph」出來(`matchedTransitionSource` + `.navigationTransition(.zoom…)`)。→ 從輸入卡片的「＋」放大出來。【26】
- 這是「挑選後回到上一層」的短任務，適合 medium 或自訂高度 detent,加 grabber;HIG 舉的「只用全高」例子是撰寫類 sheet。【26】→ 用自訂高度 detent 剛好放下四個來源加已選數量列。【推論】
- 按鈕位置:Cancel 在頂列前緣、Done 在後緣;有 Done 就要配 Cancel 或 Back,三者不要同時出現(2026-03-24 更新)。【26】→「加入（N）」當 Done(`.prominent`),左上取消。【推論】
- iOS 27 SDK 起，`controlSize`、`buttonSizing`、`ButtonBorderShape`、`menuIndicatorVisibility` 等環境值**在 sheet 與 popover 內重設為預設**,不再從呈現者繼承。【27】→ sheet 內的按鈕樣式要在 sheet 裡自己設。

### 5. 標題膠囊面板(用量百分比、context、權限模式)
- 膠囊放在工具列裡會自動有玻璃;放在內容層就不要用玻璃(HIG:內容層不用 Liquid Glass,滑桿／開關按住時例外)。【26】
- 點按鈕展開的選單、popover、dialog 會從按鈕 morph 出來;選單可以分段、加段標題、帶圖示，同一組要嘛全有圖示、要嘛全沒有。【26】
- iOS 27 新增選單裡 `LabeledContent` 的值會成為選單項目的副標題——可在選單項目列出「權限模式：預設」這類目前值。【27】
- iOS 27 選單多了「Ask Siri」按鈕(系統提供)。【27】選單圖示預設隱藏是 **iPadOS／macOS 的選單列與 macOS context menu**,不是 iPhone 的一般選單。【27】
- 面板內容(百分比、context 條)屬內容，用標準材質或中性底色，不疊玻璃。【26】

### 折射(refraction)新做法
- iOS 27 **沒有**給 app 自訂 UI 的折射參數:`Glass` 仍只有 `regular`／`clear`／`identity`、`tint(_:)`、`interactive(_:)`;`UIGlassEffect` 同樣只有 style、`tintColor`、`isInteractive`。【27 無新增】
- iOS 27 的「折射」新內容在**App 圖示**(Icon Composer 多層玻璃、可調 refraction;iOS 27 之前看不到)與 **macOS／iPad 延伸到邊緣的 sidebar**。【27】
- 系統玻璃本身的改變(擴散、深色邊、亮反光)自動套用，不必改程式。【27】

---

## 逐主題事實與出處

### A. Liquid Glass 材質本身
| 事實 | 出處 |
|---|---|
| 「tuned Liquid Glass so it more effectively diffuses complex content behind it」「a darkened edge along with brighter specular highlights」 | [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) |
| 設定新增滑桿,「anywhere from ultra clear to fully tinted」;已採用的 app「without even needing to recompile」 | 同上;[WWDC26 Keynote](https://developer.apple.com/videos/play/wwdc2026/101/)(Platform improvements 段) |
| 「We'll be removing support for opting to use the old design」,Xcode 27 重編即採用新設計 | [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/);[Meet with Apple: biggest updates from WWDC26](https://developer.apple.com/videos/play/meet-with-apple/277/) |
| Liquid Glass 會配合「減少透明度」「增加對比」 | [WWDC26 SOTU](https://developer.apple.com/videos/play/wwdc2026/102/);[HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)(2025-09-09 更新,提到使用者可在設定選偏好外觀) |
| 內容層不用 Liquid Glass(滑桿、開關按住時例外);clear 變體只用在豐富媒體上，亮底加約 35% 暗化層 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| 「if there's not any content scrolling underneath the glass, the glass effect really isn't providing any benefit. There's nothing for it to refract.」 | [WWDC26 SwiftUI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8120/)(7:21 段) |
| `Glass` 成員:`regular`、`clear`、`identity`、`tint(_:)`、`interactive(_:)`(iOS 26.0,無 iOS 27 新成員) | [Glass](https://developer.apple.com/documentation/swiftui/glass);[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect) |
| 玻璃靠取樣比自身更大的區域「reflects and refracts lights」;玻璃不能取樣玻璃，相鄰玻璃放同一個 `GlassEffectContainer` | [WWDC25 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) |
| App 圖示多層玻璃、refraction;iOS 27 之前 Refraction 設定沒有可見效果 | [WWDC26 Keynote](https://developer.apple.com/videos/play/wwdc2026/101/);[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) |

### B. Tab bar
| 事實 | 出處 |
|---|---|
| HIG Tab bars 2026-06-08 只「Updated terminology and art」;iOS 段落:浮在內容上、玻璃底;可縮小並把附屬元件(如 MiniPlayer)併入;尾端可放 search tab | [HIG Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) |
| 導覽不放動作、不停用／隱藏 tab、用單字標籤、填滿的 symbol、避免 More 溢出、內容很花時用單色 | 同上 |
| `Tab(role: .prominent)`:「pinning the tab to the trailing edge of the screen」;`TabRole.prominent` iOS 27.0 | [WWDC26 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)(5:12);[WWDC26 SOTU](https://developer.apple.com/videos/play/wwdc2026/102/);[TabRole.prominent](https://developer.apple.com/documentation/swiftui/tabrole/prominent) |
| UIKit:「The prominent tab is always visible, even when the tab bar collapses during scrolling. In iOS 27, you have the option to make any tab prominent」(`prominentTabIdentifier`);iPhone 可選擇以 sidebar 呈現 tab(`sidebar.preferredPlacement = .sidebar`) | [WWDC26 Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/)(9:18–10:53) |
| 視窗變寬時 tab bar 變寬、圖示改與標籤同列 | [Meet with Apple 277](https://developer.apple.com/videos/play/meet-with-apple/277/) |
| iOS 27 SDK 起 `TabView` 的 selection 必須是可見的 tab,否則可能 crash | [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)(SwiftUI) |
| `tabBarMinimizeBehavior`、`tabViewBottomAccessory` 為 iOS 26.0 | [tabBarMinimizeBehavior(_:)](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:));[tabViewBottomAccessory(content:)](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)) |
| search tab 兩種樣式(標準 tab／按鈕外觀，按下立即開鍵盤)| [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)(2026-06-08);[WWDC26 Design intuitive search experiences](https://developer.apple.com/videos/play/wwdc2026/292/) |

### C. Toolbar
| 事實 | 出處 |
|---|---|
| 「a uniform toolbar appears across the top and keeps the text legible … applied automatically for standard toolbars and can be customized using the existing scroll edge effect APIs」 | [WWDC26 SOTU](https://developer.apple.com/videos/play/wwdc2026/102/);[Keynote](https://developer.apple.com/videos/play/wwdc2026/101/) |
| 「the .automatic style no longer switches between the existing soft and hard styles but provides its own visuals … especially when set to .soft, as that no longer matches the default」 | [WWDC26 Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/) |
| HIG Scroll views(2026-06-08):優先用 automatic,它對控制項多的頂列、玻璃外的文字、釘住的表頭提供較不透明的分隔;scroll edge effect 不是裝飾，每個 view 一個 | [HIG Scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views) |
| `visibilityPriority(_:)`、`ToolbarOverflowMenu`、`.topBarPinnedTrailing`、`contentMarginsRemoved(_:)`、`toolbarMinimizationBehavior(_:for:)` 均為 iOS 27.0 | [visibilityPriority](https://developer.apple.com/documentation/swiftui/toolbarcontent/visibilitypriority(_:));[ToolbarOverflowMenu](https://developer.apple.com/documentation/swiftui/toolbaroverflowmenu);[topBarPinnedTrailing](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing);[contentMarginsRemoved](https://developer.apple.com/documentation/swiftui/toolbarcontent/contentmarginsremoved(_:));[toolbarMinimizationBehavior](https://developer.apple.com/documentation/swiftui/view/toolbarminimizationbehavior(_:for:)) |
| `toolbarMinimizationBehavior` 取代 `toolbarMinimizeBehavior`(session 用的是舊名) | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |
| 「we've added API this year so that you can remove that content margin … now you can remove just the padding and leave the background」 | [WWDC26 SwiftUI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8120/) |
| 工具列按鈕已有玻璃底，不要再加;要彩色用 tint | 同上;[WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) |
| HIG Toolbars(2025-12-16,iOS 27 未改):少用自訂背景與 tint、用 `.prominent` 標示唯一主要動作且放尾端、標題 < 15 字元、最多三組、文字鈕與圖示鈕要隔開 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |

### D. Sheet
| 事實 | 出處 |
|---|---|
| 「partial height sheets are inset by default with a Liquid Glass background … When transitioning to a full height sheet, the glass background gradually transitions, becoming opaque」;移除自訂 `presentationBackground`;sheet 可由按鈕 morph 出 | [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) |
| HIG Sheets 最後更新 2026-03-24(按鈕位置);Cancel 前緣、Done 後緣、Done 要配 Cancel 或 Back、三者不同時出現;medium detent、grabber、可滑動關閉 | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) |
| iOS 27 SDK 起 `controlSize`、`buttonSizing`、`buttonRepeatBehavior`、`menuIndicatorVisibility`、`ButtonBorderShape` 在 sheet／popover 重設為預設 | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |
| WWDC26 沒有找到 sheet 外觀的新變化 | 檢查過 [269](https://developer.apple.com/videos/play/wwdc2026/269/)、[102](https://developer.apple.com/videos/play/wwdc2026/102/)、[277](https://developer.apple.com/videos/play/meet-with-apple/277/)、[278](https://developer.apple.com/videos/play/wwdc2026/278/) |

### E. 輸入列／鍵盤附件
| 事實 | 出處 |
|---|---|
| HIG Virtual keyboards(2025-06-09,iOS 27 未改):「If other views in your app use Liquid Glass, or if your view looks out of place above the keyboard, apply Liquid Glass to the view that contains your controls … Use the keyboard layout guide and standard padding」 | [HIG Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards) |
| 系統搜尋:「a full-width search field appears above the keyboard」(WWDC25);底部工具列的搜尋欄「animates up over keyboard」(WWDC26) | [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/);[WWDC26 292](https://developer.apple.com/videos/play/wwdc2026/292/) |
| `textInputBorderShape(_:)`、`TextInputBorderShape`(`automatic`/`capsule`/`roundedRectangle`)、`BorderedTextFieldStyle` 為 iOS 27.0 | [textInputBorderShape(_:)](https://developer.apple.com/documentation/swiftui/view/textinputbordershape(_:));[TextInputBorderShape](https://developer.apple.com/documentation/swiftui/textinputbordershape);[iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |
| `safeAreaBar(edge:alignment:spacing:content:)` iOS 26.0;`ToolbarItemPlacement.keyboard` iOS 15.0 | [safeAreaBar](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:));[ToolbarItemPlacement](https://developer.apple.com/documentation/swiftui/toolbaritemplacement) |
| iOS 27 Release Notes 的 Keyboard 段只有一則修正(貼上候選字未在地化),沒有鍵盤外觀或附件的變化 | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |

### F. 選單與膠囊按鈕
| 事實 | 出處 |
|---|---|
| HIG Menus(2026-06-08)「Use menu item icons sparingly and with purpose」;同組全有或全無圖示 | [HIG Menus](https://developer.apple.com/design/human-interface-guidelines/menus) |
| 圖示預設隱藏只在 iPadOS 27／macOS 27 選單列與 macOS context menu;`labelStyle(.titleAndIcon)`、UIKit `preferredImageVisibility` 可強制顯示 | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes);[WWDC26 278](https://developer.apple.com/videos/play/wwdc2026/278/) |
| 選單內的 `LabeledContent` 值成為選單項目副標題;`Menu` label 不能含控制或手勢 | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |
| 「Menus in iOS 27 feature an Ask Siri button」 | [WWDC26 278](https://developer.apple.com/videos/play/wwdc2026/278/) |
| `.glass`／`.glassProminent` 按鈕樣式、`glassEffect` 預設膠囊形、`.interactive()`、tint 只表達意義 | [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/);[GlassProminentButtonStyle](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle) |
| 按鈕點擊範圍至少 44×44 pt;每個畫面 prominent 按鈕 1～2 個 | [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)(2025-12-16) |
| 新的 `TabsPickerStyle`(像 segmented,VoiceOver 念「tabs」) | [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |

---

## 與舊研究的差異

對照 `origin/master` 的 `docs/research/apple-hig-drover-chat.md` 與 `DESIGN.md`:

1. **折射(舊研究 §2.2,約第 167–169 行)**:舊結論「refraction 只在 iOS 27 以上看得到，圖示不能靠 refraction 才成立」**仍成立**,而且只限 App 圖示。本次確認 iOS 27 **沒有**給 app UI 的折射 API;UI 玻璃的 iOS 27 變化是系統自動的擴散／深色邊／亮反光與使用者滑桿。舊研究沒提到這兩點與「opt-out 移除」。
2. **Tab bar(`DESIGN.md` 第 61 行「不採 tab bar」;舊研究 §6.2「若 iPhone 版使用」)**:HIG Tab bars 規則在 iOS 27 只改用詞與插圖，舊研究引用的規則照舊有效。新增的是 `prominent` role(iOS 27)與 UIKit 讓 iPhone 以 sidebar 呈現 tab 的選項。改用 5 個 tab 會推翻 `DESIGN.md` 第 61 行的決策(「⋯」選單裡的方案用量、檔案、設定會變成 tab,主機清單 sheet 變成 tab),要另做決策紀錄。【推論】
3. **工具列 scroll edge effect**:`DESIGN.md` Liquid Glass 段說「玻璃後面的內容太亮或太花時，在玻璃下加淡出漸層或暗化層」。iOS 27 起標準工具列自動有 uniform toolbar,`.automatic` 樣式改變;在**標準工具列**下再自己加漸層會跟系統效果打架(WWDC25 323 已說要移除 bar 後的額外背景或暗化)。35% 暗化層的 HIG 原文只適用 **clear 變體**。建議把那句限縮到自訂浮動控制。【推論】
4. **sheet**:舊研究 §8.1 的規則不變(HIG 最後更新仍是 2026-03-24)。新增 iOS 27 SDK 在 sheet 內重設控制類環境值的行為差異。
5. **鍵盤附件**:舊研究第 49 行的結論(和任務相關、套 Liquid Glass 或標準 toolbar)不變;iOS 27 沒有新增指引。新增 iOS 27 的 `textInputBorderShape`。
6. **選單**:舊研究沒有 iOS 27 的選單圖示隱藏(只限 iPadOS／macOS 選單列)、`LabeledContent` 副標題、Ask Siri 按鈕。`DESIGN.md` 的「選單膠囊點開 sheet 用勾選列」是 Purrdr 自己的決策，與 HIG 不衝突;iOS 27 的副標題可用在「主機選擇」這類仍用選單的例外。
7. **工具列 API**:舊研究沒有 iOS 27 的 `visibilityPriority`、`ToolbarOverflowMenu`、`topBarPinnedTrailing`、`contentMarginsRemoved`、`toolbarMinimizationBehavior`(都要 `#available(iOS 27, *)`,iOS 26 上退回現行做法)。

---

## 查不到的清單(未證實)

- **輸入卡片與鍵盤等寬、左右貼齊鍵盤**的官方指引或系統元件:查不到。HIG 只說「keyboard layout guide and standard padding」;系統只有搜尋欄有「鍵盤上方全寬」的描述。
- **iOS 27 鍵盤本身的外觀變化**(圓角、玻璃程度):Release Notes 與 WWDC26 session 都沒提;Meet with Apple 208 提到的「new keyboard」是 iOS 26。
- **推入對話細節頁時是否該隱藏 tab bar**:HIG 無明文。
- **iOS 27 sheet 外觀的新變化**:WWDC26 session 與 HIG 都沒有。
- **App UI 用的折射強度或折射參數 API**:iOS 27 SDK 沒有(`Glass`、`UIGlassEffect` 無新成員)。
- **滑桿設定的程式介面**(app 能否讀到使用者選的「ultra clear ↔ tinted」值):沒找到對應 API。
- **iOS 27 tab bar 的精確尺寸、玻璃厚度**:HIG 沒寫;只有 Apple Design Resources 的 iOS 27 Figma／Sketch kit(2026-06-08、06-23、09-17,見 [HIG What's new](https://developer.apple.com/design/whats-new/)),這次沒有下載 kit 核對。
- 開發者論壇有人回報 iOS 27 beta 4 原生 tab bar 比 26.5 更不透明——論壇貼文不算一手依據，也可能已在正式版修正。
