# Purrdr 逐頁 HIG 盤點(截至 2026-11-19)

> **範圍**:`origin/master` `4f5ca66`(0.44.0)。行號都指這個 commit。
> **依據**:Apple Human Interface Guidelines 一手文件(以 developer.apple.com 的 HIG JSON 資料取原文，2026-11-19 擷取)。引用寫成「原文短句」+ 連結。找不到一手來源的標【未查得】;由程式碼推得、沒有實機驗證的標【推論】。
> **已決定、不再評估**(只盤點落實方式):品牌主色由紅改綠(色票原型 https://claude.ai/artifact/BmaennBJ3Revnu81RjeeMn 待選);錯誤紅、警告橙維持系統色;閒置不用綠;色彩對比只要合 HIG、不要太高，色彩種類要少;全 app 列表按壓回饋用灰色，iPad 選取用中性色;主機清單加 ⓘ、刪除要確認、圖示補齊 11 種 + 「無」、編輯器加圖示欄位、圖示同步、不取代 agent 頭像。
> **嚴重度**:高 = 不符 HIG 的硬性數值(對比)或使用者已決定要改、且影響主流程;中 = 與 HIG 建議不一致、或改主色後會產生新的語意衝突;低 = 一致性、細節。

## 0. 引用的 HIG 頁面與關鍵原文

| 代號 | 頁面 | 原文短句 |
|---|---|---|
| CO-1 | [Color](https://developer.apple.com/design/human-interface-guidelines/color) | “Avoid using the same color to mean different things.” |
| CO-2 | [Color › Inclusive color](https://developer.apple.com/design/human-interface-guidelines/color#Inclusive-color) | “Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information.” |
| CO-3 | [Color › System colors](https://developer.apple.com/design/human-interface-guidelines/color#System-colors) | “Avoid redefining the semantic meanings of dynamic system colors … don’t use the separator color as a text color, or secondaryLabel color as a background color.” |
| CO-4 | [Color › Liquid Glass color](https://developer.apple.com/design/human-interface-guidelines/color#Liquid-Glass-color) | “Apply color sparingly … reserve it for elements that truly benefit from emphasis, such as status indicators or primary actions.”;“Refrain from adding color to the background of multiple controls.” |
| CO-5 | 同上 | “in apps with primarily monochromatic content or backgrounds, choosing your brand color as the app accent color can be an effective way …” |
| AX-1 | [Accessibility › Color and effects](https://developer.apple.com/design/human-interface-guidelines/accessibility) | “Strive to meet color contrast minimum standards.” 表格:Up to 17 pts → 4.5:1;18 pts → 3:1;Bold → 3:1 |
| AX-2 | 同上 | “If your app doesn’t provide this minimum contrast by default, ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on.” |
| AX-3 | 同上 | “Prefer system-defined colors. These colors have their own accessible variants …” |
| AX-4 | 同上 | “Convey information with more than color alone … pairings such as red-green and blue-orange.” |
| AX-5 | 同上 | “Offer alternatives to gestures … offer onscreen ways to achieve the same outcome.” |
| DM-1 | [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | “At a minimum, make sure the contrast ratio between colors is no lower than 4.5:1. For custom foreground and background colors, strive for a contrast ratio of 7:1, especially in small text.” |
| DM-2 | 同上 | “Prefer the system background colors. Dark Mode is dynamic …(base／elevated)” |
| LT-1 | [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) | “Provide appropriate feedback when people select a list item … a table that helps people navigate through a hierarchy persistently highlights the selected row …” |
| LT-2 | 同上 › iOS, iPadOS | “Use an info button only to reveal more information about a row’s content. An info button … doesn’t support navigation through a hierarchical table or list.” |
| SV-1 | [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views) | “persistently highlight the current selection in each pane that leads to the detail view.” |
| BT-1 | [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | “Always include a press state for a custom button. Without a press state, a button can feel unresponsive …” |
| BT-2 | 同上 | “a button needs a hit region of at least 44x44 pt” |
| BT-3 | 同上 | “Keep the number of prominent buttons to one or two per view.” |
| BT-4 | 同上 | “Use style — not size — to visually distinguish the preferred choice among multiple options.” |
| BT-5 | 同上 | “Avoid applying a similar color to button labels and content layer backgrounds.” |
| BT-6 | 同上 | “a primary button uses an app’s accent color, whereas a destructive button uses the system red color.” |
| MN-1 | [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | “Consider grouping logically related items … use a separator.”;“Prefer listing important or frequently used menu items first.” |
| MN-2 | 同上 | “Show people when a menu item is unavailable. An unavailable menu item often appears dimmed …” |
| CM-1 | [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) | “warn people about context menu items that can destroy data … list them at the end of the menu and identify them as destructive” |
| CM-2 | 同上 | “it’s hidden by default, so people might not know it’s there.” |
| AL-1 | [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | “when people take an uncommon destructive action that they can’t undo, it’s important to display an alert in case they initiated the action accidentally.” |
| AS-1 | [Action sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets) | “Use an action sheet — not an alert — to offer choices related to an intentional action.”;“Make destructive choices visually prominent.” |
| FB-1 | [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) | “Warn people when they initiate a task that can cause data loss that’s unexpected and irreversible.” |
| SH-1 | [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | “If you provide a Done button, always pair it with a Cancel button … or a Back button …” |
| SH-2 | 同上 | “Support swiping to dismiss a sheet … If people have unsaved changes … use an action sheet to let them confirm their action.” |
| TB-1 | [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | “Reduce the use of toolbar backgrounds and tinted controls.” |
| TB-2 | 同上 | “Use the .prominent style for key actions such as Done or Submit … Only specify one primary action …” |
| TB-3 | 同上 | “the standard Close button closes a modal view. Prefer the standard symbols …” |
| TF-1 | [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) | “Show a hint in a text field to help communicate its purpose.”;“Display a Clear button in the trailing end of a text field …” |
| TY-1 | [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) | iOS 預設 17 pt、最小 11 pt;“Consider using the built-in text styles.” |
| LY-1 | [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | “Differentiate controls from content.”;“Be prepared for text-size changes.” |
| SB-1 | [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | “By default, sidebar icons use your app’s accent color … if you use them sparingly, fixed colors can help clarify the meaning of an icon” |
| GS-1 | [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) | “Swipe | Reveal actions and controls; dismiss views; scroll.” |
| — | Swipe actions 專頁 | 【未查得】HIG 沒有獨立的 Swipe actions 頁面(`/swipe-actions` 不存在);只有 Gestures 表格一行與 Alerts 的刪除原則 |
| — | Navigation bars 專頁 | 【未查得】`/navigation-bars` 已不存在，內容併入 Toolbars;`/navigation-and-search` 只是分類頁 |

---

## 1. 共通：色彩系統(Color、Accessibility、Dark Mode)

**現況盤點：畫面上出現的色相**(不含主機主題與終端機 ANSI)

| 色相 | 來源 | 用在哪 |
|---|---|---|
| 品牌紅字 `brandText` / `AccentColor` | `AccessibleColors.swift:56-61`、Asset `AccentColor.colorset` | 所有 `.tint`:需要你、勾選、tint 按鈕、焦點框、版面圖選取、資料夾圖示 |
| 品牌紅底 `brandFill`／`selectionFill` | `AccessibleColors.swift:64-72` | 送出鈕、使用者泡泡、主要按鈕、徽章、iPad 選取列 |
| 白字 `selectedRowText` | `AccessibleColors.swift:75-80` | iPad 選取列 |
| 連結藍 `linkText` | `AccessibleColors.swift:84-89` | 對話連結 |
| 錯誤紅字 `errorText` | `AccessibleColors.swift:37-42` | 錯誤訊息文字 |
| 系統紅 | 多處 | 錯誤圖示、紅點、關閉滑動鈕 |
| 系統橙 | `AgentListView.swift:589`、`ConversationHeaderView.swift:55,117`、`BlockedPromptView.swift:251`、`DelegationViews.swift:39`、`HostEditorView.swift:358`、`WorkspaceActionsViews.swift:203` | 工作中、點陣、注意文字、失敗、釘選 |
| 系統青 teal | `AgentListView.swift:590`、`ConversationHeaderView.swift:57`、`DelegationViews.swift:36` | 完成(未讀)、subagent 完成 |
| 系統綠 | `AgentListView.swift:591`、`ConversationHeaderView.swift:58`、`BlockedPromptView.swift:274`、`HostEditorView.swift:314`、`PaneTerminalView.swift:112` | 閒置、線上、已回答、連線成功、終端機已連線 |
| `idleSegment` 綠 | `AccessibleColors.swift:129-134` | Spaces 狀態條閒置段 |
| 系統黃 | `PaneTerminalView.swift:113` | 終端機連線中 |
| 系統靛 indigo | `WorkspaceActionsViews.swift:209` | 靜音滑動鈕 |
| 系統灰 | `AgentListView.swift:592`、`ConversationHeaderView.swift:54`、`PaneTerminalView.swift:114`、`WorkspaceActionsViews.swift:121` | 未知、離線、結束、重新命名滑動鈕 |
| 方案用量三色 | `AccessibleColors.swift:160-187` | 圓環(綠／橙／紅各 4 值) |
| Agent 頭像 6 色 | `AccessibleColors.swift:137-155` | 棕(Claude)、深灰(Codex)、藍(Gemini)、綠(opencode)、紫(Copilot)、中性 |

共 **12 種以上色相、10 組自訂 4 值調色盤 + 6 組頭像色**。

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 1.1 | 高 | 改綠主色後，「需要你」若沿用 `.tint` 會變成綠色，與「工作中」(原型的綠)、「已連線」、互動元素同色，綠色同時代表「要你處理」與「一切正常／可點」。 | CO-1 | `AgentListView.swift:482,516,588`;`SpacesListView.swift:334`;`ConversationHeaderView.swift:56`;`BlockedPromptView.swift:34`;`SpacesLayoutView.swift:169,196` | 「需要你」改系統橙(符號、狀態點、狀態條)。文字一律不上橙(系統橙淺色對白底只有 2.2:1),狀態字用 `secondaryText`,「Waiting for your input」用主要色 + semibold;語意靠 `!` 符號 + 文字(AX-4)。 |
| 1.2 | 高 | 承載文字的系統橙：注意附註整段文字是 `.orange`,淺色對卡片底約 2:1,不到 4.5:1。 | AX-1 | `BlockedPromptView.swift:244-252` | 文字改主要色或 `secondaryText`,只有 `exclamationmark.triangle` 圖示用系統橙。 |
| 1.3 | 中 | 色相過多(上表 12 種以上);同一個顏色在不同地方代表不同事:橙 = 工作中／點陣／注意／subagent 失敗／釘選;綠 = 閒置／線上／已回答／已連線;teal 與 indigo 只各出現一兩處。 | CO-1、CO-4 | 上表 | 收斂成第 15 節的 token 方案:主色 1 組、語意 2 色(紅、橙)、其餘中性。 |
| 1.4 | 中 | `AccentColor` 資產與 `brandText` 程式碼常數各寫一次同樣的四個值，換色要改兩處、測試只保護一處。 | AX-3(系統色已有 accessible 變體;自訂色要自己維護) | `Assets.xcassets/AccentColor.colorset/Contents.json`、`AccessibleColors.swift:54-61` | 換綠時以 Asset Catalog 的 `AccentColor` 為唯一來源，程式碼用 `Color.accentColor`;`AccessibleColorsTests` 改讀同一份值(或保留常數、加測試比對兩者一致)。 |
| 1.5 | 中 | Agent 種類頭像 5 種品牌色 + 中性，其中 opencode 的綠(`#237347`)會與綠主色撞色;頭像是內容層最大面積的彩色。 | CO-1、CO-4 | `AccessibleColors.swift:137-155`;`SpacesListView.swift:363-378` | 頭像改單一中性底(例如 `#5A5A5F`/高對比 `#48484A`,白字 6.9／9.1:1)+ 字母，種類靠字母與列內文字辨認;或至少把 opencode 換成不與主色同色相的值。使用者決定圖示「不取代 agent 頭像」,頭像本身保留。 |
| 1.6 | 低 | 「對比過高」盤點：預設外觀的自訂文字色多在 5–6:1(例如 `secondaryText` 淺色白底 6.0:1),**不算過高**;DM-1 對自訂色反而建議 “strive for … 7:1”。真正視覺上「太強」的是**飽和色大面積**(紅底使用者泡泡、紅底徽章)與終端機修飾鍵的白底黑字(21:1)。高對比變體(≥7:1)只在使用者開「增加對比」時出現，符合 AX-2,建議保留。 | AX-1、AX-2、DM-1 | `AccessibleColors.swift:47-52`;`ConversationView.swift:490`;`PaneTerminalView.swift:325-328` | `secondaryText` 不降:改成中性選取底後，淺色 `#636366` 在選取灰 `#E5E5EA` 仍 4.8:1,降到 `#6C6C70` 只剩 4.2:1;深色 `#AEAEB2` 在 `#3A3A3C` 5.1:1,降到 `#98989D` 只剩 4.0:1。降「太高」改從**面積**下手(1.3、6.1、11.3)。 |

### 色票候選的對比(本次計算，WCAG 2.x 公式)

| 候選(原型) | 淺色值 | 白底／`#F2F2F7`／`#EFEFF0`(問題卡片底) | 白字在其上 | 深色值 | 黑／`#1C1C1E`／`#2C2C2E` | 深色時黑字在其上 |
|---|---|---|---|---|---|---|
| A 森林綠 | `#1A7F37` | 5.1／4.6／**4.4** | 5.1 | `#3FB950` | 8.3／6.7／5.5 | 8.3 |
| B 翡翠綠 | `#0B7A5C` | 5.3／4.8／4.6 | 5.3 | `#3CCF9E` | 10.6／8.6／7.0 | 10.6 |
| C 系統綠可讀版 | `#248A3D` | **4.4**／**3.9**／**3.8** | **4.4** | `#30D158` | 10.4／8.4／6.9 | 10.4 |

- C 的淺色值當文字或白字填色都**不合 4.5:1**;要用 C 需把淺色值壓暗(例如 C 的高對比值 `#1B6E30`,6.3:1)。
- A 在問題卡片底(`#EFEFF0`)只有 4.4:1;若連結改用主色(6.2),A 的淺色值要再暗一點。
- B 三種淺色背景都 ≥ 4.6:1,是唯一不用再調的一組。
- 原型的做法:**淺色模式白字配主色、深色模式黑字配主色**,這讓「主色文字」與「主色填色」可以共用同一組 4 值(淺色兩用途對比相同;深色填色改黑字)。採用的話 `brandText`／`brandFill`／`selectionFill`／`selectedRowText` 四組可合成 `accent` + `onAccent` 兩組。

---

## 2. 主機清單(`HostListView.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 2.1 | 高 | 刪除不確認：滑動與選單的「刪除」點了直接刪(檔頭註解與 DESIGN.md 都寫「不另外確認」)。主機設定含金鑰／密碼／配對權杖，刪了不能復原;同一個 app 裡關閉 workspace、刪除會員都有確認，主機卻沒有，行為不一致。 | AL-1、FB-1、AS-1、CM-1 | `HostListView.swift:8`(註解)、`:130-134`、`:156`;`DESIGN.md:44` | 兩處都改成先開 `confirmationDialog`(標題「從這部裝置移除「主機名」?」+ destructive「移除主機」+ Cancel)。滑動鈕不用 `.destructive` role(List 會在確認前就把列移走)，改 `role: nil` + `.tint(.red)`,同 `WorkspaceActionsViews.swift:168-171` 的做法;DESIGN.md 第 44 行與檔頭註解一併改。 |
| 2.2 | 高 | 沒有畫面上的編輯入口：編輯只能靠左滑或長按，兩者都是隱藏手勢;使用者已決定加 ⓘ。 | AX-5、CM-2、LT-2 | `HostListView.swift:106-158`、`HostRowView` `:265-323` | 列尾加 `info.circle` 按鈕(44×44,`.borderless`,主色),點了 push `.edit(id)`;列本身仍是「選取並回到列表」。ⓘ 的語意是「看這一列的詳細內容」(LT-2),主機編輯器就是那台主機的詳細頁，符合;不要把 ⓘ 用在階層導覽。選取打勾移到 ⓘ 前面(或改用列首圖示旁的勾)，避免列尾擠兩個元素。VoiceOver label「主機名 詳細資訊」。滑動與長按選單保留。Demo 列沒有 ⓘ。 |
| 2.3 | 中 | 圖示只有 7 種(桌機、筆電、Mac mini、機架、PC、顯示器、雲端),沒有「無」。行為規格 F1.4 的 HerdrChat 有 10 種 + 無(桌機、筆電、Mac mini、伺服器、螢幕、開發板、遊戲機、家、雲、終端機);聯集後是 **11 種 + 無**(多出 Purrdr 的 PC)。 | 【未查得】HIG 對圖示數量無規定;SF Symbols 頁只談用法 | `PurrdrAgentFeatures/HostIdentity.swift:20-60`;`docs/research/herdrchat-behavior-spec.md:126-128` | 新增 `devBoard`(`cpu`)、`gameConsole`(`gamecontroller`)、`home`(`house`)、`terminal`(`terminal`)與 `none`。`none` 時列首保留 28pt 空位讓文字對齊;Agent 列表的主機名標示(`AgentListView.swift:462-465`、`SpacesListView.swift:350-353`)與選取中主機鈕不畫圖示、只顯示名稱。SF Symbol 名稱以 SF Symbols app 確認【推論】。 |
| 2.4 | 中 | 圖示只能從 context menu 的 Picker 選，編輯器沒有欄位。 | CM-2 | `HostListView.swift:146-154` | 見 3.1;選單裡的 Picker 可保留。 |
| 2.5 | 中 | 圖示不同步：`SyncedHost` 沒有圖示欄位，圖示只存 `UserDefaultsHostIconStore`(本機)。 | 【未查得】(產品決定，非 HIG) | `PurrdrCore/HostSync.swift:7-45`;`PurrdrAgentFeatures/HostIdentity.swift:66-100`;`App/Purrdr/PurrdrApp.swift:39` | `SyncedHost` 加 `icon`(可為 nil = 沿用對方裝置的預設)，改圖示要更新 `modifiedAt`(最後修改者勝);後台 wire 與 `backend/` schema 要同步加欄位，舊版 app 收到未知值時 `HostIcon(stored:)` 回 nil → 預設。GLOSSARY／DESIGN.md「只存在這支裝置」的描述要改。 |
| 2.6 | 低 | 「重新命名…」alert 與編輯器的 Name 欄位重複;有了 ⓘ 後編輯器是主要入口。 | MN-1(同組相關命令不要散在兩處) | `HostListView.swift:91-100`、`:141` | 可保留(快速改名)，但若要精簡選單，把「重新命名…」拿掉、改名走編輯器。 |
| 2.7 | 低 | sheet 只有「完成」。這個 sheet 不編輯內容，HIG 的 Done 是「完成任務或存檔後關閉」。 | SH-1、TB-3 | `HostListView.swift:75-82` | 改成標準 Close(`xmark`,`role: .close`)，或維持「完成」並記錄偏離理由。設定、註記清單、歡迎頁同類(見 12.2)。 |
| 2.8 | — | 已符合：列是預設樣式的 `Button`,List 會給灰色按壓回饋;選取有打勾 + `.isSelected` trait;刪除在選單最後並標 destructive(CM-1)。 | LT-1、CM-1 | `:107-121`、`:155-156` | — |

**問題數:7(高 2、中 3、低 2)**

## 3. 主機編輯器與配對(`HostEditorView.swift`;配對在同一畫面的 HTTPS 欄位)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 3.1 | 中 | 沒有圖示欄位。 | TF-1(表單欄位要能直接編輯)【推論】 | `HostEditorView.swift:24-42` | 「Host」區加 `Picker("Icon", selection:)`(選單樣式，每項 `Label(title, systemImage:)`,含「無」);新增主機時預設桌機。圖示存檔時與主機一起寫入(並進同步，見 2.5)。 |
| 3.2 | 中 | 沒有刪除入口。ⓘ 成為主要入口後，使用者預期在詳細頁底部能移除(iOS 設定的 Wi-Fi 詳細頁有「忘記此網路」)【推論】。 | AL-1、AS-1 | 整個 `Form`(`:23-112`) | 編輯模式(`model.isEditing`)最下方加一個 Section:`Button("Remove Host", role: .destructive)` → 同 2.1 的 `confirmationDialog`。新增模式不顯示。 |
| 3.3 | 低 | 配對碼欄位用 `plainTextInput()`(`autocapitalization(.never)`),但配對碼是大寫字母(`K7QM-2XPA`)。 | TF-1 | `:29-31`、`:451-457` | 配對碼改 `.textInputAutocapitalization(.characters)`、關掉自動修正。 |
| 3.4 | 低 | 錯誤呈現有兩種：連線測試失敗是「主要色文字 + 系統紅圖示」(`:346-352`),裝置金鑰問題是整段 `errorText`(`:232-234`)。 | CO-1、AX-4 | `:232-234` vs `:346-352` | 統一成前者(文字主要色、圖示系統紅)，即可刪掉 `errorText` token(見第 15 節)。 |
| 3.5 | 低 | 欄位沒有清除鈕。 | TF-1 | `field(…)` `:367-375` | 可選：位址、使用者名稱加尾端清除鈕;SwiftUI `TextField` 沒有內建，需自己加(成本與收益低，排最後)。 |
| 3.6 | — | 已符合：有未存變更時下滑關閉被擋、按 Cancel 出 action sheet 確認(SH-2);密碼用 `SecureField`;Cancel 在前緣、Save 在後緣(SH-1)。 | SH-1、SH-2、TF-1 | `:118-136`、`:192-196` | — |

**問題數:5(中 2、低 3)**

## 4. Agent 列表(`AgentListView.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 4.1 | 高 | iPad 選取列用品牌紅底 + 白字(`selectionFill`),使用者已決定改中性選取。 | SV-1、LT-1、CO-4 | `AgentListView.swift:598-624`;`AccessibleColors.swift:71-80`;`DESIGN.md:25` | 選取底改中性灰(淺 `systemGray5` `#E5E5EA`／深 `#3A3A3C` 一類的系統填色;原型用 `#E5E5EA`／`#2C2C2E`),文字維持主要色與 `secondaryText`;`backgroundProminence` 的白字分支(`:394-401`、`:482`、`:514-516`、`SpacesListView.swift:277-282,334,384-389`)整段移除;刪 `selectionFill`、`selectedRowText`;主機主題的 `fill` 不再用在選取。對比：淺色 `secondaryText` 對 `#E5E5EA` 4.8:1、深色對 `#3A3A3C` 5.1:1。 |
| 4.2 | 高 | 狀態色 5 種(tint／橙／teal／綠／灰);閒置是綠(已決定不再用)。 | CO-1、AX-4 | `AgentListView.swift:586-594` | 依原型：需要你 = 系統橙、工作中 = 主色、完成(未讀)= 中性實心圓、閒置 = 中性空心圓、未知 = 中性問號。只有符號上色，形狀已不同(`:574-583`),符合 AX-4。teal 刪除。 |
| 4.3 | 中 | 需處理數徽章是品牌紅底白字;語意是「需要你」,改綠主色後會變綠底。 | CO-1、CO-4 | `AgentListView.swift:543-559`(主機、設定 sheet 的「完成」旁) | 改中性膠囊(`.fill.tertiary` + `secondaryText` 數字)前面加系統橙 `exclamationmark.circle.fill`;不用填色就不需新的「橙底白字」token(系統橙配白字只有 2.2:1)。 |
| 4.4 | 中 | 大標題選單、`.plain` 樣式;以 Menu 呈現時系統是否給按壓態未驗證。 | BT-1 | `SpacesListView.swift:441-467` | 實機確認;若沒有按壓態，改 `.buttonStyle(.borderless)` 並把文字色明確指定為主要色。【推論】 |
| 4.5 | 低 | 滑動鈕顏色：釘選橙、靜音靛、Workspace 灰、關閉紅，4 色;橙與「需要你」撞色。 | CO-1、GS-1;Swipe actions 專頁【未查得】 | `WorkspaceActionsViews.swift:115-122,168-172,196-210` | 釘選 = 主色、靜音 = 灰、Workspace = 灰(左右兩側不同邊，不會並排)、關閉 = 系統紅。刪 indigo。 |
| 4.6 | — | 已符合：列是 `NavigationLink`,iPhone 有系統灰按壓回饋;連線中斷不跳 alert、留在列表下方(Alerts “Avoid using an alert merely to provide information”);section 標題 `secondaryText`。 | LT-1 | `:269-285`、`:298-309` | — |

**問題數:5(高 2、中 2、低 1)**

## 5. Spaces(`SpacesListView.swift`、`SpacesLayoutView.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 5.1 | 高 | 收合標頭整列是 `.plain` 按鈕，在 List 裡沒有灰色按壓回饋(使用者已決定全 app 列表要有)。 | BT-1、LT-1 | `SpacesListView.swift:180-225`(`:220`) | 拿掉 `.buttonStyle(.plain)`,讓 List 畫系統按壓灰;文字顏色已明確指定(`:192,198,209,213`),不會被 tint 染色。若要保留 plain,自訂 `ButtonStyle` 在 `isPressed` 時畫 `.fill.tertiary` 底。 |
| 5.2 | 中 | 狀態條閒置段是低飽和綠 `idleSegment`。 | CO-1(已決定閒置不用綠) | `AccessibleColors.swift:127-135`;`SpacesListView.swift:54-61` | 閒置段改中性(淺 `systemGray3` 類、深色相對應)，刪 `idleSegment`。狀態條是非文字圖形、對 VoiceOver 隱藏，旁邊有文字圖例(`:204-209`),顏色不承載唯一資訊(AX-4)。 |
| 5.3 | 中 | 狀態條 4 色(tint／橙／teal／綠)。 | CO-1、CO-4 | `SpacesListView.swift:252-271` | 同 4.2:橙(需要你)、主色(工作中)、深中性(完成)、淺中性(閒置)。 |
| 5.4 | 中 | Agent 種類頭像多色(見 1.5)。 | CO-1 | `SpacesListView.swift:363-378` | 見 1.5。 |
| 5.5 | 低 | 版面圖：active tab 用 tint 字 + 2pt tint 框、「需要你」方塊用 18% tint 底;改綠主色後「需要你」變綠。 | CO-1 | `SpacesLayoutView.swift:87,117,149,169,196` | 「需要你」方塊改橙符號 + 18% 中性底;active tab 保留主色(選取態)。 |
| 5.6 | 低 | 主機分組標題的主機圖示要支援「無」。 | — | `SpacesHostHeader`(`SpacesListView.swift` 內) | 同 2.3。 |

**問題數:6(高 1、中 3、低 2)**

## 6. 聊天：訊息(`ConversationView.swift`、`MarkdownView.swift`、`ConversationHeaderView.swift`、`DelegationViews.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 6.1 | 中 | 使用者泡泡是品牌色填滿(`hostFill`),長對話裡是畫面上最大面積的飽和色;改綠後，綠泡泡旁邊又是綠色送出鈕。 | BT-5、CO-4 | `ConversationView.swift:470-491`;`HostThemeViews.swift:36-47,82` | 依原型改中性泡泡(淺 `#E9E9EB`／深 `#2C2C2E`,即系統次要填色一類)，文字主要色;agent 與使用者靠位置區分(已有，`:470` 註解)。主機主題的 `fill` 改只用在送出鈕與主要按鈕。 |
| 6.2 | 中 | 連結另用一個藍色 token `linkText`,當初是為了避開紅色的危險語意;改綠後此理由消失。 | CO-1(互動色一致)、AX-3 | `MarkdownView.swift:95-96`;`AccessibleColors.swift:82-89` | 連結改用主色(連結本來就是互動元素),刪 `linkText`。前提：選定的淺色值在 `#EFEFF0`(agent 泡泡／卡片底)≥ 4.5:1——B 可以，A 只有 4.4 需微調(見第 1 節)。 |
| 6.3 | 中 | `DisclosureGroup` 的 label(「Thinking」、工具名稱)沒有指定顏色，非 List 情境下會被染成 tint,整串工具紀錄都是品牌色字【推論，需實機確認】。 | CO-4、CO-1(非互動資訊不要用互動色) | `ConversationView.swift:564-573`(Thinking)、`:591-606`(`call.name`) | label 文字明確指定 `Color.primary`(同 `:541-544` 已對摘要做的處理);只留展開箭頭用主色。 |
| 6.4 | 中 | 工作中點陣是系統橙;新方案橙 = 需要你。 | CO-1 | `ConversationHeaderView.swift:98-119`(`:117`) | 點陣改主色(= 工作中)或 `secondaryText`。 |
| 6.5 | 低 | 標題下狀態點 5 色(灰／橙／tint／teal／綠)，與列表不同步就會語意漂移。 | CO-1 | `ConversationHeaderView.swift:50-61` | 與 4.2 同一張對照表：需要你橙、工作中主色、其他中性;「線上」不另外上綠。 |
| 6.6 | 低 | subagent 完成 = teal、失敗 = 橙;失敗是錯誤，應用紅。 | CO-1、BT-6(紅 = 破壞／錯誤) | `DelegationViews.swift:25-45` | 完成 = 中性 `checkmark.circle.fill`(或主色)、失敗 = 系統紅三角形。 |
| 6.7 | 低 | 工具結果錯誤文字用 `errorText`。 | AX-1、CO-1 | `ConversationView.swift:579` | 錯誤結果文字改 `secondaryText`/主要色，旁邊的三角形圖示已是系統紅(`:604-605`)。配合刪除 `errorText`。 |
| 6.8 | — | 已符合：「Jump to Latest」44pt 玻璃鈕;離線用橫幅不用 alert;code block 複製鈕 44pt。 | BT-2、LY-1 | `:244-257`、`:337-357`;`MarkdownView.swift:148-163` | — |

**問題數:7(中 4、低 3)**

## 7. 聊天：問題卡片(`BlockedPromptView.swift`、`SlashPanelCard.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 7.1 | 高 | 注意附註整段系統橙文字，對比約 2:1(同 1.2)。 | AX-1 | `BlockedPromptView.swift:244-252` | 文字主要色、只圖示橙。 |
| 7.2 | 中 | 卡片與內容區背景用 `Color.secondary.opacity(0.12)`——把 secondaryLabel(文字色)當背景色用。 | CO-3、DM-2 | `BlockedPromptView.swift:79,230`;`SlashPanelCard.swift:47` | 改系統背景語意色:`.background.secondary`(secondarySystemBackground)或 `.fill.tertiary`。注意 DESIGN.md:27 把 `Color.secondary.opacity(…)` 列為可用，這條要一併改。改底色後重算主色與 `secondaryText` 的對比(目前測試用 `#EFEFF0`)。 |
| 7.3 | 中 | 提問圖示用 `.tint`,改綠後「需要你」變綠。 | CO-1 | `BlockedPromptView.swift:32-35` | 系統橙。 |
| 7.4 | 低 | 已回答勾用系統綠;主色改綠後畫面上同時有兩種綠(系統綠與品牌綠)。 | CO-1、CO-4 | `BlockedPromptView.swift:272-275` | 改主色或 `secondaryText`;全 app 只留品牌綠一種綠。 |
| 7.5 | — | 已符合：建議選項以樣式(prominent)區分、同尺寸(BT-4);每組最多一個 prominent(BT-3);「拒絕」不套 destructive 紅;非建議選項文字主要色。 | BT-3、BT-4、BT-6 | `:119-156`、`:188-203` | — |

**問題數:4(高 1、中 2、低 1)**

## 8. 聊天：輸入列(`ComposerView.swift`、`ComposerImageViews.swift`、`PromptSuggestionView.swift`、`SlashMenuView.swift`、`YouShouldKnowViews.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 8.1 | 低 | 聚焦時玻璃卡片描 1pt tint 框，加上 tint 送出鈕，同一個控制群組兩個主色元素。 | CO-4(“Apply color sparingly to the Liquid Glass material”)、TB-1 | `ComposerView.swift:133-138` | 框改 `.separator` 或拿掉(系統鍵盤與游標已表示焦點)。 |
| 8.2 | 低 | 建議提示詞、slash 選單列、收合的註記列是 `.plain`,沒有按壓態。 | BT-1 | `PromptSuggestionView.swift:17-32`;`SlashMenuView.swift:112`;`YouShouldKnowViews.swift:151-164` | 自訂 `PressableRowButtonStyle`(按下時畫 `.fill.tertiary` 底)，全 app 共用(見第 16 節第 3 項)。 |
| 8.3 | — | 已符合：送出是唯一 prominent;次要鈕中性 bordered;每顆 ≥ 44pt;placeholder 用 `secondaryText`(TF-1、AX-1)。 | BT-2、BT-3 | `:277-366` | — |

**問題數:2(低 2)**

## 9. 聊天：展開編輯(`ExpandedComposer.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 9.1 | 低 | 只有「完成」(收回、草稿保留)，沒有 Cancel;這裡「完成」的語意是收合而非存檔，HIG 的配對規則不完全適用。 | SH-1 | `ExpandedComposer.swift:59-64` | 維持;在 DESIGN.md 記一句理由即可(草稿永遠保留，沒有「放棄」的需求)。 |
| 9.2 | — | 已符合：large sheet、可下滑收回(SH-2 不涉及未存變更，草稿保留)。 | SH-2 | `:22` | — |

**問題數:1(低 1)**

## 10. 聊天：檔案卡片

**現況：不存在**。`docs/research/agent-files-in-chat.md`(未追蹤)的結論是 Purrdr 目前看不到 agent 產生的檔案;現有最接近的是附件列與泡泡內圖片(`ComposerImageViews.swift`)。

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 10.1 | 低 | 泡泡內圖片縮圖是 `.plain` 按鈕，沒有按壓態。 | BT-1 | `ComposerImageViews.swift:28-60`(`:48`) | 用共用的按壓樣式(縮圖上疊 `.black.opacity(0.15)`)。 |
| 10.2 | —(設計前置) | 新增檔案卡片時的規則 | CO-4、LY-1、CM-1、BT-1 | — | 內容層、不用玻璃;底色同問題卡片(系統背景語意色，不用主色);左側檔案類型 SF Symbol 用 `secondaryText`(不上色);整張卡片是一個按鈕(有按壓態)、長按 context menu:開啟、分享、複製路徑;錯誤(取檔失敗)用系統紅圖示 + 主要色文字。 |

**問題數:1(低 1)+ 1 條設計前置**

## 11. Pane 終端機與登入 Shell(`PaneTerminalView.swift`;登入 Shell 共用 `TerminalSessionView`,`TopNavigationView.swift:162-164`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 11.1 | 中 | 狀態點 4 色(綠／黃／灰／紅),黃色全 app 只出現在這裡。 | CO-1、CO-4 | `PaneTerminalView.swift:110-117` | 已連線 = 主色、連線中 = 中性(灰)、結束 = 中性、中斷／被占用 = 系統紅。刪黃。狀態旁已有文字(`:100-102`),符合 AX-4。 |
| 11.2 | 中 | 按鍵列鍵是 `.plain` 且文字明確寫白色;唯讀裝置停用時可能不會變暗，看起來仍可按【推論，需實機確認】。 | MN-2(unavailable 要 dimmed，對控制項同理)、BT-1 | `:309-337`(`:325`、`:331-332`)、`:346-358`、`:366-377` | 文字改 `.primary`(終端機強制深色，等於白)讓停用時的系統淡化生效;或讀 `@Environment(\.isEnabled)` 自行降到 `.secondary`。按下時加 `.fill.secondary` 底(按壓態)。 |
| 11.3 | 低 | 鎖定的修飾鍵是白底黑字(21:1),是全 app 對比最高、最搶眼的元素。 | CO-4 | `:320-328` | 改 `.fill.secondary` 底 + 白字 + 「•」(對比仍 >7:1),或主色底配黑字(深色模式 onAccent)。 |
| 11.4 | 低 | 橫幅背景 `Color(white: 0.15)` 自訂灰。 | DM-2 | `:139` | 改 `.background.secondary`(深色下即 `#1C1C1E` 一類 elevated 色)。 |
| 11.5 | — | 已符合：「接管」「重新連線」是單一 prominent;每鍵 ≥ 44pt;有 VoiceOver label 與 Locked 值。 | BT-2、BT-3 | `:150-163`、`:326-336` | 改綠後深色模式 prominent 用黑字(onAccent),見第 15 節。 |

**問題數:4(中 2、低 2)**

## 12. 設定(`SettingsView.swift` 與各 Section)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 12.1 | 低 | 「Show Welcome」「Rate」「Support」「Copy Diagnostics」「Privacy Policy」五列都是主色文字 + 主色圖示，整個 Support／About 區一片主色。 | CO-4、CO-1 | `SettingsView.swift:104-131` | iOS 慣例允許動作列用 tint;要減少主色面積就改成主要色文字 + 中性圖示，外部連結加 `arrow.up.forward` 尾標。外部連結尾標的 HIG 出處【未查得】,屬慣例建議。 |
| 12.2 | 低 | 設定 sheet 只有「完成」(設定即時生效，沒有要存的東西)。 | SH-1、TB-3 | `:138-146`;同類：`WelcomeView.swift:65-67`、`YouShouldKnowViews.swift:66-68`、`HostListView.swift:75-82` | 全 app 一致改標準 Close,或一致保留「完成」並在 DESIGN.md 記理由;不要混用。 |
| 12.3 | — | 已符合：section 標題與註腳用 `secondaryText`;Toggle 用主色(改綠後與系統預設綠開關觀感一致)。 | AX-1 | `:84-90` | — |

**問題數:2(低 2)**

## 13. 會員與訂閱(`MemberView.swift`、`PlusView.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 13.1 | 中 | 方案卡片整張是 `.plain` 按鈕，沒有按壓態(選取有勾與框，但按下時沒反應)。 | BT-1 | `PlusView.swift:262-301`(`:296`) | 用共用按壓樣式(按下時底色從 `.background.secondary` 換成 `.fill.tertiary`)。 |
| 13.2 | 低 | Google 登入鈕 `.plain`,沒有按壓態;另外 `minimumScaleFactor(0.7)` 會縮字。 | BT-1、TY-1 | `MemberView.swift:169-203`(`:194`、`:201`) | 加按壓態;縮字下限 body 17pt×0.7≈11.9pt 仍 ≥ 11pt,可保留。 |
| 13.3 | 低 | 標頭裝飾圖示用 `.tint`(會員、Plus),加上選中方案框、勾、訂閱主按鈕，一頁 4 處主色。 | CO-4 | `PlusView.swift:93-96`;`MemberView.swift:98-101` | 裝飾圖示改中性或保留其一;主色留給選取態與主要按鈕。 |
| 13.4 | — | 已符合：刪除會員有 confirmationDialog(destructive);主要按鈕一顆。 | AS-1、BT-3 | `MemberView.swift:277-286` | 主機刪除(2.1)比照這裡。 |

**問題數:3(中 1、低 2)**

## 14. TopNavigation 與 iPad 側欄(`TopNavigationView.swift`、`WindowViews.swift`)

| # | 嚴重度 | 問題 | HIG | 位置 | 建議 |
|---|---|---|---|---|---|
| 14.1 | 中 | 「⋯」選單 7 項(設定、主機、方案用量、登入 Shell、檔案、會員、Purrdr Plus)不分組;註解說包 `Section` 會讓 XCUITest 找不到 identifier。 | MN-1 | `TopNavigationView.swift:224-252` | 用 `Divider()` 分三組(不需要 Section):主機工具(主機、登入 Shell、檔案、方案用量)/ 帳號(會員、Plus)/ 設定;常用的「主機」放第一。 |
| 14.2 | 中 | 側欄主機列是 `.plain` 按鈕 + 打勾，沒有按壓態，也不是側欄的系統選取高亮。 | BT-1、SV-1、SB-1 | `WindowViews.swift:64-86` | 主機列改用側欄 `List(selection:)` 的系統選取(側欄用系統樣式，DESIGN.md:27 也要求側欄只用系統語意色);拿掉 `.plain`。 |
| 14.3 | 低 | 「會員」在「⋯」選單與設定第一列各有一個入口。 | MN-1 | `TopNavigationView.swift:242-243`;`SettingsView.swift:57-64` | 可保留(兩個情境都合理);精簡選單時優先拿掉「⋯」裡的。 |
| 14.4 | 低 | 選取中主機鈕要支援圖示「無」。 | — | `SelectedHostMenu`(`TopNavigationView.swift:221-223`) | 同 2.3。 |
| 14.5 | — | 已符合：「+」是唯一 prominent、在後緣(TB-2);「⋯」與「+」分兩個玻璃群組。 | TB-2 | `:253-259` | — |

**問題數:4(中 2、低 2)**

---

## 15. 色彩 token 精簡方案

**原則**:主色只有一組(綠);語意色只有系統紅、系統橙(使用者決定維持系統色);其餘一律中性。文字不承載橙與紅(系統橙、紅在淺色白底只有 2.2／3.5:1),橙與紅只上在符號、圓點、狀態條等非文字元素，旁邊一定有文字(AX-4)。

| 新 token | 取代 | 四值來源 | 用途 |
|---|---|---|---|
| `accent`(Asset `AccentColor`,唯一來源) | `brandText`、`brandFill`、`selectionFill` 的主色角色、`linkText`、`planUsageAmple` | 選定的綠(建議 B 或微調後的 A;C 淺色值不合 4.5:1) | tint、連結、選取態、工作中符號、prominent 按鈕底、送出鈕 |
| `onAccent` | `selectedRowText`(白) | 淺色白、深色黑(原型做法);高對比同 | prominent 按鈕與送出鈕上的字與符號 |
| `secondaryText`(保留，值不變) | `.secondary`／`.tertiary` 文字 | 現值 | 次要文字。改成中性選取底後仍需這組值才能 ≥ 4.5:1(見 1.6) |
| 系統紅 `.red`(不自訂) | `errorText`、`planUsageDepleted` | 系統 | 錯誤／破壞性圖示、紅點、關閉滑動鈕、用量耗盡圓環;錯誤**文字**用主要色或 `secondaryText` |
| 系統橙 `.orange`(不自訂) | 「需要你」的 tint 角色、`planUsageLow` | 系統 | 需要你符號／狀態點／狀態條段、注意圖示、用量偏低圓環 |
| 中性(系統灰與系統填色，不自訂) | `.gray`、`.teal`、`.indigo`、`.yellow`、`.green`(狀態)、`idleSegment`、使用者泡泡紅底 | 系統 `systemGray*`、`.fill.*`、`.background.secondary` | 閒置／完成／未知／離線／連線中、iPad 選取底、按壓底、使用者泡泡、卡片底、徽章底 |
| Agent 頭像底(1 組或保留) | 頭像 6 組 | 中性 `#5A5A5F`／高對比 `#48484A` | 頭像;若要保留品牌色，至少換掉與主色撞色的 opencode 綠 |

**結果**:自訂 4 值調色盤從 **10 組 + 頭像 6 組** 減到 **`accent`、`onAccent`、`secondaryText` 3 組(+ 頭像 1 組)**;畫面上的色相從 12 種以上減到 **綠、橙、紅 + 中性**。

**狀態對照表(列表、Spaces 狀態條、對話標題、終端機共用)**

| 狀態 | 符號 | 顏色 |
|---|---|---|
| 需要你 | `exclamationmark.circle.fill` | 系統橙 |
| 工作中 | `ellipsis.circle` | `accent` |
| 完成(未讀) | `circle.fill` | 中性(`secondaryText`) |
| 閒置／已讀 | `circle` | 中性 |
| 未知 | `questionmark.circle` | 中性 |
| 終端機已連線 | 圓點 | `accent` |
| 終端機連線中／結束 | 圓點 | 中性 |
| 終端機中斷／被占用 | 圓點 | 系統紅 |

**連帶要改的測試與文件**:`AccessibleColorsTests`(對比測試改測 `accent`／`onAccent` 對實際背景;刪掉被移除 token 的測試)、`BrandFillUsageTests`(規則改成「prominent 填色一律 `accent` + `onAccent`」)、DESIGN.md 顏色一節與第 23–27、44 行、App 圖示(DESIGN.md:8 的「品牌紅貓掌」)。方案用量圓環改用系統色後，DESIGN.md:43 的「非文字圖形 ≥ 3:1」不再成立(系統橙對白底 2.2:1);圓環中央有百分比文字，顏色不是唯一資訊，可接受，但要在 DESIGN.md 記下這個取捨。

---

## 16. 依優先順序的修改清單(可直接拆票)

> 每張票都要先寫失敗測試(TDD)。UI 顏色類的測試以 token 對比測試、ViewInspector 型別檢查或 UI 測試截圖比對為主。

| 順序 | 票名(建議) | 內容 | 對應問題 | 規模 |
|---|---|---|---|---|
| 1 | 主色換綠與 token 收斂 | 選定色票(建議 B,或把 A 淺色值壓暗到 `#EFEFF0` ≥ 4.5:1);`AccentColor` 成唯一來源;新增 `onAccent`;刪 `brandText`／`brandFill`／`selectionFill`／`selectedRowText`／`linkText`;`filledProminentButtonStyle` 改 accent + onAccent;更新對比測試與 DESIGN.md | 1.3、1.4、6.2、第 15 節 | 大 |
| 2 | 狀態色統一(需要你橙、工作中綠、其他中性) | 一張共用對照表(`AgentStatus.color`、`ConversationHeader.Status.color`、`segmentColor`、終端機 `dotColor`、`DelegationStatusIcon`、點陣);刪 teal／yellow／`idleSegment`;「需要你」文字改主要色／`secondaryText` | 1.1、4.2、5.2、5.3、5.5、6.4、6.5、6.6、7.3、11.1 | 中 |
| 3 | 全 app 列表與卡片的灰色按壓回饋 | 共用 `PressableRowButtonStyle`;Spaces 群組標頭拿掉 `.plain`;方案卡片、Google 鈕、建議提示詞、slash 選單、註記列、縮圖、側欄主機列、大標題選單套用 | 5.1、4.4、8.2、10.1、13.1、13.2、14.2 | 中 |
| 4 | iPad 中性選取 | `SelectionFillModifier` 改中性底、移除 `backgroundProminence` 白字分支與主題填色選取 | 4.1 | 中 |
| 5 | 主機刪除要確認 | 滑動與選單都走 `confirmationDialog`;滑動鈕改 role nil + 紅 tint;改 DESIGN.md:44 與檔頭註解 | 2.1 | 小 |
| 6 | 主機清單 ⓘ 資訊鈕 | 列尾 `info.circle` → 編輯;打勾位置調整;VoiceOver label | 2.2 | 小 |
| 7 | 主機圖示 11 種 + 無、編輯器圖示欄位 | `HostIcon` 新增 5 個 case(含 `none`);編輯器 Picker;各處「無」的版面;編輯器底部「移除主機」 | 2.3、2.4、3.1、3.2、5.6、14.4 | 中 |
| 8 | 主機圖示同步 | `SyncedHost.icon` + 後台 schema + 舊版相容;改文件 | 2.5 | 中(跨 app／backend) |
| 9 | 文字對比修正(系統橙文字) | 注意附註改主要色文字 + 橙圖示 | 1.2、7.1 | 小(可併入 2,但因不合 4.5:1 建議先修) |
| 10 | 錯誤呈現統一、刪 `errorText` | 錯誤文字主要色／`secondaryText` + 系統紅圖示;HostEditor、ToolStep、NewChat、ShellRun、WorkspaceActions、Delegation | 3.4、6.7 | 小 |
| 11 | 內容層背景改系統語意色 | `Color.secondary.opacity(0.12)` → `.background.secondary`／`.fill.tertiary`;重算對比;改 DESIGN.md:27 | 7.2 | 小 |
| 12 | 使用者泡泡改中性 | 泡泡改系統填色 + 主要色文字;主機主題 fill 只留給按鈕 | 6.1 | 小 |
| 13 | 工具紀錄 label 不染主色 | DisclosureGroup label 指定主要色(先實機確認) | 6.3 | 小 |
| 14 | 終端機按鍵列停用態與鎖定態 | 停用變暗、按壓態、鎖定改中性填色 | 11.2、11.3、11.4 | 小 |
| 15 | 「⋯」選單分組 | `Divider()` 分三組、主機置頂 | 14.1、14.3 | 小 |
| 16 | 滑動鈕配色 | 釘選主色、靜音灰、刪 indigo | 4.5 | 小 |
| 17 | 頭像配色 | 單一中性或去掉撞色 | 1.5、5.4 | 小(需產品決定) |
| 18 | 低優先細節 | 配對碼大寫鍵盤、sheet「完成」／Close 一致、設定與 Plus 的主色面積、輸入列焦點框、主機改名入口 | 3.3、3.5、2.6、2.7、8.1、9.1、12.1、12.2、13.3 | 小 |

## 17. 每頁問題數彙總

| 頁 | 高 | 中 | 低 | 合計 |
|---|---|---|---|---|
| 1 色彩系統(共通) | 2 | 3 | 1 | 6 |
| 2 主機清單 | 2 | 3 | 2 | 7 |
| 3 主機編輯器與配對 | 0 | 2 | 3 | 5 |
| 4 Agent 列表 | 2 | 2 | 1 | 5 |
| 5 Spaces | 1 | 3 | 2 | 6 |
| 6 聊天訊息 | 0 | 4 | 3 | 7 |
| 7 問題卡片 | 1 | 2 | 1 | 4 |
| 8 輸入列 | 0 | 0 | 2 | 2 |
| 9 展開編輯 | 0 | 0 | 1 | 1 |
| 10 檔案卡片 | 0 | 0 | 1 | 1(+ 設計前置 1) |
| 11 終端機／登入 Shell | 0 | 2 | 2 | 4 |
| 12 設定 | 0 | 0 | 2 | 2 |
| 13 會員／訂閱 | 0 | 1 | 2 | 3 |
| 14 TopNavigation／側欄 | 0 | 2 | 2 | 4 |
| **合計** | **8** | **24** | **25** | **57** |

(1.2 與 7.1 是同一處，分屬兩頁各計一次。)
