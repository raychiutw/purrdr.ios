# ADR-0013:Agent 種類集中在 Agent 設定檔，輸出用 ACP 詞彙

日期:2026-11-22

## 背景

Purrdr 對不同 Agent(Claude Code、Codex、Antigravity、Grok…)的差異，原本是直接比對 herdr 回報的 `agent` 字串，散在約 50 處、11 個檔案，另有五個互不相通的種類列舉。新增一種 Agent 要改十幾處，漏改沒有編譯錯誤;已經因此出現名稱寫錯的 bug(`open_code`、`github_copilot`、`antigravity`,herdr 的正式名稱是 `opencode`、`copilot`、`agy`,#435)。

研究見 `docs/research/agent-abstraction-external.md`(外部做法)與 `docs/research/antigravity-cli-facts.md`(Antigravity 實測)。

## 決策

- **Agent 種類**以 herdr 的正式名稱為準，別名表照 herdr 的清單;herdr 字串只在一個地方轉成 `AgentID`,認不得的是「其他種類」。核心以外不得直接比對 Agent 字串(守門測試擋)。
- 每種 Agent 一份 **Agent 設定檔**(可攜核心的純值):顯示、對話紀錄、輸入、畫面、session 五組，每組可以沒有;沒有就是那項能力不提供。每組記錄驗證過的 Agent 版本。
- 要連主機的能力(方案用量、slash 探索、啟動器)不放進設定檔，由 Features 的對照表依 Agent 種類接上。
- 設定檔輸出的型別語意對齊 Agent Client Protocol(ACP):權限選項(允許一次／永遠允許／拒絕一次／永遠拒絕)、session 設定選項(mode／model／effort)、可用指令、計畫項目。不引入 ACP 依賴。
- 會送按鍵給 Agent 的方言(回答選項、面板、切換權限模式)沒有用真實 Agent 驗證過就不開放;只讀取的照常開放。
- 「需要你」與「完成」以 herdr 回報的為準，不自己重算。

## 考慮過但不採用

- **一個大的 `AgentDriver` protocol**(每種 Agent 實作二十幾個方法):介面跟實作一樣大(淺)，每種 Agent 都要寫一堆預設值。
- **改用 ACP 或各家的結構化介面(Codex app-server、`agy acp`、`-p --output-format stream-json`)驅動 Agent**:這些都要自己起 Agent 程序，讀不到使用者已經在 herdr Pane 裡跑的互動 TUI,而接手既有 Pane 是 Purrdr 的定位。以 ACP 詞彙當輸出型別，保留日後主機服務改走 ACP 的空間。
- **每種 Agent 一個 class 加能力旗標表**:Swift 慣例是 value type,能力用「有沒有那組方言」表達即可，不必另有旗標表與之同步。

## Consequences

- 新增一種 Agent:加一份設定檔、在目錄登記一行;需要主機能力時再接對照表。
- Agent 的 TUI 與對話紀錄格式隨版本變(Claude 官方明說 JSONL 是內部格式),解析器要能部分失敗、比對失敗時安靜退回並記錄;App Store 發版才能更新解析器，herdr 則可遠端更新它的規則。
- 重構以先加新寫法、逐批搬遷、最後刪除舊寫法進行，期間行為不變。

## 更新(2026-11-23):Antigravity 權限提示不在 app 補判斷，等 herdr 修正

實測(#445,PR #459)發現 herdr 0.9.5(agy 偵測規則 2026.10.05.1)認不出 Antigravity CLI 1.5.14 在 default 模式的權限提示，回報 idle／done;`ask_question` 才是 blocked。所以 agy 等權限時，手機不會提示「需要你」。

曾考慮在 Antigravity 設定檔加例外、由 app 依畫面補判斷(#460),最後決定**不做**:維持「需要你以 herdr 為準」,已回報上游(herdrdev/herdr#6141)。herdr 可遠端更新偵測規則，修好後 Purrdr 不用改。在那之前，agy 的權限提示只能在聊天畫面看到。

## 更新(2026-11-27):主機能力表以 `AgentID` × 連線方式為鍵(#686)

「要連主機」的能力(方案用量來源、session 狀態讀取、slash 探索、啟動器)不放進設定檔(設定檔是可攜核心的純值),由 Features 的 `AgentHostCapabilities.resolve(_:over:)` 對照:鍵是 `AgentID` 與連線方式(SSH、HTTPS、Demo,Demo 走 SSH 的程式路徑),沒有的能力是 `false`,畫面自然隱藏;新增 Agent 或連線方式只改這張表,`AgentHostServicesTests` 逐列檢查,並確認 SSH 接線與表一致。方案用量畫面不再有自己的 `PlanUsageAgent`,直接用 `AgentID`(儲存的選擇與 UI 測試識別碼仍是舊字串,由 `planUsageKey` 對應)。HTTPS 的方案用量來源對沒有的 Agent(Antigravity)回 `nil`,不再 `preconditionFailure`。`AgentKind` 已退場(#686 補完):頭像、顯示名稱、列文字一律用 `AgentID`,顯示名稱取自設定檔的 `presentation`(`AgentID.displayName`),`AgentStringGuardTests` 守門。能力組也補齊「恢復 session」(`AgentHostCapabilities.resume`:能否列出、能否帶 session 恢復、能否接續最近一次;旗標式恢復只有 SSH 送得出去,因為主機服務不收任意啟動參數)與「設定說明文字」(方案用量畫面依 Agent 不同的文字集中在 `AgentID.planUsageCopy`,畫面不再 `agent == .agy ? … : …`)。主機能力組就是上面說的那張對照表,`AgentHostServicesTests` 逐列檢查。
