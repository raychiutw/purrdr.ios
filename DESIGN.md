# DESIGN.md

Purrdr 的 UI 與 UX 規範。依據是 Apple HIG(研究與逐畫面檢核清單見 `docs/research/apple-hig-drover-chat.md`)。詞彙見 `GLOSSARY.md`。設計原型(三個方向與選定組合)保存在 `prototype/design-directions` 分支。

## 選定方向

- **App 圖示：貓掌泡泡(T3,ADR-0009)**。四顆圓形腳趾(中間兩顆大、外側兩顆小)加上一個帶尾巴的圓角對話泡泡當肉墊，泡泡裡是白色「…」:貓正在打字。淺色底、品牌紅貓掌。兩個圖層(貓掌、「…」),以 Icon Composer 製作，六種外觀(default、dark、clear light／dark、tinted light／dark)都要辨識得出;tinted 外觀貓掌為白色、「…」為深灰。不用紅色滿版底，因為「紅漸層底 + 白色圖形」跟 Apple Music 圖示太像。原型見 https://claude.ai/artifact/2P1YePb33dgAnAGgsWsoCT。
- **畫面：方向 A「系統清單風」**。Agent 列表是 iOS 標準 grouped list,依「需要你／工作中／閒置」分 section;對話用標準泡泡;終端機全螢幕，按鍵列是單一玻璃容器。

## 顏色(ADR-0008)

| 用途 | 色碼 | 說明 |
|---|---|---|
| 品牌紅 | `#FA2D48` | 接近 Apple Music 紅。只用在圖示與不承載文字的裝飾;配白字只有 3.8:1 |
| 紅字 `brandText`(#70;`AccentColor` 同值，即系統 tint) | light `#D80521`／dark `#FC5D72`／light 高對比 `#A20419`／dark 高對比 `#FCA1AD` | tint、狀態文字、「需要你」(不用於對話中的連結)。淺色對白底 5.3:1、`#F2F2F7` 4.7:1、`#EFEFF0` 4.6:1;深色對黑底 6.9:1、`#1C1C1E` 5.6:1、`#2C2C2E` 4.6:1;高對比兩值對同一組背景都 ≥ 7.1:1 |
| 紅底 `brandFill`(#70) | light 與 dark `#EA0826`／兩種高對比 `#B3041B` | 承載白字的填色：送出鍵、使用者泡泡、主要按鈕、「+」、膠囊標籤、iPad 列表的選取列(#95)。白字 4.6:1、高對比 7.1:1;深色模式不跟著紅字變亮 |
| 次要文字 `secondaryText`(#67) | light `#636366`／dark `#AEAEB2`／light 高對比 `#48484A`／dark 高對比 `#D1D1D6` | 取代承載資訊的系統 `.secondary`／`.tertiary` 文字(系統 secondaryLabel 白底只有 3.4:1)。淺色對白底 6.0:1、grouped `#F2F2F7` 5.4:1、淡填色卡片 `#EFEFF0` 5.2:1;深色對黑底 9.5:1、`#1C1C1E` 7.7:1、grouped 列 `#2C2C2E` 6.3:1;高對比兩值對同一組背景都 ≥ 7.9:1 |
| 連結 `linkText`(#93) | light `#0068DA`／dark `#2D96FF`／light 高對比 `#004DA2`／dark 高對比 `#7DBEFF` | 對話中的連結(markdown)。系統連結藍的色相，只調明度:系統 `.link` 淺色對 `#EFEFF0` 只有 3.5:1、深色對 `#2C2C2E` 3.8:1。對比對同一組背景與紅字相同(淺色 ≥ 4.6:1、深色 ≥ 4.6:1、高對比 ≥ 7.1:1) |
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
- **Agent 列表**:所有主機的 Agent 合併在同一個列表，選取中主機的列在前。主機標示依檢視而不同:Agents 檢視只在非選取中主機的列副標開頭加主機圖示 + 主機名;Spaces 檢視由主機分組標題表示，每台主機都一樣標示，列上不再加主機名(只有不分主機的「已釘選」組，項目第三行加主機名)。列左側表示 agent 種類(Agents 檢視是圖示，Spaces 檢視是種類頭像;都對 VoiceOver 隱藏，種類名稱在列的文字裡)。某台主機連不上時保留它最後的列，列表下方「連線中斷」區段每台一行「主機名：原因」與「再試一次」;只有沒有任何列時，選取中主機的錯誤才佔滿畫面。工具列左側是**選取中主機鈕**(主機圖示 + 名稱，選單內切換;只決定新聊天開在哪裡、套用誰的主題、Claude 用量與推播設定讀哪台，不隱藏其他主機);右側搜尋、新增對話;狀態同時用文字 + 符號 + 顏色;底部選取中主機的 Claude 用量(5h／Week 剩餘比例與重置時間)。
- **主機清單**(sheet):每列左側是主機圖示(使用者在 context menu 的「圖示」選:桌機、筆電、Mac mini、機架、PC、顯示器、雲端;只存在這支裝置)。點一台即選取並回到列表。滑動：左側「編輯」;右側「刪除」(destructive,不允許整列滑到底，點了直接刪、不另外確認——只刪這支裝置上的設定，主機本身不受影響)與「分享」。context menu:編輯、重新命名…、分享…、分隔線、刪除(最後)。分享在同一個 sheet 內 push:白底 QR code(深色模式也是白底)、說明「密碼與私鑰永不分享」、系統分享鈕。掃 QR code 或點分享連結 → 主機 sheet 開出帶好欄位的新增主機表單。
- **連線中斷**:不用 alert,也不用會自動消失的提示。Agent 列表保留最後的列，在列表下方顯示「連線中斷」區段(原因 + 「再試一次」),重新連上才消失;對話在頂端橫幅顯示離線與「再試一次」。網路切換或回前景後自動恢復，不需使用者操作。
- **對話**:使用者泡泡用填色紅底白字，agent 泡泡用系統次要背景;thinking 與 tool 呼叫預設摺疊成一行;呼叫 skill 顯示「已載入 skill:<名稱>」,不貼全文;subagent 用卡片顯示各自狀態;agent 卡住時，選項以卡片放在該則提問下方(內容層):每個選項是同寬的圓角長方形選項卡(圓角 10pt,卡片 16pt 內縮一層;不用膠囊形),長文字多行完整顯示，建議選項用紅底 prominent 樣式而非大小區分。對話中的連結是連結藍(`linkText`),不用品牌紅。「Jump to Latest」只在離開底部時出現(在底部、對話短到不用捲、跟隨新訊息時都不顯示)。標題下一行是狀態點與狀態字，再以「·」串接主機名(非選取中主機)、workspace、agent、模型、effort、資料夾,放不下時從後面整段拿掉、不截斷，VoiceOver 念完整內容。標題列右側：不在工作中「重新載入」,工作中「停止」(點一下送 Esc;長按選單「強制結束」送 Ctrl-C;「需要你」的 agent 永不中斷)。工作中時對話最底下是內容層的指示：即時預覽(次要色)、3×3 點陣(Reduce Motion 時不動)、「Working…／Writing…」與經過時間。
- **列表大標題**(#66):Agent 列表(iPhone 與窄視窗、iPad 的列表欄)最上面是大標題「目前檢視名 ⌄」(Large Title 粗體、靠前緣、⌄ 次要色),點了出檢視選單(目前那個打勾);VoiceOver 唸「Spaces,按鈕」並有標題特徵，AX 字級換行不截斷。往上捲過一半，大標題收合成導覽列的小標題，小標題一樣點了出同一個選單(系統 title menu);載入中、錯誤、空狀態只有小標題。實作：系統的 title menu 只掛在 inline 標題上(`.large`／`.inlineLarge` 最上面的大標題是靜態文字，點了沒選單);iOS 26 的 `ToolbarItem(placement: .largeTitle)` 畫得出自訂內容，但不在 accessibility tree、也不接觸控。所以大標題畫在列表第一列(一般的 `Menu`),它在畫面上時以 `toolbar(removing: .title)` 收起導覽列小標題，捲上去才把小標題(`navigationTitle` + `toolbarTitleMenu`)放回來;`navigationTitle` 一直設著(App 切換器與視窗標題用)。
- **Spaces／Agents 檢視**(#40、#103):Agent 列表的大標題(或收合後的小標題)選單切換兩種檢視，存在本機，重新啟動後還是同一個。Agents 檢視每個 Agent 一列。
  - **依主機分組**:Spaces 檢視最上面是不分主機的「已釘選」組，其餘每台主機一組，順序同合併列表(選取中主機在前)。分組標題是主機圖示、主機名(Title 3 粗體)與這台主機各狀態的 Agent 數量(「● 需要你 1 · ● 工作中 2 · ○ 閒置 3」,已讀的完成算閒置);VoiceOver 念主機名與各狀態數量，有標題特徵。主機組內有需要你的 workspace 在前、再來是工作中，其他依 workspace 編號。搜尋時沒有命中的 workspace 與主機組不顯示。
  - **聊天列與群組**:只有一個 Agent 且沒有其他 Pane 的 workspace 是聊天列(第三行是狀態與 workspace 名稱),其餘是可收合的 workspace 群組。不再顯示 Tab 分組、Tab 數、Pane 數與資料夾。
  - **收合標頭(H2 狀態條)**:整列是一個按鈕。左側 36pt workspace 圖示(與聊天列的種類頭像對齊);第一行名稱 + Agent 總數膠囊(只算 Agent);第二行 6pt 高的分段狀態條——20 個 Agent 以內每個 Agent 一段、依需要你 > 工作中 > 完成 > 閒置排序、等寬，超過 20 個依狀態合併、段長與數量成正比，沒有 Agent 時不畫;第三行圖例「● 狀態 數量」,有終端機時加「終端機 N」,只有終端機時寫「N 個終端機」。右側 chevron 展開時轉 90°。VoiceOver 念「名稱、N 個 Agent、各狀態數量、已展開／已收合」並有按鈕特徵，狀態條對 VoiceOver 隱藏。狀態色沿用列表的狀態色，閒置段用低飽和的 `idleSegment`(非文字圖形，對列背景 ≥ 3:1)。
  - **展開規則**:有需要你或工作中的群組預設展開，其他收合。點標頭切換;手動狀態以「主機 + workspace id」記在記憶體，列表更新不改回去，App 結束就忘記(不寫入 `UserDefaults`)。搜尋時命中的群組一律展開，不改手動狀態，清掉搜尋後恢復。
  - **展開後的列**:Agent 列依狀態排序(需要你在前),左側 Agent 種類頭像(36pt 圓角方塊、白色字母;Claude Code、Codex、Gemini、opencode、GitHub Copilot 各有底色，其他種類中性色 + 首字母;底色四個值對白字 ≥ 4.5:1、高對比 ≥ 7:1),標題、預覽各最多兩行(AX 字級不限),第三行是狀態(符號 + 文字 + 顏色)與 Agent 種類名稱;終端機列排在 Agent 列之後，開 Pane 終端機(標題是程式名)。
  - **版面圖入口**:長按群組標頭的 context menu 第一項是「顯示版面」,其後是重新命名、新增 worktree、關閉 workspace;卡片上的版面圖按鈕已移除。iPad 側欄的版面圖按鈕不變。
- **已釘選與未讀**(#41):列的滑動或 context menu「釘選」把聊天放進最前面的「已釘選」組(不論狀態，依釘選先後);標題後的圖釘、靜音小圖示用次要色。未讀的完成以實心圓標示，VoiceOver 念「Unread」;已讀的完成顯示成閒置。section 標題帶數量。需處理數量(有「需要你」或未讀的 workspace 數)顯示在主機與設定 sheet 的「完成」旁，0 不顯示、超過 99 顯示「99+」,不設 app 圖示徽章。列表最底部的滑動提示在第一次用了滑動動作後不再出現。
- **視窗**(#31):iPad 可開多個視窗，每個視窗各自的側欄、列表選取與聊天;UI 一律稱「視窗」,不稱 Scene 或分頁。
- **You should know**(#23):列表最上方一列「✦ N notes for you」(所有主機合計，只算列表裡有的 Claude 聊天),點了開註記清單(sheet,選取中主機的在前),每則可「Go to Chat」。輸入列上方以內容層卡片顯示這個聊天 session 的那則(不透明 `.background` 底 + `.separator` 邊，同 slash 選單;tint 文字按鈕在 `#F2F2F7` 底不到 4.5:1),動作 Learn More(有說明時)、I Knew That／Got It、Discuss in Chat(放進輸入框，不蓋掉已打的字)、Dismiss;第一次動作前以 alert 徵求同意(會改主機上的 store;同意與寫回都是聊天所在的那台),設定可撤掉(選取中主機的)。
- **輸入列**:附加、多行輸入、送出(唯一 tinted 主要動作);輸入框隨內容長高，上限是 8 行與鍵盤上方可用高度(視窗安全區域內、鍵盤以上，iPad 分割畫面依當下視窗)的 40% 取小，最小 44pt,超過上限才在框內捲動(`ComposerSizing`,#137)。偏離行為規格 F6.1 的「4 行後內捲」:多行提示詞 4 行很快就內捲、難以回頭修改;固定行數在 AX 字級或小螢幕會蓋掉整個對話，所以加上可用高度比例。內容超過 2 行或聚焦時，輸入框右上角有「展開」鈕(44pt、次要色，`ComposerExpansion`,#142),打開大的編輯畫面(large sheet;不用 fullScreenCover,它會讓底下的對話視為消失):同一份草稿與同一個 UITextView 型輸入框(組字中 Return 只確認選字，硬體鍵盤規則同輸入列),上方附件列可查看、移除，底部「加入圖片」「完成」與送出鈕在鍵盤出現時停在鍵盤上方。「完成」或下滑收回時草稿保留、鍵盤收起;在裡面送出就收回到對話。slash 選單只在輸入列。**與 spec #135 的偏離**(行為不改，理由記在這裡):展開畫面用 large sheet 而非全螢幕(fullScreenCover 會讓底下的對話 onDisappear,取消自訂回答、停掉輪詢);輸入框長高依實際內容高度(含換行後的折行)計算而非「內容行數」,折行的長句也算進去;展開畫面沒有 slash 選單(大畫面編輯的是長提示詞，選單蓋住內容，且選單鍵盤操作與 Return 送出衝突)。輸入 `/` 時彈出依來源分組的 slash 選單，可鍵盤上下選擇;打了名稱後改成沒有標題的單一排名清單。每列參數提示淡色等寬;點選或 Return 選定任何指令都只填入 `/名稱 `(不送出、鍵盤不收起，#83),有參數提示的淡淡顯示在游標後。`/model`、`/effort` 開出的面板在聊天內以原生卡片呈現(內容層，同「需要你」卡片背景):目前使用中打勾、游標列填色高亮、effort 以分段控制與 ‹ › 調整、面板自己的動作鈕(確認 prominent、取消最後且中性)。
- **終端機**:全螢幕深色;標題下是狀態點加文字(連線中…／已連線／連線中斷／已結束等),連線中斷時橫幅提供「重新連線」,Pane 被別人操作或接管時提供「接管」。按鍵列是單一玻璃容器：可橫捲的 Esc、Tab、Ctrl、Alt(鎖定時同時有底色與「•」標示)、← ↓ ↑ →、`/`、`-`、`|`、`~`、Home、End,Esc～Alt 排最前面、最窄寬度也不用捲;列尾固定兩顆獨立鈕「貼上」與「收起鍵盤」。每鍵 ≥ 44×44 pt 並有 VoiceOver label。字級可用捏合與 `Aa` 選單調整(8–28 pt)。單指垂直滑動捲動(交給 herdr 決定捲歷史或送滾輪)。唯讀配對的裝置(HTTPS)只能看：已連線時橫幅說明只能看，按鍵列、貼上與滑動捲動停用。鍵盤輸入由 Purrdr 接管(不經 SwiftTerm):用輸入法組字時不送任何東西到遠端(組字中刪字也不送退格),選字確認後才送出;組字中實體鍵盤的所有按鍵(含 Ctrl-C、Esc、Return、方向鍵、空白)交給輸入法、不送遠端;組字中按按鍵列的鍵或「貼上」,先放棄組字(不送出、浮層消失)再送出該鍵或貼上內容。實體鍵盤的 Page Up／Down:登入 Shell 依模擬器看到的模式，遠端開了 alternate screen 或 application cursor 時送到遠端、一般畫面在本機捲一頁;Pane 終端機的串流不轉送終端機模式(App 看不到 less、vim 開了 alternate screen),所以一律送 `terminal.scroll` 的 `page_key`,由 herdr 依 Pane 的實際狀態決定捲主機 scrollback 或把 `ESC[5~`／`ESC[6~` 送給程式(herdr `apply_scroll`、`plain_page_keys_use_host_scrollback`)。方向鍵與 Home／End:登入 Shell 遠端開了 application cursor(DECCKM)時送 SS3(`ESC O A`),否則 CSI(`ESC [ A`),帶修飾鍵一律 `CSI 1;<參數>`;Pane 終端機看不到 DECCKM,herdr 也沒有依模式編碼按鍵的訊息，固定送 CSI(大部分程式兩種都收)。實體鍵盤另外支援 Shift-Tab、F1–F12、Delete(xterm 編碼),是 spec #135 沒列、但終端機使用者預期會有的鍵。系統發起的結束組字(輸入法切換、點畫面等)一律放棄組字文字、不送出:字元範圍分不出「已選好的字」與「還在拼的音」(拼音字母、假名、注音都可能),寧可少送不誤送;實機紀錄(#139)若顯示某輸入法的確認走這條路，再個別調整。**組字浮層**(#140):組字中的文字直接畫在遠端游標格子上——終端機字型與字級、每個字對齊格子(寬字元佔兩格)、整段畫 1pt 底線，輸入法正在選的那一段畫 2pt 粗底線;背景與文字色取游標格子的顏色(反白時對調),所以看起來像已經打在命令列上。浮層從游標格子往右長，超出畫面右緣時整段往左移;遠端游標移動(輸出捲動、換行)時跟著移。確認或取消後立刻消失。選字窗(iPad 實體鍵盤)對齊組字段，沒有組字時對齊游標格子。VoiceOver 念「組字中」與組字文字。

## 通用規則

- 文字一律用 text style,支援到 AX5 不截斷;觸控目標 ≥ 44×44 pt。
- app 快捷鍵只用 Command;終端機聚焦時 Control 組合鍵與 Esc 送往遠端(組字中除外：實體鍵盤的所有按鍵交給輸入法)。
- 完整的逐畫面檢核清單在 `docs/research/apple-hig-drover-chat.md` 第 20 節，實作每個畫面時逐項檢查。
