# 改名為 Purrdr,圖示改為貓掌泡泡

使用者希望名稱跟貓有關、可愛，同時讓人聯想到 herdr。採用 **Purrdr**:purr(貓的呼嚕聲)加上 herdr 結尾的「-rdr」,呼應英文俗語 herding cats(趕貓：管理一群各自亂跑的 agent),而且不含「herdr」字樣。App Store 搜尋(2026-11-15)沒有同名 app,名稱最終以 App Store Connect 保留成功為準。

App 還沒上架、也還沒有程式碼，所以一次全部改名：

| 舊 | 新 |
|---|---|
| Drover Chat | Purrdr |
| Drover Chat Plus | Purrdr Plus |
| Drover 後台 | Purrdr 後台 |
| `com.raychiu.droverchat` | `com.raychiu.purrdr` |
| `raychiutw/drover-chat.ios` | `raychiutw/purrdr.ios`(GitHub 自動轉址舊網址) |
| `~/.drover-chat/` | `~/.purrdr/` |
| `drover-chat-host-plugin` | `purrdr-host-plugin` |

圖示由羊群(B1)改為貓掌泡泡(T3):四顆圓形腳趾加上帶「…」的對話泡泡肉墊，品牌紅與 ADR-0008 的顏色規則不變。

## Consequences

- ADR-0001～0008 與 `docs/research/` 是歷史紀錄，不改舊名;讀到「Drover」時對照上表。
- `prototype/design-directions` 分支保留舊名的原型。
