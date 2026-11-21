# 取消 clean-room:可以閱讀 herdrchat 與 Heeler 的原始碼

取代 ADR-0001。使用者決定(2026-11-21):移除 clean-room 設定，研究與實作時可以直接閱讀 herdrchat(`cobanov/herdrchat`)與 Heeler(`ZingerLittleBee/Heeler`)的原始碼，參考它們解決同一類問題(例如聊天載入、捲動、herdr API 的用法)的做法，不必只透過行為規格轉述。

兩者都是 Apache-2.0。閱讀不受限;**複製或改寫程式碼**時照 Apache-2.0 處理：保留原作者的著作權與授權聲明、在檔頭註明來源與修改，並在 repo 根目錄維護 `NOTICE`(第一次引入時建立)。herdrchat 的 `legacy/` 授權範圍不明確(ADR-0001 的原始顧慮),仍不複製其程式碼，只參考做法。

## Consequences

- AGENTS.md 拿掉「clean-room」一條，改成指向這份 ADR;`docs/research/herdrchat-behavior-spec.md` 照樣保留，作為行為的整理。
- 研究筆記可以引用兩個 repo 的檔案與行號(以 commit 固定版本)。
- 引入第三方程式碼的 PR 要在說明裡列出來源與授權處理。
