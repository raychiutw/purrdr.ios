# DESIGN.md

Purrdr 的 UI 與 UX 規範。依據是 Apple HIG(研究與逐畫面檢核清單見 `docs/research/apple-hig-drover-chat.md`)。詞彙見 `GLOSSARY.md`。設計原型(三個方向與選定組合)保存在 `prototype/design-directions` 分支。

## 選定方向

- **App 圖示：貓掌泡泡(T3,ADR-0009)**。四顆圓形腳趾(中間兩顆大、外側兩顆小)加上一個帶尾巴的圓角對話泡泡當肉墊，泡泡裡是白色「…」:貓正在打字。淺色底、品牌紅貓掌。兩個圖層(貓掌、「…」),以 Icon Composer 製作，六種外觀(default、dark、clear light／dark、tinted light／dark)都要辨識得出;tinted 外觀貓掌為白色、「…」為深灰。不用紅色滿版底，因為「紅漸層底 + 白色圖形」跟 Apple Music 圖示太像。原型見 https://claude.ai/artifact/2P1YePb33dgAnAGgsWsoCT。
- **畫面：方向 A「系統清單風」**。Agent 列表是 iOS 標準 grouped list,依「需要你／工作中／閒置」分 section;對話用標準泡泡;終端機全螢幕，按鍵列是單一玻璃容器。

## 顏色(ADR-0008)

| 用途 | 色碼 | 說明 |
|---|---|---|
| 品牌紅 | `#FA2D48` | 接近 Apple Music 紅。只用在圖示與不承載文字的裝飾;配白字只有 3.8:1 |
| 紅字 `brandText`(#70;`AccentColor` 同值，即系統 tint) | light `#D80521`／dark `#FC5D72`／light 高對比 `#A20419`／dark 高對比 `#FCA1AD` | 連結、tint、狀態文字、「需要你」。淺色對白底 5.3:1、`#F2F2F7` 4.7:1、`#EFEFF0` 4.6:1;深色對黑底 6.9:1、`#1C1C1E` 5.6:1、`#2C2C2E` 4.6:1;高對比兩值對同一組背景都 ≥ 7.1:1 |
| 紅底 `brandFill`(#70) | light 與 dark `#EA0826`／兩種高對比 `#B3041B` | 承載白字的填色：送出鍵、使用者泡泡、主要按鈕、「+」、膠囊標籤、iPad 列表的選取列(#95)。白字 4.6:1、高對比 7.1:1;深色模式不跟著紅字變亮 |
| 次要文字 `secondaryText`(#67) | light `#636366`／dark `#AEAEB2`／light 高對比 `#48484A`／dark 高對比 `#D1D1D6` | 取代承載資訊的系統 `.secondary`／`.tertiary` 文字(系統 secondaryLabel 白底只有 3.4:1)。淺色對白底 6.0:1、grouped `#F2F2F7` 5.4:1、淡填色卡片 `#EFEFF0` 5.2:1;深色對黑底 9.5:1、`#1C1C1E` 7.7:1、grouped 列 `#2C2C2E` 6.3:1;高對比兩值對同一組背景都 ≥ 7.9:1 |
| 錯誤文字 `errorText`(#35) | light `#C4001A`／dark `#FF7A70`／light 高對比 `#A50011`／dark 高對比 `#FF9F97` | 取代承載文字的系統 `.red`(白底 3.6:1);圖示與小紅點仍用系統紅 |

- 每個自訂顏色都要有 light／dark／各自 high contrast 四個值，放在 Asset Catalog 或程式碼的 `ContrastPalette`(`AccessibleColors`)都可以;四個值都要有對比測試(對它實際出現的背景計算，一般 ≥ 4.5:1、高對比 ≥ 7:1,見 `AccessibleColorsTests`)。
- 紅色只用在主要動作與「需要你」狀態;每個畫面 prominent 按鈕最多 2 個。
- 紅底白字一律用紅底角色：填色寫 `.brandFill` 或 `hostFill(in:)`,prominent 按鈕用 `filledProminentButtonStyle()`／`filledGlassProminentButtonStyle()`;不要用 tint／`Color.accentColor` 當白字的底(`BrandFillUsageTests` 擋)。
- iPad 列表(split view 內容欄)的選取列不用系統選取底色(它是 tint,也就是紅字角色，深色白字只有 3.0:1、深色高對比 1.9:1):列加 `selectionFill(for:)`,底色是紅底角色(有主機主題時用主題的白字填色)，列內文字、次要文字與「需要你」的符號、狀態字、「Waiting for your input」一律改成白字 `selectedRowText`(對紅底 4.6:1、高對比 7.1:1);「需要你」在選取列靠 `!` 符號與文字辨認(`AccessibleColorsTests` 的選取列對比測試)。
- 紅色在 iOS 常代表危險，所以「需要你」一律同時有 `!` 符號與文字，不只靠顏色;真正的錯誤與刪除用系統 `.red`／destructive role,不用品牌紅。
- 次要文字的判斷原則(#67):**承載資訊的文字一律用 `secondaryText`**——副標、時間、說明、狀態字、預覽、參數提示、placeholder、空狀態與錯誤說明，List／Form 的 section 標題與註腳(系統預設是 secondaryLabel,要明確指定;iPad 側欄的系統樣式 section 標題除外，保留系統色：它畫在系統的 Liquid Glass 側欄上，系統依底下透出的內容、深淺色與「增加對比」調整文字的 vibrancy,換成固定的 `secondaryText` 反而失去這層調整;側欄只用系統語意色文字，audit 透過玻璃取樣不穩定的情況記在 `AccessibilityAudit` 的排除規則),以及「圖示 + 文字」的 Label 整體、只有圖示的按鈕(關閉、複製)與單獨表達狀態的圖示(縮放、未知)。**純裝飾可留系統階層色**:旁邊已有文字說明或對 VoiceOver 隱藏的圖示(卡片種類圖示、主機圖示、工具種類圖示、檔案圖示、圖片佔位圖示、展開箭頭 chevron)、軌道線、分隔線、邊框與底色(`.fill.*`、`.background.secondary`、`Color.secondary.opacity(…)`)。在按鈕(List 列、`DisclosureGroup` label)裡也不會被 tint 染色，因為 `secondaryText` 是固定色。
- 其他使用系統外觀，不提供 app 內的深淺色設定。
- **主機主題**(#23,設定「Use Host Theme」,經同意):選取中主機 herdr `config.toml` 的 `[theme]` 套到側欄、列表、對話與終端機(所有主機的聊天都用選取中主機的主題;換選取中主機立刻換，新視窗也一樣)——accent 當 tint(對 `#F2F2F7`／`#1C1C1E` ≥ 4.5:1 才用)、白字填色(使用者泡泡、送出鍵與主要按鈕，白字 ≥ 4.5:1 才用，否則紅底角色)、終端機背景／文字／ANSI(對背景 ≥ 4.5:1,不足的退回系統)。設定等 sheet 永遠用 App 配色(關掉主題的地方不能被主題弄得不可讀)。

## Liquid Glass

- 只出現在導覽層與控制層：工具列(含選取中主機鈕)、輸入列、終端機按鍵列。
- 內容層(泡泡、code block、subagent 卡片、核准選項、列表列)不用玻璃，也不疊玻璃。
- 自訂玻璃只用 regular 變體，包在 `GlassEffectContainer`。

## 畫面重點

- **iPhone 頂層導覽**:不採 tab bar。Agent 列表工具列右側兩個群組:「⋯」選單(設定、主機)與主要動作「+」(新增對話);三者都以 sheet 開啟，「完成」回到同一個列表。設定的深層連結是 `purrdr://settings`(冷啟動與背景都適用)。
- **iPad 與寬視窗**:三欄 `NavigationSplitView`——側欄(主機、選取中主機的 workspace;workspace 列尾有版面圖按鈕)→ Agent 列表 → 對話。依 size class 排版：窄視窗收合成一疊、從 Agent 列表開始(同 iPhone)。列表的列是選取並持續高亮，沒選時對話欄顯示「選一個對話」。版面圖在側欄按鈕上：指標停留 300ms 出現浮動玻璃卡(寬 340、最高 520pt,在列表欄內靠前緣)、離開 200ms 消失;點按鈕釘住，「關閉」、點背景或 Esc 才關。中欄是所有主機合併的 Agent 列表(同 iPhone,工具列一樣有選取中主機鈕);側欄點主機等於切換選取中主機，只換側欄的 workspace、清掉 workspace 篩選與版面圖卡片，對話欄的聊天留著。列的 context menu 最前面有「在新視窗開啟」「在新視窗開啟終端機」,任何一台主機的 Agent 都可以;每個視窗各自的導覽狀態，UI 一律稱「視窗」。快捷鍵:Command-N 新增對話、Option-Command-N 新視窗、Command-, App 設定(選單列的 Settings… 保留給系統)、Command-F 搜尋、Option-Command-↓／↑ 下／上一個 Agent、Shift-Command-T 開終端機。
- **Purrdr Plus 付費牆**(「⋯」選單與會員頁進入，sheet 一律可以關閉):每個方案一張可選的卡片——名稱、每期總扣款金額(最醒目)、試用(「2 weeks free, then …」);主要按鈕一顆(沒登入時是「Sign In to Subscribe」,權限記在會員身上);下方是選中方案的自動續訂說明(試用結束自動扣款、24 小時前取消、到設定管理)、「Restore Purchases」「Redeem Code」(系統 Offer Code 流程)、使用條款與隱私權政策連結。購買確認用系統 sheet;已訂閱時不推銷，改顯示續訂日期與「Manage Subscription」(系統 UI);不能付款時隱藏購買並說明;到期或退款後顯示續訂提示(推播與主機同步暫停，聊天與終端機照常)。
- **Agent 列表**:所有主機的 Agent 合併在同一個列表，選取中主機的列在前;非選取中主機的列在副標開頭以主機圖示 + 主機名標示。列左側的圖示表示 agent 種類(圖示對 VoiceOver 隱藏，種類名稱在副標)。某台主機連不上時保留它最後的列，列表下方「連線中斷」區段每台一行「主機名：原因」與「再試一次」;只有沒有任何列時，選取中主機的錯誤才佔滿畫面。工具列左側是**選取中主機鈕**(主機圖示 + 名稱，選單內切換;只決定新聊天開在哪裡、套用誰的主題、Claude 用量與推播設定讀哪台，不隱藏其他主機);右側搜尋、新增對話;狀態同時用文字 + 符號 + 顏色;底部選取中主機的 Claude 用量(5h／Week 剩餘比例與重置時間)。
- **主機清單**(sheet):每列左側是主機圖示(使用者在 context menu 的「圖示」選:桌機、筆電、Mac mini、機架、PC、顯示器、雲端;只存在這支裝置)。點一台即選取並回到列表。滑動：左側「編輯」;右側「刪除」(destructive,不允許整列滑到底，點了直接刪、不另外確認——只刪這支裝置上的設定，主機本身不受影響)與「分享」。context menu:編輯、重新命名…、分享…、分隔線、刪除(最後)。分享在同一個 sheet 內 push:白底 QR code(深色模式也是白底)、說明「密碼與私鑰永不分享」、系統分享鈕。掃 QR code 或點分享連結 → 主機 sheet 開出帶好欄位的新增主機表單。
- **連線中斷**:不用 alert,也不用會自動消失的提示。Agent 列表保留最後的列，在列表下方顯示「連線中斷」區段(原因 + 「再試一次」),重新連上才消失;對話在頂端橫幅顯示離線與「再試一次」。網路切換或回前景後自動恢復，不需使用者操作。
- **對話**:使用者泡泡用填色紅底白字，agent 泡泡用系統次要背景;thinking 與 tool 呼叫預設摺疊成一行;呼叫 skill 顯示「已載入 skill:<名稱>」,不貼全文;subagent 用卡片顯示各自狀態;agent 卡住時，選項以卡片放在該則提問下方(內容層),建議選項用 prominent 樣式而非大小區分。標題下一行是狀態點與狀態字，再以「·」串接主機名(非選取中主機)、workspace、agent、模型、effort、資料夾,放不下時從後面整段拿掉、不截斷，VoiceOver 念完整內容。標題列右側：不在工作中「重新載入」,工作中「停止」(點一下送 Esc;長按選單「強制結束」送 Ctrl-C;「需要你」的 agent 永不中斷)。工作中時對話最底下是內容層的指示：即時預覽(次要色)、3×3 點陣(Reduce Motion 時不動)、「Working…／Writing…」與經過時間。
- **列表大標題**(#66):Agent 列表(iPhone 與窄視窗、iPad 的列表欄)最上面是大標題「目前檢視名 ⌄」(Large Title 粗體、靠前緣、⌄ 次要色),點了出檢視選單(目前那個打勾);VoiceOver 唸「Spaces,按鈕」並有標題特徵，AX 字級換行不截斷。往上捲過一半，大標題收合成導覽列的小標題，小標題一樣點了出同一個選單(系統 title menu);載入中、錯誤、空狀態只有小標題。實作：系統的 title menu 只掛在 inline 標題上(`.large`／`.inlineLarge` 最上面的大標題是靜態文字，點了沒選單);iOS 26 的 `ToolbarItem(placement: .largeTitle)` 畫得出自訂內容，但不在 accessibility tree、也不接觸控。所以大標題畫在列表第一列(一般的 `Menu`),它在畫面上時以 `toolbar(removing: .title)` 收起導覽列小標題，捲上去才把小標題(`navigationTitle` + `toolbarTitleMenu`)放回來;`navigationTitle` 一直設著(App 切換器與視窗標題用)。
- **Spaces／Agents 檢視**(#40):Agent 列表的大標題(或收合後的小標題)選單切換兩種檢視，存在本機，重新啟動後還是同一個。Spaces 檢視以 workspace 為單位：只有一個 Agent 且沒有其他 Pane 的是一般聊天列，其餘是 workspace 卡片(標題、統計行「N agents, M working · N tabs · N panes · 資料夾」、工作中或需要你時的狀態;底下依 Tab 分組列出 Agent 列與終端機列，內縮並有左側軌道)。點卡片標題或列尾的版面圖鈕開該 workspace 的版面圖;終端機列開 Pane 終端機(標題是程式名)。Agents 檢視每個 Agent 一列。
- **已釘選與未讀**(#41):列的滑動或 context menu「釘選」把聊天放進最前面的「已釘選」組(不論狀態，依釘選先後);標題後的圖釘、靜音小圖示用次要色。未讀的完成以實心圓標示，VoiceOver 念「Unread」;已讀的完成顯示成閒置。section 標題帶數量。需處理數量(有「需要你」或未讀的 workspace 數)顯示在主機與設定 sheet 的「完成」旁，0 不顯示、超過 99 顯示「99+」,不設 app 圖示徽章。列表最底部的滑動提示在第一次用了滑動動作後不再出現。
- **視窗**(#31):iPad 可開多個視窗，每個視窗各自的側欄、列表選取與聊天;UI 一律稱「視窗」,不稱 Scene 或分頁。
- **You should know**(#23):列表最上方一列「✦ N notes for you」(所有主機合計，只算列表裡有的 Claude 聊天),點了開註記清單(sheet,選取中主機的在前),每則可「Go to Chat」。輸入列上方以內容層卡片顯示這個聊天 session 的那則(不透明 `.background` 底 + `.separator` 邊，同 slash 選單;tint 文字按鈕在 `#F2F2F7` 底不到 4.5:1),動作 Learn More(有說明時)、I Knew That／Got It、Discuss in Chat(放進輸入框，不蓋掉已打的字)、Dismiss;第一次動作前以 alert 徵求同意(會改主機上的 store;同意與寫回都是聊天所在的那台),設定可撤掉(選取中主機的)。
- **輸入列**:附加、多行輸入、送出(唯一 tinted 主要動作);輸入 `/` 時彈出依來源分組的 slash 選單，可鍵盤上下選擇;打了名稱後改成沒有標題的單一排名清單。每列參數提示淡色等寬;點選或 Return 選定任何指令都只填入 `/名稱 `(不送出、鍵盤不收起，#83),有參數提示的淡淡顯示在游標後。`/model`、`/effort` 開出的面板在聊天內以原生卡片呈現(內容層，同「需要你」卡片背景):目前使用中打勾、游標列填色高亮、effort 以分段控制與 ‹ › 調整、面板自己的動作鈕(確認 prominent、取消最後且中性)。
- **終端機**:全螢幕深色;標題下是狀態點加文字(連線中…／已連線／連線中斷／已結束等),連線中斷時橫幅提供「重新連線」,Pane 被別人操作或接管時提供「接管」。按鍵列是單一玻璃容器：可橫捲的 Esc、Tab、Ctrl、Alt(鎖定時同時有底色與「•」標示)、← ↓ ↑ →、`/`、`-`、`|`、`~`、Home、End,Esc～Alt 排最前面、最窄寬度也不用捲;列尾固定兩顆獨立鈕「貼上」與「收起鍵盤」。每鍵 ≥ 44×44 pt 並有 VoiceOver label。字級可用捏合與 `Aa` 選單調整(8–28 pt)。單指垂直滑動捲動(交給 herdr 決定捲歷史或送滾輪)。

## 通用規則

- 文字一律用 text style,支援到 AX5 不截斷;觸控目標 ≥ 44×44 pt。
- app 快捷鍵只用 Command;終端機聚焦時 Control 組合鍵與 Esc 送往遠端。
- 完整的逐畫面檢核清單在 `docs/research/apple-hig-drover-chat.md` 第 20 節，實作每個畫面時逐項檢查。
