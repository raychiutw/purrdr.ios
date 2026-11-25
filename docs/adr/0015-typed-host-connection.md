# 型別化主機連線:HostConnection 提供領域操作,不再以 herdr 位元組為介面

`HostConnection`(ADR-0010)原本的介面是 herdr 單次請求「一行 NDJSON 進、一行出」,HTTPS 連線得把主機服務協定組回 herdr 的 snapshot 行或 SSH 腳本的輸出格式,上層(`HerdrClient`、`TranscriptReader`)再解析一次。HTTPS 因此繞了一圈,新增操作要同時懂兩種格式。本 ADR 決定在 `HostConnection` 上加**型別化的領域操作**,讓每種連線方式直接回領域型別。決定於 #568(使用者 2026-11-25:直接做,不再評估是否要做),實作是 #594。

## 決策

- `HostConnection` 新增六個型別化操作:`readSnapshot`、`sendKeys`、`sendText`、`readPaneScreen`、`locateTranscript`、`readTranscriptWindow`。
- 每個操作有**預設實作**,走既有的 `HerdrClient` 與 `TranscriptReader`,所以 SSH(及 Demo、`FakeHostConnection` 沒設定型別化 stub 時)沿用 herdr NDJSON 與腳本格式,不必改。
- HTTPS(`HTTPSTypedOperations.swift`)覆寫成直接對應主機服務訊息(`agents.list`、`pane.send_keys`、`pane.send_text`、`pane.read`、`transcript.locate`、`transcript.window`),不再組回 herdr 或 SSH 腳本格式。期限、版本門檻(`HostServiceFeature`)與 `expected_session` 的行為與既有路徑一致。
- 定位結果的檢查(位置是否安全、header 是否符合)抽成 `TranscriptReader.locatedFile(lines:for:)`,SSH 與 HTTPS 共用同一份,不各寫一次。
- `FakeHostConnection` 提供型別化 stub 與 `typedCalls`;沒設定的操作走既有的 herdr 回放,舊測試不用改。

## 與 ADR-0010 的關係

ADR-0010 的決定(單一 WSS、窄 API、不提供任意指令、主機取檔規則、配對與權杖)全部不變。本 ADR 只改 app 內部 `HostConnection` 介面的形狀:ADR-0010 說「herdr 請求在 HTTPS 換成主機服務協定」,現在這個換算由連線方式直接以領域型別完成,不經 herdr 位元組往返。SSH 仍是 herdr NDJSON 與主機腳本(ADR-0002 零安裝不變)。

## 遷移方式(expand–contract)

1. **Expand**(#594,本批):只新增型別化操作與預設實作,既有的 `Data` 操作都不動、呼叫端不遷移,所以可獨立合併、隨時回退。
2. **Migrate**(後續票,分批):`HerdrClient`、`TranscriptReader`、聊天、Pane 等呼叫端逐批改呼叫型別化操作,每批各自測試與合併。
3. **Contract**(#596,已完成):呼叫端都遷完後,移除 `HostConnection` 的 `Data` 操作、預設實作與 HTTPS 的 herdr 格式組回程式。

## AGENTS.md 要改的描述

遷移完成(Contract 那批)時一併更新:

- 「主機連線」段:`HostConnection` 的介面改成型別化操作加串流,不再以 herdr 單次請求位元組為主;`HerdrClient`、`TranscriptReader` 說明為 SSH 預設實作的解析層。
- 「HTTPS 主機連線」段:拿掉「結果組回 herdr 的 snapshot 行／`read.text`／與 SSH 腳本相同的輸出」的敘述,改為直接對應主機服務訊息。
- 新增 herdr 操作的流程(「先在 schema 加訊息、再在 `HerdrOperation` 加 case」)改為:在 `HostConnection` 加型別化操作,SSH 經 wire client 實作(`SSHTypedOperations.swift`)、HTTPS 對應訊息(`HTTPSTypedOperations.swift`)。

Expand 批不改 AGENTS.md 的行為描述,只在遷移進度到哪時補一行狀態。

## 考慮過但不採用

- **一次改完所有呼叫端**:變更面太大、難以回退,也不符合 expand–contract。
- **維持現狀**:每個新操作都要為 HTTPS 寫一次「組回 herdr 格式」的轉換,並由上層再解析一次。

## Consequences

- 新增操作的成本從「兩種格式各寫一次」降成「領域型別一個,SSH 預設實作一個,HTTPS 一個直接對應」。
- Expand 期間 HTTPS 同時有舊的組回格式路徑與新的型別化路徑,測試以「型別化結果等於舊路徑解出的結果」守住兩者一致(`TypedHostConnectionTests`)。
- Contract 前舊程式碼仍在,所以多出一段過渡期的重複。

## 遷移進度(完成)

- Contract(#596):`HostConnection` 移除 `herdrRequest`／`herdrEvents`／`readTranscript` 與所有預設實作,每個型別化操作由連線方式自己實作。herdr 的 NDJSON 與對話紀錄腳本輸出收進 SSH 專屬的 wire 層:核心的 `package protocol HerdrWire`(三個 `Data` 操作,只有 `SSHHostConnection` 實作)、`HerdrWireClient`／`TranscriptWireReader`(原本的 `HerdrClient.wire*`／`TranscriptReader.wire*`,改為獨立的 `package` struct)。HTTPS 刪掉 herdr 回應行組裝(`HerdrOperation`、`HerdrRequestLine`、`HerdrResponseLine`、對話紀錄的腳本輸出組裝),只留 `HerdrMethod`(版本門檻)。`FakeHostConnection` 改成型別化 stub(不再回放 herdr 位元組),測試替身以 `ForwardingHostConnection`／`FailingHostConnection` 組成。HTTPS 沒有對應主機服務訊息的四個操作(整合清單、在場回報、等待、就緒狀態)維持送出前丟 `unsupported`。

## 遷移進度(歷史紀錄)

- Migrate(#595):`HerdrClient` 的 snapshot／送鍵／送文字／讀畫面與 `TranscriptReader` 的定位／讀視窗改經連線的型別化操作;原本的 herdr NDJSON／腳本實作改名 `wire*`，只留給 SSH 預設實作與 `FakeHostConnection` 的回放。其餘 `Data` 操作(prompt、workspace、事件、預覽等)留給 Contract 批(#596)。
- Migrate 第二批(#595):`HerdrClient` 其餘操作(prompt、workspace／tab／worktree 建立關閉重命名、啟動 agent、續接清單、等待、就緒狀態、整合清單、在場回報、ping、事件訂閱)與 `TranscriptReader` 其餘操作(尾端讀取、預覽、subagent、workflow、委派)都經 `HostConnection` 的型別化操作。HTTPS 直接對應主機服務訊息,沒有對應的操作(整合清單、在場回報、等待、就緒狀態)送出前丟 `unsupported`;追蹤與預覽的判讀(`TranscriptReader.interpretTail`、`readings`)SSH 與 HTTPS 共用。呼叫端只剩各 `wire*` 預設實作與轉送用的包裝連線還碰 `Data` 操作;`Data` 操作本身與其測試留給 #596 移除。
