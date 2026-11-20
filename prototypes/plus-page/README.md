# Purrdr Plus 頁的重新設計(拋棄式，PROTOTYPE)

- `purrdr-plus-page.html`:三種結構 × 兩種狀態(已訂閱、會員未訂閱),與現況並排。線上 https://claude.ai/artifact/1E8ndxFUKWYZ2YuYGKXdm9 (私人)。`#a-sub`、`#c-free` 之類的 hash 切換版本與狀態。
- `current-screens.png`:2026-11-21 的現況(會員帳號頁、會員付費牆、Plus 帳號頁、Plus 頁、深層連結)。

問題(使用者):訂閱後的管理訂閱頁空白很怪，登入會員的 Purrdr Plus 頁要多一些說明。

| 版本 | 結構 |
|---|---|
| A 設定頁式 | inset grouped:方案與管理訂閱、「你的 Plus 包含」每項一列帶目前狀態、不需要訂閱的、恢復購買／兌換代碼 |
| B 說明式 | 品牌標誌、狀態一行、每項功能一段說明(含 5 種通知)、常見問題 |
| C 會員卡 | 錢包式會員卡(期間進度、續訂日)、三格目前使用量、免費／Plus 對照表 |

## 結論

**A 設定頁式**(2026-11-21 使用者選定)。實作票 raychiutw/purrdr.ios#323。
