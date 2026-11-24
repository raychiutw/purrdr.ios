# ADR-0014:聊天列表改用 UICollectionView，不用 SwiftUI lazy stack

日期:2026-11-23

## 背景

聊天列表原本是 `ScrollView` + `LazyVStack` + `defaultScrollAnchor`／`scrollPosition`。使用者看到的問題:往上閱讀時被工具步驟拉走、展開的工具串自己收起、圖片捲出再捲回先縮成一行、打開聊天閃骨架畫面、畫面停在內容外露出底色(黑框)。

這類問題已修過 37 次(近 400 筆 commit 中，例如 #185、#191、#210、#251、#255、#418、#476)，修補都落在捲動協調層，問題一直回來。根因是 lazy stack 只能畫完一幀後才補捲，列高未知時位置必然錯一幀。

研究見 `docs/research/chat-message-rendering-heeler-herdrchat-herdr.md`:
- herdrchat 的 SwiftUI 版放棄了與 Purrdr 現在相同的組合。
- Heeler 是唯一順暢的參考實作，底層用 UIKit 列表。
- Signal、Telegram、MessageKit 同樣用 UIKit 列表，在同一次排版內補償捲動位置。

## 決策

- 聊天列表改用 `UICollectionView` + 自訂單欄 layout + diffable data source，包進 SwiftUI 使用;列內容仍用 `UIHostingConfiguration` 寫 SwiftUI。
- 自訂 layout 在同一次排版內補償捲動位置(插入新列、往上補舊訊息、列高改變)，底部錨定由 layout 自己計算。
- 直接取代舊列表，不留開關、不並存;舊的 `LazyVStack` 列表與捲動協調 module 同批刪除。
- 捲動只由一個捲動決策者決定，依「跟隨最新」規則(見 GLOSSARY)，每一刻最多一個指令。

## 考慮過但不採用

- **在 SwiftUI 裡翻轉列表**(整個 `ScrollView` 上下顛倒再把列翻回來):底部錨定靠變形而非真實捲動，會壞掉捲動指示器、選取、VoiceOver 閱讀順序與鍵盤互動，列高變化的補償問題仍在。
- **繼續修 `LazyVStack`**:已修 37 次仍復發;問題在框架只能事後補捲，不是哪一處寫錯。

## Consequences

- 新增 UIKit 薄層，可攜核心(ADR-0006)不受影響:時間軸與捲動規則仍是只用 Foundation 的純值。
- 需要在有模擬器的環境驗證排版與捲動，不能只靠單元測試。
- 以後不要把聊天列表改回 SwiftUI lazy stack。

## 補充(2026-11-24):列高快取與程式捲動

實機卡頓記錄(0.51.x、XXXL):大卡頓(≥ 100 ms)全在 `scroll=idle`,其中 9 成同時有 10 次以上的 cell 自適應。固定的 60pt 估計讓每次追加內容、程式跳動都得逐列自適應並補償位移。決定:量過的列高存起來當估計與已知高度(`ChatListHeightCache`),程式捲動很遠就直接跳並在同一輪排版內對準最底,不再動畫跨過整段沒量過的列。細節與守門測試見 AGENTS.md「聊天列表的列高」。

