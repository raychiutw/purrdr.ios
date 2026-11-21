# 參考 herdrchat 的行為，但自行重寫，不複製程式碼

> **狀態：已被 ADR-0012 取代(2026-11-21)**,clean-room 取消，可以閱讀 herdrchat 與 Heeler 原始碼。

herdrchat(Apache-2.0)已經實作了大部分功能，但我們決定從頭以 SwiftUI 重寫。先充分閱讀 herdrchat,用自己的話寫成行為規格(`docs/research/herdrchat-behavior-spec.md`),之後寫程式只依據這份規格、herdr 官方文件，以及在真實主機上的實測，不複製 herdrchat 的程式碼(包括 git 歷史裡的 legacy SwiftUI 版),也不沿用它的檔名、型別名稱、模組結構與品牌。這樣做是為了避開版權疑慮，特別是 `legacy/` 的授權範圍並不明確。

## Consequences

- herdrchat 修過的 bug 不會自動繼承，要靠行為規格把每條規則寫清楚，再各自變成測試。
- 未來有人想「直接把 herdrchat 那段搬過來」時，答案是不行。
