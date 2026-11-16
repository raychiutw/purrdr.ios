# 無障礙總稽核 v1(#35,2026-11-16)

> 依 `docs/research/apple-hig-drover-chat.md` 第 20 節(20.2 全 app 共通、20.4～20.12)與 `DESIGN.md`,逐頁稽核 iPhone 與 iPad 的主要畫面。
>
> 自動稽核用 Xcode 的 accessibility audit(`XCUIApplication.performAccessibilityAudit()`),寫成 UI 測試：
> `AccessibilityAuditUITests`(iPhone 17,15 個測試、22 個畫面)與 `IPadLayoutUITests.testAccessibilityAudit*`(iPad Air 11-inch (M4))。
> 每個畫面以預設字級與 AX5(`AccessibilityXXXL`)各跑一次全部稽核類型(contrast、hit region、element detection、
> sufficient element description、Dynamic Type、text clipped、trait)。排除規則在 `tests/PurrdrUITests/AccessibilityAudit.swift`,
> 每一條都寫了理由，測試輸出逐筆印出「排除 …— 理由：…」與當下判斷用的玻璃區域。
>
> 第一次跑(修正前):15 個測試全紅，309 筆問題(`.tdd-logs/35-audit-red.log`)。
>
> 結果欄:**通過** = 沒問題;**已修** = 這張票修掉;**排除** = audit 回報，但判定為系統元件或誤報(理由見最後一節);**留下** = 已知、沒處理。

## 票面指定的三個問題

| 問題 | 原因 | 修法 | 測試(紅燈) | commit |
|---|---|---|---|---|
| Spaces 卡片下的 Codex 列中間一大片空白、狀態圖示浮在中間、「Now」掉到列底 | 不是 #41 的未讀圓點，是 `StatusLabel` 用了 `Label`。List 列裡的 `Label` 套列表樣式(圖示固定欄寬、標題對齊列文字),放進右側 `fixedSize` 的欄算不出理想寬度，標題「Working」被擠成極窄、一字一行(所以畫面上看不到字),把列撐到 188pt。另外列用 `ViewThatFits` 比「不換行的理想寬度」,副標稍長(「Claude Code · demo/weather-app」)就在預設字級也上下堆疊，各列版面不一致 | `StatusLabel` 改成 `HStack`(圖示 + 文字);列的版面改依字級決定：AX 字級才上下堆疊，其他字級文字在左、狀態與時間在右 | `AccessibilityUITests.testAgentRowsKeepStatusBesideTextAtDefaultSize`(Codex 列 187.7pt、需要你列 132pt;mutation 只把 `StatusLabel` 改回 `Label`→ 187.7pt) | 7e8ac45 |
| `!` 指令 stderr 的系統紅色對比約 3.6:1 | 系統 `.red`(#FF3B30)在白底 3.55:1、在 shell 區塊的 `.fill.tertiary` 底 3.1:1 | `AccessibleColors.errorText`:淺 #C4001A(對 #EFEFF0 5.4:1)、深 #FF7A70(對 #2C2C2E 5.5:1)、淺高對比 #A50011(7.0:1)、深高對比 #FF9F97(7.1:1),依外觀與「增加對比」取值。stderr 與其他承載文字的錯誤紅(失敗的工具結果、表單錯誤、回音失敗、subagent 錯誤)都改用它;圖示與小紅點仍用系統紅 | `AccessibleColorsTests`(淺 3.09、深 4.09、高對比都不到 7;mutation 把淺色改回 #FF3B30 轉紅) | 7011564 |
| 歡迎頁寫「A Mac or Linux host」 | #26 支援 Windows 後沒更新 | 「A Mac, Linux, or Windows host…」;繁中「macOS、Linux 或 Windows 主機…」 | `WelcomeUITests.testHostRequirementIncludesWindows`(英文、繁中) | 8134aaa |

## 逐頁稽核

### Agent 列表(Spaces、Agents、卡片)

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| Dynamic Type 到 AX5 不截斷 | 已修 | 見上 | `testAgentRowsKeepStatusBesideTextAtDefaultSize`、audit `testAgentListSpaces/Agents`(AX5) |
| 對比 4.5:1 | 已修 | section 標題的數字多疊一層 `.secondary`(約 2:1),拿掉 | audit(紅燈：「1」Contrast failed)/ 6b834b1 |
| 觸控目標 44×44 | 已修 | 卡片的版面圖按鈕 `frame(minWidth: 44, minHeight: 44)` 在 `Button` 外面，可點範圍只有圖示(19×18pt);移到 label 裡並加 `contentShape` | audit(紅燈：hit region 19×18)/ 6b834b1 |
| VoiceOver | 通過 | 列合成一個元素(標題、副標、預覽、狀態、時間;「Unread」「Pinned」「Muted」),種類圖示隱藏 | 既有 `UnreadPinnedUITests` |
| 狀態不只靠顏色 | 通過 | 文字 + 符號形狀 + 顏色 | — |
| Reduce Motion | 通過 | 沒有自訂動畫 | — |
| Reduce Transparency／Increase Contrast | 通過 | 只有系統搜尋欄與工具列玻璃;顏色都是系統語意色 | — |
| Bold Text | 通過 | 系統字型 text style | — |

### 對話(訊息、需要你、subagent、工作中)

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| VoiceOver:每則訊息一個元素 | 已修 | 使用者泡泡合成一個元素，念「Your message.」+ 內容 + 時間(有圖片時仍是容器，圖片可點開);agent 訊息合成一個元素、開頭念「Agent:」;有程式碼區塊或表格的訊息維持容器(程式碼要能橫捲、複製，表格逐格讀) | `AccessibilityUITests.testEachMessageIsOneElement`(紅燈：泡泡是 Other 容器、agent label 只有「Agent message」;mutation 把泡泡改回 `.contain` 轉紅);`ConversationUITests` 程式碼複製、連結、表格仍可操作 / c689f9b |
| VoiceOver:新訊息與狀態公告、節流 | 已修 | `ConversationAnnouncer`:新 agent 訊息「<聊天> replied: <開頭 120 字>」、變成需要你「<聊天> needs you」、工作結束「<聊天> finished」;第一次載入與串流更新不念;上次公告後 4 秒內的變化先留著，到時間只念最新一則，需要你優先。`ConversationView` 以 `AccessibilityNotification.Announcement` 送出 | `ConversationAnnouncerTests` 6 個(紅燈 8 個 issue;mutation 把節流改 0 秒轉紅)/ 7448ace、c689f9b |
| Dynamic Type 到 AX5 | 已修 | 工作中的即時預覽在 AX 字級不限 6 行 | audit `testConversationWorking`(紅燈：AX5 livePreview Text clipped)/ 6b834b1 |
| 觸控目標 44×44 | 已修 | You should know 卡片四個動作、回音失敗的「Retry」:`frame(minHeight: 44)` 在 `Button` 外面，改用 `HitTarget` label | audit `testConversationWithNoteCard`(紅燈：4 個 hit region)/ 6b834b1 |
| 標題下的狀態行 | 已修 | 純文字卻沒有 trait,audit 當成觸控目標;加 `.isStaticText` | audit(紅燈：conversation.header 14pt 高)/ 6b834b1 |
| 對比 4.5:1 | 已修 | 工具串摘要與工具輸入：DisclosureGroup 的 label 是按鈕，階層式 `.secondary` 變成淡化的 tint,改 `Color.secondary`;需要你的非建議選項：bordered 預設 tint 字配淡 tint 底(AX5 下報 failed),文字改主要色;失敗的工具結果改 `errorText` | audit `testConversationNeedsYou`、`testSlashMenuAndPanels` / 85fdd5d |
| Reduce Motion | 已修 | 自動捲到底(需要你、面板、送出、跳到最新)在 Reduce Motion 時不做動畫;工作中的 3×3 點陣原本就不動 | 程式碼檢查(見「留下」)/ c689f9b |
| Reduce Transparency／Increase Contrast | 通過 | 輸入列與「跳到最新」是系統玻璃;內容層沒有玻璃 | — |
| rotor | 留下 | 見最後 | — |

### 輸入列、slash 選單、面板卡片

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| 對比 4.5:1 | 已修 | 參數提示 `.tertiary`(約 2:1)改 `.secondary`;選單底從半透明 `.bar` 改不透明(半透明底讓次要色對比不足);來源標題改主要色 | audit `testSlashMenuAndPanels`(紅燈：`<path>`、`[instructions]` Contrast failed;mutation 把參數提示改回 `.tertiary` 轉紅)/ 6b834b1、85fdd5d |
| section 標題一般大小寫 | 已修 | 拿掉 `.textCase(.uppercase)`(「BUILT-IN」→「Built-in」) | 6b834b1 |
| AX5 不截斷 | 已修 | slash 選單開著時先收起 You should know 卡片(鍵盤 + 選單 + 卡片同時在時，AX5 下卡片被擠到截字) | audit(AX5 Text clipped)/ 85fdd5d |
| 觸控目標、VoiceOver label | 通過 | 列 ≥ 44pt,label 是指令名、value 是參數與說明;面板 ‹ › 有 label | 既有 `SlashMenuUITests` |

### `!` 指令

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| stderr 對比 | 已修 | 見上 | `AccessibleColorsTests` / 7011564 |
| 其他 | 通過 | 「Show All」≥ 44pt;長按可複製 | audit `testShellCommand` |

### 終端機

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| 按鍵 44×44、VoiceOver label、Ctrl 鎖定不只靠顏色 | 通過 | — | 既有 `PaneTerminalUITests`、audit `testTerminal` |
| Bold Text | 已修 | 終端機字型是固定大小的等寬系統字(使用者用 `Aa` 調),不會自動變粗;「粗體文字」開啟時改 semibold(`legibilityWeight`) | 程式碼檢查(見「留下」)/ 6b834b1 |
| 字級手勢替代 | 通過 | `Aa` 選單 | — |

### 主機清單、新增主機、分享

| 檢查項目 | 結果 | 修正方式 | 測試／commit |
|---|---|---|---|
| 對比 4.5:1 | 已修 | 主機列是 `Button`,階層式 `.primary`／`.secondary` 跟著按鈕變成 tint,副標成了淡粉紅(「demo@studio-mac:22」);改 `Color.primary`／`Color.secondary` | audit `testHostsEditorAndShare`(紅燈：兩列副標 Contrast failed;mutation 把副標改回 `.secondary` 轉紅)/ 6b834b1 |
| AX5 | 通過 | 欄位標籤換行;placeholder 是系統單行(排除) | audit |

### 設定、付費牆、登入、歡迎頁、You should know 清單、新增對話、版面圖

| 畫面 | 結果 | 修正方式 | 測試 |
|---|---|---|---|
| 設定 | 通過 | — | audit `testSettings` |
| 付費牆 | 通過 | — | audit `testPaywall`、既有 `PlusUITests`(AX XXXL) |
| 登入 | 通過 | — | audit `testSignIn`、既有 `SignInUITests` |
| 歡迎頁 | 已修(文字)、通過 | #34 沒有 AX5 測試，這次補 AX5 audit | audit `testWelcome` |
| You should know 清單 | 已修 | 「Go to Chat」觸控目標不到 44pt(frame 在 label 外) | audit `testNotesListAndLayout`(紅燈：hit region) |
| 新增對話 | 通過 | — | audit `testNewChat` |
| 版面圖 | 排除 | 方塊依 Pane 比例固定大小，放大會裁字;完整名稱在 VoiceOver label 與 Spaces 卡片下的列 | audit `testNotesListAndLayout` |

### iPad(三欄、版面圖浮動卡片)

| 檢查項目 | 結果 | 測試 |
|---|---|---|
| 選取中的列對比 | 已修 | Agent 列與終端機列選取時，系統以 tint(紅)填滿列底，次要色變淡白、「Needs You」紅字疊在紅底上看不見。依 `backgroundProminence == .increased` 改用白色(符號形狀仍區分狀態) | `testAccessibilityAuditThreeColumns`(紅燈 `.tdd-logs/35-ipad-4.log`:「4:40 PM」「Claude Code · demo/weather-app」Contrast failed)/ d693880 |
| 觸控目標 44×44 | 已修 | 側欄 workspace 的版面圖按鈕沒有 44pt frame | 同上(紅燈 `.tdd-logs/35-ipad.log`:3 個 hit region)/ d693880 |
| 三欄(側欄、列表、對話欄)預設字級 | 通過 | 對話開在對話欄 | `testAccessibilityAuditThreeColumns` |
| 三欄 AX5 | 通過(只有側欄與列表) | AX5 加上輪詢中的對話時 audit 逾時(「Audit failed to complete in time」,`.tdd-logs/35-ipad-2.log`),AX5 段落不開對話;對話畫面的 AX5 由 iPhone 涵蓋 | 同上 |
| 釘住的版面圖浮動卡片(玻璃)預設字級 | 通過 | — | `testAccessibilityAuditLayoutCard` |
| 版面圖浮動卡片 AX5 | 未稽核 | AX5 時側欄上沒有版面圖按鈕(測試找不到 `sidebar.layout.w3`),這段略過;版面圖改由 Spaces 卡片開 sheet,iPhone audit 有涵蓋 | 同上 |
| 側欄文字對比 | 排除 | 同一份程式碼五輪裡三輪通過、兩輪報側欄文字 Contrast failed(`.tdd-logs/35-ipad-4.log`、`35-ipad-final.log`);截圖確認是系統語意色文字配淺色玻璃，判定為透過系統 Liquid Glass 側欄取樣不穩定 | — |

## Accessibility audit 排除規則與理由

| 類型 | 範圍 | 理由 |
|---|---|---|
| contrast、Dynamic Type | 導覽列／工具列的系統按鈕(Done、Cancel、Save、Start…) | 系統繪製的 Liquid Glass 按鈕;AX 字級時系統固定工具列字級、提供 Large Content Viewer |
| text clipped、Dynamic Type | 導覽列標題 | 導覽列高度固定，長標題(聊天名稱)由系統截斷;完整標題在 VoiceOver label 與列表 |
| contrast、text clipped、hit region | 元素中線落在狀態列、導覽列與其下 24pt 的 scroll edge effect、搜尋欄(含玻璃膠囊上方 24pt)、輸入列或終端機按鍵列底下;有一部分在 slash 選單範圍外;超出視窗 | audit 取樣到的是被玻璃模糊或被裁掉的那一塊;捲到可見處時另外受檢。一開始用「有交集就排除」,mutation 發現它把主機列、slash 參數提示的真問題也蓋掉，改成看中線 |
| Dynamic Type、text clipped | 只在預設字級段落，靜態文字與 List／Form 按鈕 | audit 以模擬放大「預測」,對 List／Form 裡用 text style 的 SwiftUI Text 誤報;同一測試緊接著以 AX5 實際啟動同一畫面，以 AX5 段落為準 |
| Dynamic Type | AX5 段落裡一行高度 ≥ 50pt 的靜態文字 | 已實際放大(預設字級一行約 20pt);audit 對 Button 內合併的 SwiftUI Text 誤報「部分不支援」 |
| contrast | 對應不到元素、detailedDescription 是「SwiftUI.AccessibilityNode」 | 已對 VoiceOver 隱藏的裝飾(卡片軌道線、狀態點、種類圖示)。【推論】audit 不給元素也不給位置，無法逐一指認;只在有這類裝飾的畫面出現 |
| contrast | 停用中的控制項 | 系統停用樣式刻意淡化;WCAG 1.4.3 列為例外 |
| text clipped | 文字欄位 | placeholder 由系統單行繪製;輸入的文字可橫捲 |
| text clipped | 「Choose Folder on Host」「1 note for you」「Go to Chat」 | 預設字級與 AX5 截圖確認完整顯示(Label 圖示 + 文字);audit 以單行寬度判定的誤報 |
| contrast | iPad 側欄的靜態文字 | 系統 Liquid Glass 側欄，透過玻璃取樣，五輪裡兩輪失敗;文字是系統語意色 |
| contrast | 需要你卡片、subagent／workflow 卡片裡的主要色文字 | 截圖確認黑字配淺灰填色(約 15:1 以上);卡片底是半透明填色、旁邊有轉動的進度圖示，同一份程式碼前三輪通過、之後一輪失敗 |
| Dynamic Type、text clipped | 對應不到元素、說明不是 SwiftUI 節點 | UIKit 繪製的系統元件(iPad split view 的側欄切換、視窗控制);app 的文字都是 SwiftUI |
| Dynamic Type、text clipped、contrast | 版面圖的靜態文字 | 依 Pane 比例的示意圖;完整名稱在 VoiceOver label 與 Spaces 卡片下的列;medium 高度的 sheet 是系統玻璃底 |
| sufficient element description | 純數字的 label(表格的「12.50」) | 數值本身就是內容 |

## 留下的項目

- **次要色對比**(#67 已處理):系統 secondaryLabel(rgba(60,60,67,0.6))在白底約 3.4:1,低於 4.5:1。#35 時 audit 報成「nearly passed」並排除;#67 新增 `secondaryText`(四值見 DESIGN.md 顏色表),承載資訊的 `.secondary`／`.tertiary` 文字全部改用，並刪掉這條排除。
- **rotor**:沒有自訂 rotor(訊息、程式碼、需要回答的提問之間跳轉)。HIG 寫「when possible」,票面未列。
- **沒有自動測試的修正**:Reduce Motion(自動捲動不做動畫)、Bold Text(終端機 semibold)。XCUITest 沒有切換這兩個設定的方法(`simctl ui` 只支援外觀、增加對比、字級)。
- **深色模式與增加對比**:這次的 audit 都在淺色、一般對比下跑;深色與高對比只檢查了 `errorText`、`secondaryText` 的四個值(`AccessibleColorsTests`),其他是系統語意色。
- **版面圖**:方塊在 AX 字級會裁字(比例示意圖)。
- **隱藏裝飾的對比**:audit 對應不到元素的那幾筆無法逐一指認(見排除規則)。
