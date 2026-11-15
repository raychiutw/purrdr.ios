# DESIGN.md

Drover Chat 的 UI 與 UX 規範。依據是 Apple HIG(研究與逐畫面檢核清單見 `docs/research/apple-hig-drover-chat.md`)。詞彙見 `GLOSSARY.md`。設計原型(三個方向與選定組合)保存在 `prototype/design-directions` 分支。

## 選定方向

- **App 圖示：方向 B1「羊群」**。三隻沿虛線小徑前進的羊，領頭那隻是品牌紅、停下來等你;淺色底。三個圖層(小徑、兩隻跟隨的羊、領頭羊),以 Icon Composer 製作，六種外觀(default、dark、clear light／dark、tinted light／dark)都要辨識得出。不採用紅底白羊(B2),因為「紅漸層底 + 白色圖形」跟 Apple Music 圖示太像。
- **畫面：方向 A「系統清單風」**。Agent 列表是 iOS 標準 grouped list,依「需要你／工作中／閒置」分 section;對話用標準泡泡;終端機全螢幕，按鍵列是單一玻璃容器。

## 顏色(ADR-0008)

| 用途 | 色碼 | 說明 |
|---|---|---|
| 品牌紅 | `#FA2D48` | 接近 Apple Music 紅。只用在圖示與不承載文字的裝飾;配白字只有 3.8:1 |
| 填色底(放白字)、淺色模式紅字 | `#D91E36` | 白字 5.0:1。送出鍵、使用者泡泡、主要按鈕、「+」 |
| 深色模式紅字與強調 | `#FF4D63` | 對 `#1C1C1E` 5.3:1 |

- 每個自訂顏色在 Asset Catalog 都要有 light／dark／各自 high contrast 四個值。
- 紅色只用在主要動作與「需要你」狀態;每個畫面 prominent 按鈕最多 2 個。
- 紅色在 iOS 常代表危險，所以「需要你」一律同時有 `!` 符號與文字，不只靠顏色;真正的錯誤與刪除用系統 `.red`／destructive role,不用品牌紅。
- 其他使用系統外觀，不提供 app 內的深淺色設定。

## Liquid Glass

- 只出現在導覽層與控制層：工具列、主機切換鈕、輸入列、終端機按鍵列。
- 內容層(泡泡、code block、subagent 卡片、核准選項、列表列)不用玻璃，也不疊玻璃。
- 自訂玻璃只用 regular 變體，包在 `GlassEffectContainer`。

## 畫面重點

- **Agent 列表**:頂部主機切換、搜尋、新增對話;狀態同時用文字 + 符號 + 顏色;底部 Claude 用量(5h／Week 剩餘比例與重置時間)。
- **對話**:使用者泡泡用填色紅底白字，agent 泡泡用系統次要背景;thinking 與 tool 呼叫預設摺疊成一行;呼叫 skill 顯示「已載入 skill:<名稱>」,不貼全文;subagent 用卡片顯示各自狀態;agent 卡住時，選項以卡片放在該則提問下方(內容層),建議選項用 prominent 樣式而非大小區分。
- **輸入列**:附加、多行輸入、送出(唯一 tinted 主要動作);輸入 `/` 時彈出依來源分組的 slash 選單，可鍵盤上下選擇。
- **終端機**:全螢幕深色;按鍵列 Esc、Tab、Ctrl(鎖定時同時有底色與「•」標示)、方向鍵、收起鍵盤，每鍵 ≥ 44×44 pt 並有 VoiceOver label;桌機正在操作同一個 Pane 時顯示「接管」提示;字級可用捏合與 `Aa` 按鈕調整。

## 通用規則

- 文字一律用 text style,支援到 AX5 不截斷;觸控目標 ≥ 44×44 pt。
- app 快捷鍵只用 Command;終端機聚焦時 Control 組合鍵與 Esc 送往遠端。
- 完整的逐畫面檢核清單在 `docs/research/apple-hig-drover-chat.md` 第 20 節，實作每個畫面時逐項檢查。
