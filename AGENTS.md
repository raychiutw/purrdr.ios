# AGENTS.md

## 專案性質

Purrdr:在 iPhone／iPad 上看、回覆、操作電腦上由 herdr 管理的 coding agent,並開終端機進那台電腦。原生 SwiftUI,最低 iOS 26,用 Xcode 27 建置,Universal,要上架 App Store。尚未開始實作。

- 詞彙在 `GLOSSARY.md`,UI 規範在 `DESIGN.md`,難以逆轉的決策在 `docs/adr/`,一手來源研究在 `docs/research/`。
- **clean-room**(ADR-0001):不閱讀、不複製 herdrchat 原始碼;只依據 `docs/research/herdrchat-behavior-spec.md`、herdr 官方文件與真實主機實測。
- 舊名 Drover Chat 已改為 Purrdr(ADR-0009);ADR-0001～0008 與 `docs/research/` 保留舊名，對照表見 ADR-0009。
- 設計原型保存在 `prototype/design-directions` 分支，不合併。

## 開發流程

- 走 Matt Pocock skill 工作流:`/grill-with-docs` → `/to-spec` → `/to-tickets` → `/implement`。
- TDD:production code 變更先寫失敗測試，並真的跑出紅燈、留下輸出。
- 不直接 commit 到 `master`:開 feature branch,push 後開 PR,合併用 **merge commit**,不用 squash。
- 文件、註解、commit message 用繁體中文(台灣用語),技術名詞保留英文。

## Agent skills

### Issue tracker

Issues 與 spec 放在 GitHub Issues(`raychiutw/purrdr.ios`),用 `gh` CLI 操作。見 `docs/agents/issue-tracker.md`。

### Triage labels

使用預設的五種 triage label:`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。見 `docs/agents/triage-labels.md`。

### Domain docs

單一 context:根目錄 `GLOSSARY.md` 加 `docs/adr/`。見 `docs/agents/domain.md`。
