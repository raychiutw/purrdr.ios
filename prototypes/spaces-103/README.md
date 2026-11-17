# Spaces 列表簡化原型(#103)

拋棄式原型，回答「Spaces 列表要長什麼樣子」。雙擊 HTML 即可開啟。

| 檔案 | 問題 | 結論 |
|---|---|---|
| `purrdr-spaces-prototype.html` | 三種整體版面:A 平鋪、B 依主機分組、C 依狀態 | 選 B,並加入 A 的 Agent 種類頭像 |
| `purrdr-spaces-prototype-b.html` | B1–B3:Agent 列放寬成多行、workspace 怎麼呈現 | 選 B3(可收合的 workspace 群組) |
| `purrdr-spaces-prototype-b3.html` | S1–S3:收合時的多頭像堆疊 | 全部否決，不顯示多個頭像 |
| `purrdr-spaces-prototype-b3-header.html` | H1–H3:收合標頭(含 9 個與 30 個 Agent) | 採用 H2 狀態條，超過 20 個 Agent 依狀態合併分段 |

規格與實作：raychiutw/purrdr.ios#103。
