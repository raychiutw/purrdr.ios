# 主機服務常駐 Agent 觀察者

ADR-0010 的主機服務只在 app 連線時轉送請求：沒有連線就什麼也不做。Send When Done(Agent 做完再送下一則)與「卡住／仍在等你」提醒都要在 app 關掉、手機鎖屏時照樣運作，只靠 app 做不到——iOS 會在背景切斷連線，推播又只能由主機主動發出(ADR-0004)。所以主機服務加上一條**常駐的 herdr 事件訂閱**,稱為 **Agent 觀察者**,讓主機服務從「被動轉送」變成「會自己在主機上動作」(raychiutw/purrdr.host#25)。

## 決策

- **觀察者只做三件事**:
  - **Send When Done 佇列**:每個 pane 一條佇列(上限 20 則，每則沿用輸入上限),項目帶文字與 `expected_session`(必填)。Agent 從 `working` 轉 `idle`／`done` 時送出第一則，送出前與即時送出一樣比對 session;`blocked` 時暫停，session 對不上時暫停並保留項目，不送進別的對話。佇列存在狀態資料夾的 `send-queue.json`,重啟後還原。新增項目不會解除暫停。
  - **卡住**:`working` 的 Agent 定期讀畫面指紋(畫面文字的 SHA-256),10 分鐘不變就推播一次。
  - **仍在等你**:`blocked` 持續 15 分鐘就推播一次。兩種提醒都是每個「狀態期間」最多一次。
- **斷線處理**:訂閱斷線以退避重連;重連後讀一次 `session.snapshot` 對帳，斷線期間做完的 Agent 照樣送出佇列下一則。
- **界線**:
  - 只呼叫 herdr 本機 socket 已有的操作(`events.subscribe`、`session.snapshot`、`pane.read`、`agent.prompt`),與 app 經協定能做的事相同;**不執行任意指令**,`no_command_execution` 不放寬，維持 ADR-0010 的窄 API。
  - **不記活動紀錄與對話內容**:佇列只存使用者自己排的文字;畫面只在記憶體裡算指紋比對，不落地。
  - 推播沿用 ADR-0004:內容只有配對密鑰、workspace 名稱、狀態與 pane,**不帶對話或畫面文字**;已靜音的聊天不推，後台回 410 視為配對已撤銷(種類見 raychiutw/purrdr.server#15)。
  - 佇列的新增、移除、排序是寫入操作(`x-write`):唯讀裝置一律拒絕，寫進 `audit.log`(不記文字內容)。
- 離開期間摘要、context 百分比與待辦進度、切換 Claude 權限模式**不放在主機服務**,由 app 解析既有對話紀錄、以 `pane.read`＋`pane.send_keys` 自己處理。主機服務只留非主機不可的部分。

## 考慮過但不採用

- **由 app 在背景輪詢**:iOS 會切斷背景連線，做不到「做完就送」,也無從得知卡住。
- **由 Purrdr 後台排程送出**:佇列文字就得經過後台，違反「聊天不經過後台」。
- **用 herdr plugin 實作佇列**:plugin 在 Windows 仍是 preview(ADR-0004),而且要另外處理 session 比對與持久化，主機服務已經有 herdr 連線與狀態資料夾。
- **觀察者順便記活動紀錄給 app 做摘要**:會在主機上累積使用紀錄;app 讀既有對話紀錄就算得出來。

## Consequences

- 主機服務即使沒有 app 連線也會對 herdr 送 prompt;送出的只會是使用者事先排進佇列、且 session 仍相符的文字。
- `working` 的 Agent 會被定期讀畫面，主機多一點負擔;間隔固定且只在 `working` 時讀。
- 狀態資料夾多一個 `send-queue.json`;解除安裝時一併移除，仍可完整還原。
- 觀察者的行為要在 macOS、Linux、Windows 三平台測試(假 herdr 事件序列＋假推播後台)。
