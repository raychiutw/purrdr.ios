# Purrdr 改版原型(#376／#377)視覺一致性與 HIG 審查

> 由獨立審查子代理(Opus)產出;寫檔時磁碟已滿,由主 session 依其回覆原文存檔。對比值依 WCAG 相對亮度公式手算(約 ±0.05);玻璃上的對比假設底下是頁面底色。

- 審查日期:2026-11-22。對象:20 個 artboard(`design377/project/*.dc.html`),從原始碼推斷畫面(沒有渲染)。
- 依據:`origin/master` 的 `DESIGN.md`、`docs/research/apple-hig-drover-chat.md`(「HIG 研究」)、`docs/research/ios27-design-language.md`(「iOS 27 研究」)、issue #376。
- HIG 原文(2026-11-22 從 developer.apple.com 的 JSON 端點重讀確認):Tab bars、Toolbars、Sheets、Menus、Toggles;其他頁原文引自 HIG 研究。
- 標記:只陳述有依據的判斷;沒有依據的標「意見」;Apple 自家 app 的做法標「慣例」。

## 摘要:最嚴重的 10 項

| # | 嚴重度 | 問題 |
|---|---|---|
| 1 | 必修 | 帳號頁只剩會員、通知裝置、登出,沒有「刪除會員」。App Store Review Guidelines 5.1.1(v) 要求提供帳號就要能在 app 內刪除;DESIGN.md「帳號頁」也列了刪除會員 |
| 2 | 必修 | 第一層頂列右上的「新增聊天」36×36、帳號「R」32×32,只隔 2px,無法各自擴到 44pt(Tabs、Host、HostHttps、Settings、Files、Spaces、States、Offline、DarkCompare) |
| 3 | 必修 | 淺色 tab bar 選取標籤:主色 `#0B7A5C` 疊在玻璃 fill(約 `#E9E9EB`),11pt 只有 4.38:1 |
| 4 | 應修 | 深色紅字「刪除主機」「登出」(`#FF453A` 在 `#2C2C2E`)只有 4.09:1 |
| 5 | 應修 | 第二層靜態標題(Files 預覽、Git、Terminal、Shell)用跟可點的聊天標題膠囊一樣的玻璃膠囊,不能點卻像能點;玻璃用在非控制元素 |
| 6 | 應修 | 空狀態(States)主要按鈕「新增主機」是內容層裡的玻璃按鈕,違反 HIG〈Materials〉「Don't use Liquid Glass in the content layer」 |
| 7 | 應修 | 色彩 token 漂移:淺色 `--card` 有時白、有時 `#F2F2F7`;淺色紅 `#D70015`／`#FF3B30` 兩值;玻璃配方 5 種不透明度 |
| 8 | 應修 | 低飽和用量色、diff 綠／紅、README 語法色不在 DESIGN.md 色盤,也沒有「增加對比」版本(DESIGN.md 要求四值) |
| 9 | 應修 | Agents 與 Spaces 的列結構不同:Spaces 狀態點在列尾、沒有頭像;DESIGN.md「Agent 列表」規定 Spaces 列首同樣是頭像加右下狀態 |
| 10 | 應修 | 終端機按鍵 36pt、沒有貼上／收起鍵盤與 Home／End、沒有大小膠囊;輸入列 + 與送出 40pt(DESIGN.md 要 ≥ 44pt) |

## 問題清單

### A. 跨 artboard 一致性

| 編號 | 嚴重度 | Artboard | 現況 | 依據 | 修正 |
|---|---|---|---|---|---|
| A1 | 應修 | Host vs HostHttps／Files／Settings | 頂列左側佔位:Host 44px,其他 84px,中間膠囊位置不同,切 tab 會跳 | #376 故事 36 | 中間膠囊對齊螢幕中線;佔位等於右側群組寬度 |
| A2 | 應修 | Settings tab | 中間是純文字「設定」,其他 tab 是可點膠囊 | #376 | 寫明例外;標題基線對齊膠囊文字,或用系統 large title(意見) |
| A3 | 應修 | Files 預覽、Git、Terminal、Shell vs Main／Header／NeedsYou | 前者標題膠囊是不能點的玻璃 div;後者是 button | HIG Toolbars;HIG Materials | 靜態頁用系統導覽列標題(兩行用 `navigationSubtitle`),不包玻璃;只有可點的聊天標題用玻璃膠囊 |
| A4 | 應修 | Offline、DarkCompare | 用文字符號當圖示(▾ + ‹ ⋯ ↑),tab bar 只有文字,Offline 沒有搜尋欄 | 一致性;HIG Icons | 套用 Tabs 的頂列、tab bar 與 SVG 圖示 |
| A5 | 應修 | DarkCompare | 對照列表是卡片列,與選定的 Tabs 列表不同 | 控制變因(意見) | 改成 Tabs 的列表與頂列,只換底色 |
| A6 | 應修 | 各檔 | 頂列下內容起點 116／120／126／130 不一 | 間距節奏(意見) | 用系統工具列／safe area,不手寫數字 |
| A7 | 應修 | Settings | 外觀列 46px,其他 50px | 一致性 | 統一系統 inset grouped 列高 |
| A8 | 建議 | 各檔 | 列高 46–64、圓角 10–28 很多種 | 意見 | 整理 token:單行列、雙行列;卡片 22、程式碼 12、選單 24 |
| A9 | 應修 | Model | 卡片圓角 26,sheet 38 內距 16 不同心(應 22) | HIG Toolbars／Adopting Liquid Glass | 改 22 |
| A10 | 應修 | Host／Settings／NewChat、Header／PanelStates、Spaces、Attach | section 標題四種寫法(含全大寫) | HIG 研究 §7 引 Adopting Liquid Glass:section header 不再全大寫 | 統一系統 section header(footnote,`secondaryText`) |
| A11 | 應修 | 卡片 vs 列表 | 卡片分隔線從最左畫到最右 | 慣例(設定 app 從文字起點) | 卡片列分隔線從文字起點 |
| A12 | 應修 | 第一層頂列 | 「Agents ▾」500、「所有主機 ▾」600 | 一致性 | 同字重 semibold |
| A13 | 應修 | 主要按鈕 | 54／52／50 高、States 用玻璃 | 一致性 | 統一高度與 `.borderedProminent` |
| A14 | 應修 | Header vs NeedsYou 等 | 「● 工作中」一處次要色一處主色;「!」字重不同 | DESIGN.md 狀態色(StatusTone) | 照 StatusTone 上色;「!」用 SF Symbol |
| A15 | 應修 | 色彩 token | 淺色 `--card` 兩義;淺色 Spaces 白底灰卡;`--track` 重複定義 | HIG Color | 分 grouped／非 grouped 兩組語意 token |
| A16 | 應修 | 淺色紅 | `#D70015` vs `#FF3B30` | 同上 | 用系統 `.red` |
| A17 | 建議 | 玻璃 | 不透明度 .74–.90、blur 20／24 | DESIGN.md:自訂玻璃只用 regular | 統一一個 regular token;實作用 `.glassEffect(.regular)` |
| A18 | 應修 | 圖示 | 線寬 1.2–2.4 混用;返回 20／18px | HIG SF Symbols | 全部 SF Symbols(終端機 `apple.terminal`、Git `arrow.triangle.branch`、聊天 `bubble.left.and.bubble.right.fill`、檔案 `folder.fill`、主機 `desktopcomputer`、設定 `gearshape.fill`) |
| A19 | 應修 | Files | 上傳圖示與分享圖示幾乎一樣 | HIG 研究 §17 | 上傳改 `arrow.up.doc` 或「＋」 |
| A20 | 應修 | 選單圖示位置 | ⋯ 選單圖示在前;主機選單勾在前;Spaces 選單勾在後 | 慣例:系統 pull-down 勾在前、圖示在後 | 用系統 `Menu`,位置交給系統 |
| A21 | 應修 | 字級 | 14、12.5、11.5、18、24 等非 text style | DESIGN.md 通用規則;HIG Typography | 改成對應 text style;等寬字跟 Dynamic Type |
| A22 | 應修 | 邊距 | 聊天文字 20、輸入列 16／8、橫幅 16 | DESIGN.md 聊天 A1:同一條 16pt 邊 | 訊息改 16;展開的 8 見 B9 |
| A23 | 建議 | 深淺兩版 | NeedsYou 程式碼區深淺邏輯相反 | 意見 | 用 `.fill.tertiary` |
| A24 | 應修 | PanelStates | 文案「在電腦上用 /permissions」 | #376 用詞 | 改「主機」 |

### B. 是否符合 HIG

| 編號 | 嚴重度 | Artboard | 現況 | 依據 | 修正 |
|---|---|---|---|---|---|
| B1 | 必修 | 帳號頁 | 沒有刪除會員 | [App Review 5.1.1(v)](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage);[HIG Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts) | 保留「刪除會員」 |
| B2 | 應修 | 4 個 tab | tab 圖示是線條 | [HIG Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars):「Prefer filled symbols」 | 改 filled SF Symbols |
| B3 | 可疑(意見) | 第二層 | 隱藏 tab bar | [HIG Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars):隱藏會讓人忘記在哪個區域;例外是 modal 覆蓋 | 可保留(輸入列與 tab bar 搶底部),在 DESIGN.md 記理由;或用 `tabBarMinimizeBehavior` |
| B4 | 可疑 | Files、Host、Settings | 右上固定「新增聊天 +」,與該 tab 內容無關 | [HIG Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars):作用於目前畫面的控制放 toolbar;WWDC25 356 | 只在聊天 tab 放「+」;其他 tab 放該頁動作。要重新確認 #376 決策 |
| B5 | 應修 | States | 空狀態按鈕用玻璃 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | `ContentUnavailableView` + `.borderedProminent`;範例主機用 borderless |
| B6 | 應修 | Settings | 外觀自動／淺色／深色 | [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode):「Avoid offering an app-specific appearance setting」 | #246 既有決策;保留就在 DESIGN.md 寫理由 |
| B7 | 應修 | 深色稿 | 頁面提亮到 `#1C1C1E` 後 sheet 同色,失去 base／elevated 層次 | [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | sheet `#2C2C2E`、sheet 內卡片 `#3A3A3C`(次要文字 5.13:1);附增加對比版 |
| B8 | 應修 | Model／Attach／帳號 | sheet 左上 xmark | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) 允許;DESIGN.md 規定右上「完成」 | 見 D 節:選一種寫進 DESIGN.md |
| B9 | 意見 | Main 展開 | 輸入卡片左右 8 | [HIG Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards):keyboard layout guide + standard padding | 標準邊距 16 |
| B10 | 應修 | Attach、NewChat | 主要動作在底部、頂列無確認;Attach 高度固定 | [HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | 可保留底部按鈕(慣例);部分高度畫成內縮玻璃,detent medium |
| B11 | 建議 | Model | 內容短卻用 large | 同上 | medium,可拉 large |
| B12 | 應修 | Spaces 檢視選單 | 圖示與勾自訂位置 | [HIG Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | 用系統 Menu |
| B13 | 應修 | NeedsYou 工作中 | 狀態文字與停止包在同一顆 40h 按鈕 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars);HIG Buttons 44pt | 停止獨立一顆 ≥ 44pt,VoiceOver 分開念 |
| B14 | 應修 | Host、HostHttps、Model | 手繪開關無 role/狀態;`label for` 找不到 id | [HIG Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) | 實作用系統 Toggle;原型標 `role="switch"` |
| B15 | 意見 | Tabs、States | 自繪搜尋欄 | [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) | 系統 `.searchable` 或自繪二選一寫進 DESIGN.md |
| B16 | 建議 | 玻璃稿 | 無減少透明度/增加對比版本 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | 至少補一張「減少透明度」 |
| B17 | 應修 | 頂列 | 標題膠囊可展開,只有部分標 `aria-expanded` | [HIG VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover) | 加 hint |

### C. 觸控目標、只靠顏色、VoiceOver

**觸控目標 < 44pt**(HIG Buttons;DESIGN.md 通用規則)

| 元素 | Artboard | 尺寸 | 嚴重度 |
|---|---|---|---|
| 頂列「新增聊天」與帳號 | 9 個第一層稿 | 36×36、32×32,相隔 2px | 必修 |
| 輸入列 +、送出 | Main、DarkCompare、Offline、NeedsYou | 40×40 | 應修 |
| 終端機按鍵 | Terminal、Shell | 36 高 | 應修 |
| Files 麵包屑與上傳 | Files | 36 | 應修 |
| Spaces 版面圖鈕 | Spaces | 32×32 | 應修 |
| 「再試一次」 | Offline | 34 | 應修 |
| 排隊訊息「取消」 | Offline | 13pt 行內字 | 必修 |
| 停止膠囊 | NeedsYou | 40 | 應修 |
| 主機挑選鈕 | NewChat | 40 | 建議 |
| 搜尋欄 | Tabs、States | 38／40 | 建議 |

**只靠顏色**:用量三段門檻亮度接近、只差色相(有數字,不違反,建議到門檻加三角形符號);列表狀態只靠徽章形狀加顏色,DESIGN.md 要求「文字與符號」→ 確認列表是否補狀態字。

**VoiceOver 缺漏**:頭像字母念成字母(應念種類)、context 圓環只念百分比、副標「●」「!」會被念出、「▾」會被念出、Git 種類字母 aria-label 在無 role span、照片格無序號、麵包屑「~」念成波浪號、終端機方向鍵無 label、開關無 role、排隊「取消」是 span。

## 對比計算表

| 前景 | 背景 | 對比 | 判定 |
|---|---|---|---|
| D 次要 `#AEAEB2` | 頁面 `#1C1C1E` / 卡片 `#2C2C2E` / 玻璃 / `#3A3A3C` | 7.7 / 6.3 / 6.5 / 5.1 | ✓ |
| D 主色 `#3CCF9E` | 頁面 / 卡片 / tab fill | 8.6 / 7.0 / 5.1 | ✓ |
| D 白 ✓ | 完成徽章 `#8E8E93` | 3.3 | 符號 ✓、文字 ✗ |
| D 黑 ! | 橙 `#FF9F0A` | 10.2 | ✓ |
| D 頭像字 Claude / Codex | 各自底 | 6.2 / 6.5 | ✓ |
| D 用量 ok / warn / high | 軌道 ≈`#404042` | 4.0 / 4.1 / 3.4 | 非文字 ✓ |
| D Git +6 / −9 | 頁面 | 6.6 / 5.6 | ✓ |
| D 警示膠囊 `#FFB340` | warnbg/卡片 | 5.4 | ✓(違反「系統橙不承載文字」) |
| **D 紅字 `#FF453A`** | 卡片 | **4.1** | **✗** |
| D 開關 off 軌道 | 卡片 | 1.6 | 建議 |
| 終端機文字/ANSI 色 | `#141416` | ≥ 8.9 | ✓ |
| L 次要 `#636366` | 白 / `#F2F2F7` / 白上 fill / 灰上 fill | 6.0 / 5.4 / 4.9 / 4.5 | ✓(最後臨界) |
| L 主色 `#0B7A5C` | 白 / `#F2F2F7` | 5.3 / 4.8 | ✓ |
| **L 主色 tab 標籤 11pt** | fill ≈`#E9E9EB` | **4.4** | **✗** |
| L 橙徽章 / 標題「!」 | 白 | 2.2 | ✗(旁有文字,建議改填色符號) |
| L 頭像字 Claude / Codex | 各自底 | 5.5 / 6.7 | ✓ |
| L 用量 ok `#5E9583` | 軌道 `#E9E9EB` | 2.8 | ✗(非文字,有數字) |
| L 用量 warn / high | 軌道 | 3.2 / 3.6 | ✓ |
| **L Git +6 `#4F8572`** | 白 | **4.4** | **✗** |
| L Git −9 / 紅字 `#D70015` | 白 | 5.3 / 5.4 | ✓ |
| **L 未選照片白圈** | `#D8D8DD` | **1.4** | **✗** |

修正建議:淺色 tab 選取用高對比主色 `#075C45` 或降低 fill,最好用系統 tab bar;淺色 Git「+」改回主要色粗體;深色紅字改 `#FF6961` 或主要色文字(系統紅字按鈕慣例與 WCAG 衝突,要使用者決定)。

## 與 DESIGN.md 的衝突

| DESIGN.md 規則 | 原型 | 評估 |
|---|---|---|
| 不採 tab bar、⋯ 選單 | 4 tab;⋯ 改終端機／Git | 推翻有理(#376),改 DESIGN.md,並處理 B2–B4 |
| Agents／Spaces 用兩列勾選 | 左上選單 | 有理,改 DESIGN.md 列為例外 |
| sheet 右上「完成」 | 左上 xmark | 兩種都合 HIG,選一種寫進 DESIGN.md |
| 輸入列:收鍵盤鈕、8 行、權限膠囊、≥ 44pt | 無收鍵盤、5 行、權限移面板、40pt | 前三項有理;40pt 應改回 ≥ 44 |
| 點標題開狀態 sheet(待辦、子 Agent、做完再送) | 只有用量、context、權限 | **缺口**:待辦、子 Agent、「做完再送」沒有新入口 |
| context 70% 橙、85% 紅;語意色只有系統紅橙 | 低飽和色、diff 綠紅底 | 應改回,或正式寫進 ADR-0011(四值與對比測試) |
| 變更頁:新增粗體、刪除次要色 | 綠紅字加底色 | 應改回 |
| 系統橙不承載文字 | 「3.5× 使用量」橙字 | 改主要色文字配橙三角形 |
| 檔案:右上「＋」上傳、≥ 44pt | 上傳移麵包屑、36pt | 位置有理;尺寸改回,圖示與分享分開 |
| 終端機:貼上／收起鍵盤、Home／End、每鍵 ≥ 44、Aa 字級 | 10 顆 36pt 鍵 | 應改回(漏畫) |
| 設定頁六段、App 鎖開關、送出可撤回 Stepper、數據用量 | 「其他」推入列、無數據用量 | 應改回分段 |
| 帳號頁:登入方式、刪除會員 | 都拿掉 | 刪除會員必須改回;登入方式建議保留 |
| 附加:照片在上、勾選 | 種類在上、數字序號 | 有理,改 DESIGN.md |
| Spaces 列首頭像加右下狀態 | 列尾狀態點 | 應改回 |
| 16pt 同一條邊 | 訊息 20、展開輸入列 8 | 應改回 |
| 顏色對比以純黑為準 | 底色 `#1C1C1E` | 有理;補 sheet 層次(B7) |
| 沒有主機空狀態用 `ContentUnavailableView` | 自繪、玻璃按鈕 | 應改回系統元件 |

## 做得好、應保留

- 主色與次要文字 token 跨 20 檔一致,與 ADR-0011 相同;主色上的字正確。
- 玻璃大致只在控制層;內容卡片用中性底;右上兩顆按鈕同一玻璃容器。
- 狀態有符號形狀加顏色加 aria-label;錯誤橫幅紅色只上在圖示。
- 停用送出鈕改中性 fill,解決黑色圓。
- 選項一律勾選列攤開。
- 每畫面最多一顆主要填色按鈕;刪除放獨立卡片。
- sheet 有 grabber、子頁有返回;HTTPS 無用量不畫壞區塊;權限停用附原因。
- 主機選單不列範例主機、「新增主機…」有省略號。
- 終端機 ANSI、語法色、頭像色對比 ≥ 5.4:1;離線排隊泡泡沿用 DESIGN.md。

> **2026-11-22 修正(取代 A20／R29 中「勾在前、圖示在後」的描述)**:iOS 26 系統 `Menu` 把項目圖示放在文字前面,沒有 API 可以調整。設計稿已改成勾與圖示都在文字前,與系統行為一致;DESIGN.md 同步改為「圖示在前」。
